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

- Clone with submodules (`git clone --recursive`); `third_party/libwebp` (pinned v1.4.0) is required to build `libemote_codec`.
- Set `clientId` in `lib/twitch_config.dart` and register the `redirectUri` (exact match) in the Twitch console.

## Architecture (know before editing)

- IRC is the chat pipeline (PRIVMSG/USERNOTICE/CLEARCHAT/CLEARMSG/NOTICE); EventSub is moderation-only (`channel.moderate` v2 where the user is a mod) plus broadcaster-only, read-only chat widgets (hype train/poll/prediction). `ChatConnectionManager` orchestrates all of it.
- Not logged in = anonymous read-only IRC (justinfan NICK, no Helix); emotes still render via the IRC `emotes` tag + third-party providers.
- `TwitchAuth` is multi-account: secure-storage registry + active account (`switchTo`/`removeAccount`, avatar from `profileImageUrl`). The account switcher lives in the settings Account screen.
- OAuth: Android goes through `MainActivity` (session-bound Custom Tab so App Links can't hand off to the Twitch app; `ermchat://` redirect back via the `ermchat/oauth` MethodChannel). iOS keeps `flutter_web_auth_2`. `startFlow({ephemeral})` applies to iOS only (re-auth path).
- Emote caching: `EmoteManager` (ChangeNotifier, metadata TTL, usage registry) + `EmoteCacheManager` (disk cap, evicts by registry priority). 7TV live updates via `SevenTvEventClient`.
- Message spans are cached per message in `MessageBuilder` and invalidated against `EmoteManager.version`, so emote changes recompute lazily.

## Test conventions

- Unit tests in `test/unit/<file>_test.dart`, data/IRC-parsing tests in `test/data/`, widget/integration tests in `test/widgets/`.
- Injectable for tests: `TwitchApi.client`, `TwitchChatApp`/`HomeScreen` service params, `EventSubService.handleRawMessage`/`emitConnected`/`waitForSession`, `IrcService.emitChatMessage`/`emitUserNotice`, `OAuthStarter`, `AccountScreen.twitchApi`.

## Consistency

- Use `InkWell` (not `GestureDetector`) for `onLongPress` in scrollable contexts.
- Apply message features to both the main chat and the thread panel.
- Emote providers: static `fetchGlobal()`/`fetchChannel(channelId)` (7TV exposes `fetchChannelResponse`); dedup priority 7TV > BTTV > FFZ > Twitch.
- NO em-dashes in new code; avoid non-ASCII unless necessary.

## Notes

- Dart SDK `^3.12.2`, Flutter stable, app version `0.5.1`; `flutter_lints` only, no codegen.
