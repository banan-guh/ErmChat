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

## P16. systemBodyBuilder parseTextWithLinks leak (chat_view.dart:271)

`systemBodyBuilder` calls `parseTextWithLinks` on every tile rebuild for system
messages. System messages have no stable `messageId`, so the tile cache skips them.
Each call creates `RegExp`, runs `linkify()`, and allocates `TapGestureRecognizer`
objects that are never disposed. Fix: cache parsed spans on the `TwitchMessage`
object (same `cachedSpans` pattern as regular messages). Use a
`GestureRecognizerFactory` or dispose recognizers on span reuse.

## P17. RegExp per-message in _mergeHistoryIntoChannel (home_screen.dart:871)

A new `RegExp(RegExp.escape(msg.login), caseSensitive: false)` is compiled for
every system message during history merge. RegExp compilation is expensive. Fix:
cache compiled regexps in a `Map<String, RegExp>` (login is the key) scoped to the
merge call, or use `String.toLowerCase()` comparison instead.

## P18. addRepaintBoundaries disabled (chat_view.dart:198)

`addRepaintBoundaries: false` means a paint in ANY visible message forces
repainting ALL visible messages. The original comment says it's for performance, but
the net effect is worse: one changed emote frame repaints the entire visible list.
Fix: re-enable `addRepaintBoundaries: true` (or verify the manual
`RepaintBoundary` wrapping in `_buildTile` at line 314 is sufficient and remove the
`addRepaintBoundaries: false` override).

## P19. 7TV subscriptions never unsubscribed on channel leave

`subscribeEmoteSet`/`subscribeUser`/`subscribeTwitchChannel` are called in
`chat_channel_setup.dart:476-478` but the corresponding `unsubscribe*` methods on
`SevenTvEventClient` (lines 236-262) are never called. Stale subscriptions mean 7TV
sends events for channels no longer viewed. Fix: call `unsubscribe*` in the channel
removal path (`_removeChannel` in home_screen.dart).

## P20. AnimatedBuilder over-scoped in widget cutout dots (chat_widget_cutout.dart:59)

One `AnimatedBuilder` per page dot, all listening to the same `PageController`
animation. Every scroll tick rebuilds ALL dots, but only 2 change. Fix: use a single
`AnimatedBuilder` wrapping the entire `Row` of dots, or scope each dot's listener to
only fire when its index is adjacent to the active page.


# Mod View

Parity wishlist with twitch.tv mod view. Land the wishlist in TODO first,
then implement one item at a time. V1 starts with M1.

## M0. Wishlist

1. AutoMod queue (hold/allow/deny) as first tab.
2. Quick actions on user/message: timeout picker + reason, ban/unban, delete, warn, clear.
3. Chat mode controls: slow/followers/emoteonly/subs/r9k/shield/commercial/raid/shoutout.
4. Mod/vip list manager (view/add/remove).
5. Unban request inbox.
6. Blocked/permitted terms manager.
7. Warnings log + mod activity feed.
8. Suspicious users + AutoMod settings editor.

## M1. AutoMod queue (first tab)

- Problem: moderation today is slash commands plus a read-only event feed.
  No queue, no approve/deny UI. Missing Helix verbs
  (`manageHeldAutoModMessages`, `getAutoModSettings`, `getBlockedTerms`,
  `getBannedUsers`, `getWarnings`) and scopes
  (`moderator:manage:automod`, `moderator:read:automod_settings`,
  `moderator:manage:unban_requests`, `moderator:read:suspicious_users`).
- Solution:
  - Add Helix verbs to `TwitchApi` plus the missing scopes in `twitch_oauth.dart`.
  - Subscribe `automod.message.held` + `automod.message.updated` per modded
    channel in `chat_channel_setup.dart` next to `channel.moderate` v2.
  - New `heldMessages` collection in `ChatStore` with kernel verbs
    (add/resolve/expire), unit tests in `chat_store_test.dart`.
  - UI: `ModView` screen or `OverlayPanel.modQueue` tab; entry from app bar
    3 dots, user profile sheet, and message long press (both currently have
    no mod rows).

## Verification

Held message appears in queue; allow releases to chat; deny drops it;
403 non-mod hides the entry.

# Webview video player (DankChat port)

## V1. Per-channel player above chat

- Problem: no in-app video. Chat only, links open externally.
- Solution (copies `~/dankchat/app/.../stream/`):
  - New dep `webview_flutter`. New `StreamPlayerController` (current channel,
    audio-only, theater flags) plus `StreamPlayerView` (16:9 box above
    `ChatView` with close/audio-only/theater overlay).
  - URL: `https://player.twitch.tv/?channel=$channel&enableExtensions=$flag&muted=false&parent=twitch.tv`
    (`StreamViewModel.kt:148-156`). JS on, `mediaPlaybackRequiresUserGesture=false`,
    `domStorageEnabled=true` (`StreamWebView.kt:9-24`).
  - `WebViewClient` allowlist: `about:blank`, `https://id.twitch.tv/`,
    `https://www.twitch.tv/passport-callback`, `https://player.twitch.tv/`;
    block rest (`StreamView.kt:448-509`). Handle render-process death with a
    generation counter; cache WebView behind a retain setting; switch URL per
    channel via `setStream(channel)`; resume after config change with
    `document.querySelector('video')?.play()`.
  - Toggle from channel header or 3 dots menu. Settings: retain webview, show
    extensions, audio-only default.
- Boundary: chat stays the source of truth; player is view-only.

## Verification

Channel A plays; switch to B loads B; close stops; audio-only hides video;
rotation/theater keeps playback; `parent=twitch.tv` verified on Android
WebView and iOS WKWebView.

# Native Twitch GIFs

Generic `.gif` link embeds stay future work (`TODO.md:56`). This spec covers
only native T2/T3 GIPHY messages. Chatterino7 does not have this feature;
standard Chatterino has link previews plus image uploader only, and open
issue `chatterino2#7186` tracks the same gap.

## G1. Render T2/T3 GIF messages

- Problem: wire format unknown. Chatterino note says GIFs "work essentially
  as emotes but there is no list and they need to be loaded after the message
  is received." Twitch docs: single standalone message, 30s cooldown, PG
  default (G optional), respects AutoMod/emote-only/shield/timeout, fallback
  is GIF name text, static preview if animations disabled.
- Solution:
  - Investigative step: capture raw IRC tags plus EventSub
    `channel.chat.message` fragments for a T2/T3 GIF message.
  - Parse into new `TwitchMessage` fields (`gifUrl` + fallback text) in
    `twitch_irc.dart` and `twitch_eventsub.dart`, preserving emote offset logic.
  - Render via `CachedNetworkImage` in `message_builder.dart`/`emote_text.dart`,
    reusing `InlineEmoteView` sizing and the unlimited-fps setting. New chat
    appearance pref for disable-animations (static preview).
  - `ChatStore` needs no new laws; GIF is message content like emotes.

## Verification

T2 GIF renders animated; non-sub sees fallback text; delete/timeout removes
it; disable-animations shows static; cooldown and moderation behavior match
Twitch.

# Threads dashboard

## T1. Active + Saved tabbed panel (like mentions)

- Problem: threads exist in kernel (`ChatStore` threads, `threadFor`,
  `computeThreadMessages`) with single-thread view only. No overview, no
  saved threads.
- Solution:
  - Extend `OverlayPanel` in `home_screen.dart:62` with a threads dashboard
    using a TabBar: Active / Saved. Reuse `_buildMentionsPanel` /
    `_buildThreadPanel` patterns and `PanelManager.computeThreadMessages`.
  - Active tab: derive from store threads sorted by `lastActivity`, unread
    via `PingManager` participation.
  - Saved tab: bookmark action in `_showMessageMenu` ("Save thread") plus
    unsave; persist `channel -> [rootIds]` in prefs (cap ~50).
  - Tap row opens existing `_showThreadView`; reply via main input bar
    (`_replyToMsg` + focus) since panels stay copy-only. Entry in app bar
    3 dots next to mentions.

## Verification

Active list updates live; save persists across restart; tap navigates to
thread; reply from dashboard posts to the correct thread root.