# ermchat

Twitch chat viewer (WIP). Single Flutter package. See [TODO.md](TODO.md) for the roadmap; [PLAN.md](PLAN.md) is a scratchpad, with [I18N.md](I18N.md) and [BACKLOG.md](BACKLOG.md) as deferred plans.

## Commands

```
flutter run        # launch on device/emulator
flutter test       # run all tests
flutter analyze    # static analysis (flutter_lints)
dart format .      # format all Dart files
```

## Setup

- Clone normally; no submodules. Emote decode is engine + pure-Dart.
- Set `clientId` in `lib/twitch_config.dart` and register the `redirectUri` (exact match) in the Twitch console.

## Architecture (know before editing)

- IRC is the chat pipeline (PRIVMSG/USERNOTICE/CLEARCHAT/CLEARMSG/NOTICE); EventSub is moderation-only (`channel.moderate` v2 where the user is a mod) plus broadcaster-only, read-only chat widgets (hype train/poll/prediction). `ChatConnectionManager` orchestrates all of it.
- Not logged in = anonymous read-only IRC (justinfan NICK, no Helix); emotes still render via the IRC `emotes` tag + third-party providers.
- `TwitchAuth` is multi-account: secure-storage registry + active account (`switchTo`/`removeAccount`, avatar from `profileImageUrl`). The account switcher lives in the settings Account screen.
- OAuth: Android goes through `MainActivity` (session-bound Custom Tab so App Links can't hand off to the Twitch app; `ermchat://` redirect back via the `ermchat/oauth` MethodChannel). iOS keeps `flutter_web_auth_2`. `startFlow({ephemeral})` applies to iOS only (re-auth path).
- Emote caching: `EmoteManager` (ChangeNotifier, metadata TTL, usage registry) + `EmoteCacheManager` (disk cap, evicts by registry priority). 7TV live updates via `SevenTvEventClient`.
- Message spans are cached per message in `MessageBuilder` and invalidated against `EmoteManager.version`, so emote changes recompute lazily.

## Architecture rules

See [docs/ARCHITECTURE_RULES.md](docs/ARCHITECTURE_RULES.md) for the rules and [docs/DECISIONS.md](docs/DECISIONS.md) for why. [docs/BEHAVIOR_CHECKLIST.md](docs/BEHAVIOR_CHECKLIST.md) gates each migration phase. `test/architecture/architecture_test.dart` enforces the import-direction rules; keep it green.

## Chat kernel conventions

- `Chat` is the root: channel registry and cross-channel totals. `Channel` composes `Messages`/`Threads`/`Unread`/`Moderation`/`Points`/`ChannelInfo`. Account identity lives in `lib/client/Session`, outside the kernel; the app subscribes to `Session.version`.
- Mutate only through verbs. Live path is `Channel.receive`, history path is `Channel.receiveHistory`. Both stay atomic: dedup, insert, truncate, index in one call.
- `Channel` children are readable from anywhere, but only `Channel` verbs may mutate them. Exception: row-scoped moderation edits go through `Messages.markDeleted`/`markUserDeleted`/`markAllDeleted`.
- Pipeline components (`ChatConnectionManager`) may gate/filter messages but must not re-implement state rules.
- No generic bus. Owners expose typed notifiers (`Messages.version`, `ChannelInfo.version`, `Moderation` versions, `Chat` aggregates). UI subscribes to the owner it renders.
- New chat-state features: put the rule in `lib/chat/`, add tests in `test/chat/`, then consume from pipeline/UI.
- View-only caches (tile caches, panel data) stay in `HomeScreen`, driven by typed notifiers.

## Test conventions

- Unit tests in `test/unit/<file>_test.dart`, data/IRC-parsing tests in `test/data/`, widget/integration tests in `test/widgets/`.
- Injectable for tests: `TwitchApi.client`, `TwitchChatApp`/`HomeScreen` service params, `EventSubService.handleRawMessage`/`emitConnected`/`waitForSession`, `EventSubDecoder.feed`, `IrcChatDecoder.feed`, socket `handleLine`, `OAuthStarter`, `AccountScreen.twitchApi`.

## Rules

When you make a commit, ALWAYS read [RULES.md](RULES.md) first: short jab titles (4 words target, 8 hard max), body essentially never. RULES.md also holds code-consistency and subagent rules; follow those too. Read RULES.md on first init.
IMPORTANT: NO em-dashes.
If a comment is multiple lines long, see if you can rephrase it to be shorter. ALWAYS review a comment if you write one more than 3 lines long.
Comments and doc comments state what the code does and why, in the present tense. Never narrate the change (no "previously", "used to", "moved from").
NEVER `dart format .` as it creates extremely large diffs. Instead, specify the exact files to format.

## Notes

- Versions live in pubspec.yaml (Dart SDK, Flutter channel, app version). `flutter_lints` only, no codegen.
