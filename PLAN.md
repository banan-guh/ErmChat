# Localization / i18n

Not yet implemented. No architectural changes required - Flutter l10n is additive and the
codebase's existing patterns (prefs-backed settings state, constructor-injected service
configs) already fit it. Current state: no `intl`, no `flutter_localizations`, no
`l10n.yaml`, no ARB files; `MaterialApp` (main.dart:142,150) has no
`localizationsDelegates`. ~160+ user-facing literals in screens/widgets plus ~50-100 in
services (command usage/error texts, "Connected"/"Disconnected", "Live with X viewers
for Yh Zm", notification titles, loading/error messages) = ~300-400 unique strings.

## L1. Dependency + wiring (small)

- Problem: the app has no localization infrastructure at all, so nothing can be
  translated.
- Solution:
  - Add `flutter_localizations` (SDK) + `intl` to pubspec; create `l10n.yaml` and
    `lib/l10n/app_en.arb` (English is the source locale; other locales start as AI
    translations).
  - Wire `MaterialApp` (both instances in main.dart): `localizationsDelegates:
    AppLocalizations.localizationsDelegates`, `supportedLocales`, and `locale` bound
    to a prefs-backed state field using the existing `_themeMode`/`_setThemeMode`
    pattern (main.dart:103) so the language can switch at runtime.
  - Add a language picker to Settings (prefs key, e.g. `locale`).

## L2. Service access to translations (the one design decision)

- Problem: services build user-facing strings without a BuildContext: `CommandHandler`
  (usage/error texts), `ChatConnectionManager` ("Connected", "Live with X viewers..."),
  `NotificationService` (ping titles), `RecentMessagesService`, `MediaUploader`,
  `foreground_task`. These are composed into system messages rendered in chat, so they
  must be translated at composition time, not at the edge.
- Solution: inject an l10n accessor into services via the existing config-injection
  pattern (`ChatConnectionConfig` already takes ~20 callbacks). A narrow interface,
  e.g. `String Function(String key, {List<Object> args})` (or a `AppLocalizations`
  wrapper), keeps services decoupled from Flutter's localization machinery and is
  trivially testable. Do NOT use a global singleton or leave service strings in
  English.

## L3. String extraction (the big mechanical chunk)

- Problem: ~300-400 hardcoded literals across screens, widgets, and services.
- Solution: replace literals with `AppLocalizations.of(context)!...` keys; use ICU
  placeholders/plurals for dynamic strings ("Live with {viewers} viewers",
  "timed out for {duration}s", "{count} more options"). Order of extraction: settings
  screens -> widgets -> home_screen -> services (via L2).
- Boundary: Twitch's own `system-msg` (sub/raid notices), usernames, emotes, and chat
  text stay untranslated - only app-authored labels translate. Message span/tile
  caches are unaffected (they hold chat content, not labels).

## L4. AI translation workflow + validation (the safety net)

- Problem: AI-generated translations are good for short UI strings but fail
  mechanically on ICU placeholders/plurals (renaming or reordering
  `{placeholders}`), and drift on chat-domain jargon ("emote", "sub", "raid",
  "shoutout", "whispers", "ping") without a glossary.
- Solution:
  - Generate launch locales (de, es, fr, pt, ja recommended; dev/debug screens can
    stay English) with a strict prompt: preserve `{placeholders}` verbatim, keep ARB
    keys and one line per string, obey the glossary.
  - Maintain a glossary of frozen terms: "ErmChat", "emote", "sub", "raid",
    "shoutout", "whispers", "ping", "true dark" - and the intentional placeholder
    strings that must never be translated (e.g. `g;pr[SomgomgAtYou`,
    "glorpKaraoke", foreground_task.dart:67-68).
  - Add a validation test (~50 lines): every ARB parses; every key in `app_en.arb`
    exists in each locale; every `{placeholder}` in the English string exists in the
    translated string (catches the #1 AI failure mode before it ships).
  - Longer translated strings can break layouts (German/CJK) - QA pass per locale;
    RTL languages (ar/he) need a layout pass on the custom tab bar / input row (no
    structural work, Directionality comes from the delegates).

## Verification

`flutter gen-l10n` succeeds; the ARB validation test passes for every locale; app
launches with each locale set; runtime language switch via Settings applies without
restart; services render translated system messages; chat content and Twitch
`system-msg` remain untranslated.

# Performance: medium-tier backlog

Carried over from the full audit. Each is practical, self-contained, and worth doing
when touching the file anyway.

## P1. PaintedUsernameText rebuild scope (painted_username_text.dart)

The `ListenableBuilder` listening to `SevenTvPaintService` rebuilds every visible
username when any paint resolves. Fix: compare `service.lookup(userId)` against the
previous paint before rebuilding; short-circuit when unchanged.

## P2. InlineEmoteView theme lookup (inline_emote_view.dart:209)

`Theme.of(context).colorScheme.surfaceContainerHighest` is resolved per emote in
every chat tile (hundreds of InheritedWidget walks per build). Fix: pass the
highlight color down from the parent tile as a constructor parameter.

## P3. Stacked Opacity compositing (chat_message_tile.dart:246-261)

Up to three independent `Opacity` widgets stack for deleted + backfill + shared-chat
fading, each allocating an offscreen buffer. Fix: compute a single combined alpha
and apply once.

## P4. Action message span allocation (message_builder.dart:49-68)

Every `/me` message allocates a fresh `TextSpan` list via `.map().toList()` to
re-color non-link spans. Fix: cache the colored variant alongside the base spans
when the version matches.

## P5. Emote menu recent-emotes debounce (emote_menu_panel.dart:85-89)

Every `EmoteManager` notification (7TV live deltas) triggers an async DB query
for recent emotes. Fix: debounce `_loadRecentEmotes` to coalesce rapid-fire
notifications.

## P6. ChatView idToIndex rebuild (chat_view.dart:159-168)

Inside the `ValueListenableBuilder` (fires on every new message), a
`Map<String, int>` is rebuilt by scanning the full message list against pending
tile-cache keys — O(n*m). Fix: maintain incrementally on add/remove.

## P7. SevenTvEventClient dispose order (seven_tv_event_client.dart:667-682)

`dispose()` nulls `_channel`, `_heartbeatTimer`, etc. before calling
`_disconnect()`, so the disconnect path can't cancel the still-live
subscriptions/timers. Fix: call `_disconnect()` first, then null remaining fields.
Also track the reconnect timer in a field and cancel it on dispose.

## P8. SevenTvEventClient reconnect timer tracking (seven_tv_event_client.dart:602-607)

The reconnect `Timer(delay, ...)` is fire-and-forget. If `dispose()` runs during
backoff, the timer leaks until it fires. Fix: store the timer in a field and
cancel in `_disconnect()`/`dispose()`.

## P9. NativeEmoteCodec sequential frame decode (native_emote_codec.dart:155-161)

`ui.decodeImageFromPixels` is awaited sequentially per frame. Fix: fire all
`decodeImageFromPixels` concurrently and collect results.

## P10. EmoteManager _removeFromSuggestions O(n) (emote_manager.dart:1326-1444)

Each 7TV delta (add/rename/remove) calls `_removeFromSuggestions` which does a
linear `indexWhere` scan. For batch deltas this is quadratic. Fix: rebuild the
suggestions list once at the end of `updateSevenTvEmotes` instead of
inserting/removing per operation.

## P11. EmoteManager _isEmoteUsedElsewhere scan (emote_manager.dart:1446-1451)

Per removed emote, scans every channel's `byCode.values` linearly —
O(removed * channels * avg_emotes). Fix: maintain a `_globalIdUsageCount:
Map<String, int>` reference counter (increment on add, decrement on remove) for
O(1) lookups.

## P12. ChatStore truncation passes (chat_store.dart:591-681)

`truncateChannel` does 5 passes over the full message list: parentOf, thread
grouping, active-thread identification, keep-indices, retained-list. Fix: collapse
phases 1+2+3 into a single pass.

## P13. NotificationService sequential show (notification_service.dart:139-141)

Each mention notification `await`s the platform `show()` call, serializing rapid
pings. Fix: fire `show()` without await; debounce `_updateSummary()`. Also cap
`_summaryOrder` at ~50 entries and clear `_idsByChannel` on channel-less clear-all.

## P14. EmoteMetaStore migrateFromPrefs batch (emote_meta_store.dart:71-92)

Migration calls `prefs.getString(key)` and `prefs.remove(key)` in a loop — each a
separate platform channel call. Fix: batch with `prefs.getStringList` or collect all
keys first, then batch-remove.

## P15. suggestion.dart emote list flatten (home_screen.dart:1042-1049)

`_cachedAutocompleteEmotes` is invalidated on every `_onEmotesChanged` but the
flatten itself (`expand((e) => e)`) still creates a new list when the cache is
missed. Fix: cache the flattened list across channels, not just per invalidation.
