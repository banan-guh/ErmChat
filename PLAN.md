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

## Post-0.7.5 backlog

Release wrap-up triage, kept short so 0.7.5 can ship and stop.

### ASAP next update

- Emote resilience: bounded retry on fail, low-res placeholder when tier goes
  Low to High, uncapped FPS follows display refresh.
- Perf: image-embed cache bypass plus double linkify, action-message recolor,
  double tokenize, GIF regex hoist, explicit cacheExtent, checker parity by id.
- Visual: border flicker on tab in, tab strip stretch, double Connected on iOS,
  timestamp gutter width, reply colon on empty preview.
- UX consistency: one slider contract, one empty state, one error with Retry,
  welcome copy fix, InkWell audit, More menu Close, macro Save errors.
- Verify own-message send ack if the read socket dies mid-send.

### Near future

- Widget test prune. 84 candidates cataloged across widgets_test plus the five
  smaller widget files. Keep reconnect dedup, tombstone, thread truncation,
  pause hold, swipe hysteresis, JOIN gate. Only prune when tests churn or CI
  gets slow.
- Notification double-init plus stale map, player and sheet controller swaps,
  subscribe-then-part race.
- Short architecture and data flow doc.
- Mod View 52-issue triage plus Points CRUD decision.

### Far future, major reworks only

- Split connection manager and store god objects. Private state with verbs
  only. Single ingest path. Single moderation formatter. Table-driven EventSub.
- UI: single tile cache owner, one tile config for main, thread, mentions,
  history. Split mod_view per tab. Single panel shell. Single input borrow
  stack. Stable video slot across layout modes.
- Features: VOD replay, dual-pane, chat search, full l10n, accessibility pass,
  home widget, iOS push, stream battery saver.

### Rejected for right before release (too high scope)

- Android release signing fallback when key.properties is missing.
- English-only declaration plus F-Droid changelog docs.
- Switching-account connecting hint rework.
- Join dialog validation plus progress plus n/50 count.
- Full widget test gutting.
- All god-object splits and structural UI reworks.
