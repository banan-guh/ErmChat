# flutter_twitch_app

Twitch chat viewer (WIP). Single Flutter package, no monorepo. Version `0.0.5+1`.

See [TODO.md](TODO.md) for the feature roadmap. See [PLAN.md](PLAN.md) for the home_screen.dart refactoring plan (largely completed).

## Commands

```
flutter run                # launch on connected device/emulator
flutter test               # run all tests (282 total)
flutter analyze            # static analysis (uses package:flutter_lints)
dart format .              # format all Dart files
```

## Structure

### lib/

#### Entry point
- `lib/main.dart` — app entrypoint (TwitchChatApp with theme mode, injectable services, foreground task init)

#### Models
- `lib/models/twitch_message.dart` — chat message data class (reply threading, metadata)
- `lib/models/generic_emote.dart` — cross-provider emote model (Twitch/BTTV/FFZ/7TV, zero-width, scale, aspectRatio)
- `lib/models/twitch_badge.dart` — BadgeVersion, BadgeSet, MessageBadge data classes

#### Screens
- `lib/screens/home_screen.dart` — 1753‑line main screen: multi‑channel layout, EventSub + IRC integration, reply threads, mentions/whispers view, message input, system messages, chat room state, user profiles, emote menu, autocomplete
- `lib/screens/settings_screen.dart` — full-screen settings (dark mode toggle, Twitch credentials, channel management, injectable OAuth starter)
- `lib/screens/benchmark_screen.dart` — message latency benchmark UI (sends test messages, measures EventSub/IRC delivery times)

#### Services
- `lib/services/twitch_auth.dart` — credential holder (client ID + access token), persistence via SharedPreferences
- `lib/services/twitch_oauth.dart` — OAuth implicit grant flow (browser-based login, fragment parsing)
- `lib/services/twitch_api.dart` — Twitch Helix API calls (user lookup, EventSub subscription, chat commands) with injectable `http.Client`
- `lib/services/twitch_eventsub.dart` — EventSub WebSocket transport, message parsing, keepalive; exposes `handleRawMessage()` and `emitConnected()` for tests
- `lib/services/twitch_irc.dart` — IRC WebSocket for send commands; exports `parseIrcMessage`
- `lib/services/twitch_irc_read.dart` — read-only IRC connection for own-message detection and user color updates
- `lib/services/recent_messages.dart` — recent‑messages.robotty.de client; exports `RecentMessagesService.parseIrcLine`
- `lib/services/chat_connection_manager.dart` — 1004‑line central orchestrator: connection lifecycle, message routing, pending-message tracking, duplicate detection, chat status
- `lib/services/command_handler.dart` — IRC command dispatcher (`/me`, `/color`, `/ban`, `/timeout`, `/unban`, `/delete`, `/clear`, `/announce`, `/shoutout`) via Helix API + IRC fallback
- `lib/services/emote_manager.dart` — `ChangeNotifier`-based emote caching with TTL per provider (Twitch/BTTV/FFZ/7TV global + channel); exposes `ChannelEmotes` per channel
- `lib/services/seven_tv_event_client.dart` — 7TV live emote update WebSocket client (add/remove/rename events)
- `lib/services/twitch_badge_service.dart` — global + channel badge fetching from Twitch API
- `lib/services/user_store.dart` — recent chatter tracking per channel (LRU, max 5000)
- `lib/services/foreground_task.dart` — Android foreground service keepalive via `flutter_foreground_task`
- `lib/services/suggestion.dart` — `getCurrentWord`, `replaceCurrentWord`, and `Suggestion` sealed class hierarchy (emote/user command autocomplete)

#### Emote providers
- `lib/services/emote_providers/twitch_emotes.dart` — Twitch global + user emotes via Helix API
- `lib/services/emote_providers/bttv_emotes.dart` — BTTV global + channel emotes
- `lib/services/emote_providers/ffz_emotes.dart` — FFZ global + channel emotes
- `lib/services/emote_providers/seven_tv_emotes.dart` — 7TV global + channel emotes

#### Widgets
- `lib/widgets/chat_message_tile.dart` — reusable chat message tile (badges, text spans, timestamps, tap/long-press handlers)
- `lib/widgets/emote_text.dart` — emote-aware text rendering with inline image spans, clickable links, zero-width overlay support
- `lib/widgets/emote_sheet.dart` — emote detail bottom sheet (copy/share/trackpad)
- `lib/widgets/emote_menu_panel.dart` — emote selection panel with provider tabs (Twitch/BTTV/FFZ/7TV) in a draggable scrollable sheet
- `lib/widgets/thread_panel.dart` — reply thread panel with input box
- `lib/widgets/mentions_panel.dart` — mentions + whispers filtered view
- `lib/widgets/tabbed_layout.dart` — swipeable tab layout with custom physics for channel switching
- `lib/widgets/message_input.dart` — chat input box with reply indicator, send button, emote toggle
- `lib/widgets/user_profile_sheet.dart` — user profile bottom sheet (PFP, display name, created date, Mention/Whisper/Block/Report buttons)
- `lib/widgets/login_webview.dart` — OAuth WebView for browser-based login
- `lib/widgets/autocomplete_dropdown.dart` — autocomplete dropdown for emotes/users/commands
- `lib/widgets/settings.dart` — shared settings button (navigates to settings screen)

#### Utilities
- `lib/color_utils.dart` — Twitch username color picking, luminance/contrast helpers
- `lib/twitch_config.dart` — compile‑time Client ID constant
- `lib/util/text_bypass.dart` — text duplication bypass helpers for anti-duplicate send detection

#### Benchmark
- `lib/benchmark/message_latency_benchmark.dart` — sends test messages via Helix, measures EventSub vs IRC delivery latency

### test/

#### test/unit/
- `color_utils_test.dart` — 21 tests: color picking, luminance, contrast, ensureContrast
- `emote_manager_test.dart` — emote manager state, GenericEmote creation, relativeScale/aspectRatio JSON round-trip
- `emote_text_test.dart` — text parsing with emotes, segment building, whole-token matching, zero-width overlays
- `twitch_auth_test.dart` — 6 tests: credential persistence and accessors
- `twitch_config_test.dart` — 2 tests: client ID constant
- `twitch_message_test.dart` — 3 tests: model creation and reply threading
- `chat_connection_manager_test.dart` — connection manager tests (pending messages, duplicate detection, channel subscription)
- `seven_tv_event_client_test.dart` — 7TV WebSocket protocol tests (hello, emote-set update, reconnect)
- `suggestion_filter_test.dart` — suggestion filtering/relevance tests
- `current_word_test.dart` — getCurrentWord edge cases (spaces, punctuation, empty, cursor at bounds)
- `text_bypass_test.dart` — bypassTextDuplicate and normalizeForReconciliation tests
- `user_store_test.dart` — UserStore add/retrieve/remove/capacity tests
- `twitch_oauth_test.dart` — OAuth fragment parsing tests

#### test/data/
- `twitch_eventsub_test.dart` — 20 tests: EventSub routing for all message types (channel.chat.message, channel.channel_points_custom_reward_redemption.add, channel.ban, channel.message_delete, channel.subscribe, channel.subscription.gift, channel.subscription.message, channel.cheer, channel.raid, channel.chat.user_message_hold)
- `twitch_api_test.dart` — 15 tests: Helix API calls (getUser, createEventSubSubscription, deleteEventSubSubscription, getEventSubSubscriptions, sendChatMessage) with MockClient
- `twitch_irc_test.dart` — 9 tests: IRC message parsing (PRIVMSG, CLEARCHAT with/without duration, NOTICE, JOIN, PART, PING, WHO)
- `recent_messages_test.dart` — 9 tests: Robotty IRC line parsing (TwitchMessage creation, ban/timeout, highlights)

#### test/widgets/
- `widget_test.dart` — 40+ tests: main screen renders, channel bar, reply threads (10), system messages (7), settings screen (7), connected/disconnected dedup, join channel dialog, message cutoff, autocomplete, emote menu
- `channel_bar_test.dart` — channel bar rendering, selection, underline painting, font weight, disappearance
- `home_screen_test.dart` — 8 tests: channel subscription, tab switching, message display, thread navigation
- `draggable_scrollable_sheet_spike_test.dart` — draggable scrollable sheet interaction tests

## Test naming convention

- Widget tests in `test/widgets/widget_test.dart`
- Unit tests for each service/model file named `test/unit/<file_name>_test.dart`
- Integration/high-level tests in `test/widgets/home_screen_test.dart`

## Setup

1. Open `lib/twitch_config.dart` and replace `YOUR_CLIENT_ID_HERE` with your Twitch app's Client ID (get one at https://dev.twitch.tv/console/apps, set redirect URI to `http://localhost:17563`).

## Notes

- Dart SDK `^3.12.2`, Flutter stable channel
- No custom lint rules; uses `package:flutter_lints/flutter.yaml`
- No codegen, migrations, or build artifacts to manage
- Standard Flutter `.gitignore` in use
- `parseIrcMessage` (top-level in `twitch_irc.dart`) and `RecentMessagesService.parseIrcLine` (public static) are exposed for unit testing
- `TwitchApi` uses `http.Client _client` with `@visibleForTesting set client()` for MockClient injection
- `EventSubService` exposes `@visibleForTesting void handleRawMessage(Map<String, dynamic>)` and `@visibleForTesting void emitConnected()` for test injection
- `SettingsScreen` accepts optional `OAuthStarter? oAuthStarter` param for mocking OAuth
- `TwitchChatApp` accepts optional `EventSubService`, `IrcService`, `IrcReadService`, `RecentMessagesService`, `SevenTvEventClient`, `initialCurrentUserLogin` for injection
- `HomeScreen` accepts optional `EventSubService`, `IrcService`, `IrcReadService`, `RecentMessagesService`, `SevenTvEventClient`, `initialCurrentUserLogin` for injection
- `ChatConnectionManager` orchestrates EventSub, IRC, IRC read, recent messages, emote manager, badge service, and user store — instantiated inside `HomeScreen`
- `EmoteManager` is a `ChangeNotifier` — subscribe via `addListener`/`ListenableBuilder` for UI updates
- `BenchmarkScreen` accepts `TwitchAuth`, `availableChannels`, and `eventSubMessages` stream
- `SevenTvEventClient` is a standalone WebSocket client (not injected by default in tests)
- `IrcReadService` is a separate read-only IRC connection (distinct from `IrcService` which handles sends)
- `StreamController.broadcast()` uses `sync: true` for synchronous event delivery in tests

## Consistency

When adding or modifying UI, keep patterns consistent across the codebase:
- **Long-press menus**: Use `InkWell` (not `GestureDetector`) for `onLongPress` handlers on messages. `InkWell` provides `HitTestBehavior.opaque` by default, which works correctly inside `ListView.builder`. `GestureDetector` defaults to `deferToChild` and can silently fail in scrollable contexts.
- **Message rendering**: The main chat (`_buildChat`) and thread panel (`ThreadPanelWidget`) are separate code paths. When adding message features (long-press menus, tap handlers, layout), apply the same pattern to both.
- **Test coverage**: When fixing a gesture or interaction bug, add a test that reproduces the exact gesture (e.g., `tester.longPress`) in the affected context (e.g., inside the thread panel, not just the main chat).
- **Emote providers**: Each provider (`emote_providers/*`) implements static `fetchGlobal()` and `fetchChannel(channelId)` returning `List<GenericEmote>`. Priority order for dedup: 7TV > BTTV > FFZ > Twitch.
- **Autocomplete**: `Suggestion` is a sealed class with `EmoteSuggestion` and `UserSuggestion` subtypes. Use `getCurrentWord`/`replaceCurrentWord` from `suggestion.dart`.

## Bug fixes

When fixing a notable bug, write a test that reproduces it before applying the fix. Add the test to the relevant `test/` file or create a new one following the naming convention.

## Refactoring status

See [PLAN.md](PLAN.md) for the detailed home_screen.dart split plan. Key milestones:
- **Stage 1** (extract widgets): Completed — all 6 widget classes extracted to `lib/widgets/`
- **Stage 2** (command handler): Completed — `CommandHandler` lives in `lib/services/command_handler.dart`
- **Stage 3** (connection manager): Completed — `ChatConnectionManager` lives in `lib/services/chat_connection_manager.dart`
- **Stage 4** (cleanup): `home_screen.dart` reduced from ~3847 to 1753 lines
