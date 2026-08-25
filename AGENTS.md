# ermchat

Twitch chat viewer (WIP). Single Flutter package. See [TODO.md](TODO.md) for the roadmap; [PLAN.md](PLAN.md) covers the home_screen refactor (done).

## Commands

```
flutter run        # launch on device/emulator
flutter test       # run all tests
flutter analyze    # static analysis (flutter_lints)
dart format .      # format all Dart files
```

## Setup

- Clone with submodules (`git clone --recursive`); `third_party/libwebp` (pinned submodule) is required to build `libemote_codec`.
- Set `clientId` in `lib/twitch_config.dart` and register the `redirectUri` (exact match) in the Twitch console.

## Architecture (know before editing)

- IRC is the chat pipeline (PRIVMSG/USERNOTICE/CLEARCHAT/CLEARMSG/NOTICE); EventSub is moderation-only (`channel.moderate` v2 where the user is a mod) plus broadcaster-only, read-only chat widgets (hype train/poll/prediction). `ChatConnectionManager` orchestrates all of it.
- Not logged in = anonymous read-only IRC (justinfan NICK, no Helix); emotes still render via the IRC `emotes` tag + third-party providers.
- `TwitchAuth` is multi-account: secure-storage registry + active account (`switchTo`/`removeAccount`, avatar from `profileImageUrl`). The account switcher lives in the settings Account screen.
- OAuth: Android goes through `MainActivity` (session-bound Custom Tab so App Links can't hand off to the Twitch app; `ermchat://` redirect back via the `ermchat/oauth` MethodChannel). iOS keeps `flutter_web_auth_2`. `startFlow({ephemeral})` applies to iOS only (re-auth path).
- Emote caching: `EmoteManager` (ChangeNotifier, metadata TTL, usage registry) + `EmoteCacheManager` (disk cap, evicts by registry priority). 7TV live updates via `SevenTvEventClient`.
- Message spans are cached per message in `MessageBuilder` and invalidated against `EmoteManager.version`, so emote changes recompute lazily.

## Chat kernel conventions

- `ChatStore` is the kernel: it owns the chat state collections and the laws for mutating them.
- Mutate only through store verbs (`addSystemMessage`, ingest-style operations, `truncateChannel`, `indexMessages`); never reach into the exposed collections directly.
- Pipeline components (`ChatConnectionManager`) may gate/filter messages but must not re-implement state rules.
- Kernels emit downward only: change events on `store.events` (per-channel notifiers) and UI-effect notices on `store.notices`; they never import Material widgets or call upward into screens. `HomeScreen` subscribes once and translates both.
- New chat-state features: put the rule in `ChatStore`, add unit tests in `test/unit/chat_store_test.dart`, then consume from pipeline/UI.
- View-only caches (tile caches, panel data) stay in `HomeScreen`, driven by `store.events`.

## Test conventions

- Unit tests in `test/unit/<file>_test.dart`, data/IRC-parsing tests in `test/data/`, widget/integration tests in `test/widgets/`.
- Injectable for tests: `TwitchApi.client`, `TwitchChatApp`/`HomeScreen` service params, `EventSubService.handleRawMessage`/`emitConnected`/`waitForSession`, `IrcService.emitChatMessage`/`emitUserNotice`, `OAuthStarter`, `AccountScreen.twitchApi`.

## Rules

When you make a commit, ALWAYS read [RULES.md](RULES.md) first: short jab titles (4 words target, 8 hard max), body essentially never. RULES.md also holds code-consistency and subagent rules; follow those too.

## Notes

- Versions live in pubspec.yaml (Dart SDK, Flutter channel, app version). `flutter_lints` only, no codegen.
