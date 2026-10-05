# ermchat

Twitch chat viewer (WIP). Single Flutter package. See [TODO.md](TODO.md) for the roadmap and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for a map of the app; [docs/I18N.md](docs/I18N.md) is a deferred plan.

## Commands

```
flutter run              # launch on device/emulator
flutter test             # run all tests
flutter analyze          # static analysis (flutter_lints)
dart format <files>      # only the files you changed, never `.`
```

## Setup

- Clone normally; no submodules. Emote decode is engine + pure-Dart.
- Set `clientId` in `lib/twitch_config.dart` and register the `redirectUri` (exact match) in the Twitch console.
- In-app bug reports post to ermchatbot at the URL in `lib/report_config.dart`. The bot's `TWITCH_CLIENT_ID` must equal `clientId`.

## Architecture (know before editing)

- IRC is the chat pipeline (PRIVMSG/USERNOTICE/CLEARCHAT/CLEARMSG/NOTICE); EventSub is moderation-only (`channel.moderate` v2 where the user is a mod) plus broadcaster-only, read-only chat widgets (hype train/poll/prediction). `ChatConnectionManager` orchestrates all of it. Moderation facts from both sources funnel through `ModerationHub`; `ChatLiveness` owns the watchdog and reconnect paths.
- Not logged in = anonymous read-only IRC (justinfan NICK, no Helix); emotes still render via the IRC `emotes` tag + third-party providers.
- `TwitchAuth` is multi-account: secure-storage registry + active account (`switchTo`/`removeAccount`, avatar from `profileImageUrl`). The account switcher lives in the settings Account screen.
- OAuth: Android goes through `MainActivity` (session-bound Custom Tab so App Links can't hand off to the Twitch app; `ermchat://` redirect back via the `ermchat/oauth` MethodChannel). iOS keeps `flutter_web_auth_2`. `startFlow({ephemeral})` applies to iOS only (re-auth path).
- Emote caching: `EmoteManager` (ChangeNotifier, metadata TTL, usage registry) + `EmoteCacheManager` (disk cap, evicts by registry priority). 7TV live updates via `SevenTvEventClient`.
- Message tokens parse once at ingest onto `TwitchMessage.emoteTokens` and freeze; `MessageBuilder` caches spans per message keyed on badge/link/gif prefs only. Typing, picker, and menus read the live mixer.
- Emote playback: animated non-Twitch emotes (and frozen stills) run through `EmoteUrlProvider`'s custom loop on one shared tick (`runOnTick`) at `EmoteUrlProvider.frameRate`, set by `EmoteFrameRatePolicy`. Playing Twitch GIFs use the stock `Image` and pause only through `TickerMode` (`EmoteUrlProvider.playing`). Per-frame work joins the shared tick; never add a timer per emote.
- Settings search: each settings tile takes its title from a `Setting` in `lib/screens/settings/settings_search.dart` and wraps in `SettingAnchor`. Add new settings there too; `settings_search_test` fails when a declared setting is missing from its page.
- `ChatView` reuses rows across inserts via `findChildIndexCallback`, limited to slots from the last layout (flutter#153922 crash). Removing it rebuilds every visible row per message. Rows outside the viewport freeze their emotes through `_RowGate`.

## Architecture rules

See [docs/ARCHITECTURE_RULES.md](docs/ARCHITECTURE_RULES.md) for the rules and [docs/DECISIONS.md](docs/DECISIONS.md) for why. `test/architecture/architecture_test.dart` enforces the import-direction rules; keep it green.

Never route around a rule to make a check pass: no re-export shims, wrapper files, or new carve-outs that sneak a forbidden import in, and no flipping a test's assertion because your change broke it. A test that locks deliberate behavior (read its name and comments) means your change is wrong, or the user must decide. When a rule blocks the obvious fix, put the code in the layer allowed to own it (e.g. widget identity like `GlobalKey` lives in `lib/widgets`, not on a service). If no layer fits, stop and ask.

## Chat kernel conventions

- `Chat` is the root: channel registry and cross-channel totals. `Channel` composes `Messages`/`Threads`/`Unread`/`Moderation`/`Points`/`ChannelInfo`. Account identity lives in `lib/client/Session`, outside the kernel; the app subscribes to `Session.version`.
- Mutate only through verbs. The live path is `Chat.receive` (root) delegating to `Channel.receive`; the history path is `Chat.receiveHistory` delegating to `Channel.receiveHistory`. The root owns the `@mentions` mirror and the unread/mention totals, so pipeline callers never write a root child. The channel verbs stay atomic: dedup, insert, truncate, index in one call.
- `Channel` children are readable from anywhere. Ingest-critical writes go through `Channel` verbs; a child owner's own methods (`Moderation.putBan`, `Points.upsertRedemption`) are its verbs. Row-scoped moderation edits use `Messages.markDeleted`/`markUserDeleted`/`markAllDeleted`.
- Pipeline components (`ChatConnectionManager`) may gate/filter messages but must not re-implement state rules.
- No generic bus. Owners expose typed notifiers (`Messages.version`, `ChannelInfo.version`, `Moderation` versions, `Chat` aggregates). UI subscribes to the owner it renders.
- New chat-state features: put the rule in `lib/chat/`, add tests in `test/chat/`, then consume from pipeline/UI.
- View-only caches (tile caches, panel data) stay in `HomeScreen`, driven by typed notifiers.

## Tests

A test earns its place when a bug there would be quiet, rare to trigger, or expensive. Loud bugs you would hit in a day of normal use don't need one.

- Test: protocol parsing (IRC, EventSub, 7TV, history) with real payloads; chat kernel rules; reconnect, backoff, join rate limits; auth and token refresh; persisted data that must survive an upgrade; emote priority and eviction; leaks; and each bug that actually shipped (one regression test, named for the bug).
- Don't test: that a widget renders or a label shows, that a toggle saves a pref, pixel sizes, copy text, getters/enums/constants, internal counters (unless guarding a leak), or third-party libraries.
- Extend an existing table or flow before adding a test: one test per rule, not per input. Name the failing case with `reason:`.
- Fake time, never real waits. New timing code takes an injectable clock instead of reading `DateTime.now()`.
- Widget tests: pump once and assert along one flow. Boot `TwitchChatApp`/`HomeScreen` only when the behavior needs the whole app.
- Deleting a redundant test is a normal change.
- Layout: `test/chat` (kernel rules), `test/data` (parsing), `test/unit`, `test/widgets`, `test/leak`, `test/architecture`.
- Injectable for tests: `TwitchApi.client`, `TwitchChatApp`/`HomeScreen` service params, `EventSubService.handleRawMessage`/`emitConnected`/`waitForSession`, `EventSubDecoder.feed`, `IrcChatDecoder.feed`, socket `handleLine`, `OAuthStarter`, `AccountScreen.twitchApi`.

## Rules

When you make a commit, ALWAYS read [RULES.md](RULES.md) first: short jab titles (4 words target, 8 hard max), body essentially never. RULES.md also holds code-consistency and subagent rules; follow those too. Read RULES.md on first init.
IMPORTANT: NO em-dashes.
TODO.md entries are one line: what, not how. Design notes belong in the PR or docs.
If a comment is multiple lines long, see if you can rephrase it to be shorter. ALWAYS review a comment if you write one more than 3 lines long.
Comments and doc comments state what the code does and why, in the present tense. Never narrate the change (no "previously", "used to", "moved from").
NEVER `dart format .` as it creates extremely large diffs. Instead, specify the exact files to format.
Smallest change in the code that already owns the behavior. No new files, helpers, abstractions, or dependencies for a one-off; no edits outside your task (version bumps, TODO lines, unrelated cleanups) folded into a commit.

## Performance

- `--dart-define=ERMCHAT_PERF=true` logs a `[perf]` line every 10s (frames, build/raster ms, timer sites, emote gauges). `ERMCHAT_FAKE_CHAT=<msgs/sec>` feeds seeded synthetic chat through the real IRC decoder.
- `tool/perf_ab.sh <label>` builds, installs and samples per-thread CPU on a USB device (`FAKE=10` for load). Compare A/B runs back to back; about ±5% is noise. Measure on a real phone, not an emulator.

## Notes

- Versions live in pubspec.yaml (Dart SDK, Flutter channel, app version). `flutter_lints` only. The one codegen is `flutter gen-l10n` (run by pub get, test, build); its output is gitignored.
- User-facing text lives in `lib/l10n/app_en.arb` and reads through `context.l10n`; translations arrive as other `app_<locale>.arb` files. Usernames, emotes, chat text and Twitch's own notices stay untranslated.
