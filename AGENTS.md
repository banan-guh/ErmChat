# ermchat

Twitch chat viewer (WIP). Single Flutter package, no monorepo.

See [TODO.md](TODO.md) for the feature roadmap. See [PLAN.md](PLAN.md) for the home_screen.dart refactoring plan (largely completed).

## Commands

```
flutter run                # launch on connected device/emulator
flutter test               # run all tests
flutter analyze            # static analysis (uses package:flutter_lints)
dart format .              # format all Dart files
```

## Structure

### lib/

#### Entry point
- `lib/main.dart` - app entrypoint (TwitchChatApp with theme mode, injectable services, foreground task init)

#### Models
- `lib/models/twitch_message.dart` - chat message data class (reply threading)
- `lib/models/generic_emote.dart` - cross-provider emote model (Twitch/BTTV/FFZ/7TV, zero-width, scale, aspectRatio)
- `lib/models/twitch_badge.dart` - BadgeVersion, BadgeSet, MessageBadge data classes

#### Screens
- `lib/screens/home_screen.dart` - 2234‑line main screen: multi‑channel layout, EventSub + IRC integration, reply threads, mentions/whispers view, message input, system messages, chat room state, user profiles, emote menu, autocomplete
- `lib/screens/settings/settings_screen.dart` - full-screen settings (dark mode toggle, Twitch credentials, channel management, injectable OAuth starter)
- `lib/screens/settings/analytics_screen.dart` - per-channel chat analytics (total messages, unique chatters, live msgs/min, top chatters/emotes/words, bans/timeouts) with a channel selector, raw-vs-stopword word toggle, and per-channel/all resets

#### Services
- `lib/services/twitch_auth.dart` - credential holder (client ID + access token), persistence via FlutterSecureStorage; also caches the logged-in `login`/`userId` so cold start skips the Helix user lookup (`setUser`, cleared by `setCredentials`/`clear`)
- `lib/services/twitch_oauth.dart` - OAuth implicit grant flow (browser-based login, fragment parsing)
- `lib/services/twitch_api.dart` - Twitch Helix API calls (user lookup, EventSub subscription creation, chat commands) with injectable `http.Client`
- `lib/services/twitch_eventsub.dart` - EventSub WebSocket transport for the moderation feed (channel.moderate v2 -> `onModeration`); keepalive, reconnect; exposes `handleRawMessage()`, `emitConnected()`, and `waitForSession()` for tests
- `lib/services/twitch_irc.dart` - IRC WebSocket: chat messages (`onMessage`), USERNOTICE subs/announcements/raids (`onUserNotice`), CLEARCHAT (bans/timeouts into `onBan`, full channel clears without a target into `onChannelClear`) and CLEARMSG (deletion) into `onMessageDeleted`, NOTICE, ROOMSTATE (`onRoomState`, feeds the chat status splash), USERSTATE/GLOBALUSERSTATE (`onUserState`/`onGlobalUserState`), jtv; exports `parseIrcMessage` and shared `parseIrcChatMessage`/`buildUserNoticeText`
- `lib/services/twitch_irc_read.dart` - read-only IRC connection for own-message detection
- `lib/services/recent_messages.dart` - recent‑messages.robotty.de client; exports `RecentMessagesService.parseIrcLine`
- `lib/services/chat_connection_manager.dart` - central orchestrator: connection lifecycle, message routing, duplicate detection, chat status (room modes from ROOMSTATE + stream info from a 60s Helix poll, composed in `_composeChatStatus`); IRC is the chat pipeline, EventSub is moderation-only (channel.moderate v2 subscribed in channels where the user is a moderator, `_moderationChannels` suppresses duplicate IRC CLEARCHAT/CLEARMSG/NOTICE copies while active); optional `onAnalyticsMessage`/`onAnalyticsModeration` callbacks feed the AnalyticsService from the live message funnel (history merges bypass these, so backfill never pollutes stats)
- `lib/services/analytics_service.dart` - `ChangeNotifier` per-channel chat stats accumulated live: total messages, unique chatters, top chatters, top emotes (Twitch positions + whole-token match against an injected `emoteLookup`, mirroring `EmoteText` semantics), top words with an optional stopword filter, a 60-minute rolling msgs/min window, and ban/timeout counters; no persistence, resets on app close or manually
- `lib/services/base_irc_connection.dart` - shared abstract base for IRC WebSocket connections (reconnect, ping/pong, auth, disposal)
- `lib/services/command_handler.dart` - command dispatcher (40+ commands: `/me`, `/color`, `/ban`, `/timeout`, `/unban`, `/untimeout`, `/delete`, `/clear`, `/announce` + color variants, `/mod` `/unmod` `/mods`, `/vip` `/unvip` `/vips`, chat modes `/slow` `/followers` `/emoteonly` `/subscribers` `/r9kbeta` `/uniquechat` + off variants, `/shoutout`, `/raid` `/unraid`, `/shield` `/shieldoff`, `/commercial`, `/marker`, `/w`, `/block` `/unblock`) via Helix API (`/me` is the only IRC command - Twitch deprecated the rest in Feb 2023); exposes `allCommands` (single source for / autocomplete, suggested to everyone regardless of permission - the API rejects with a clean error notice); failure notices follow DankChat wording (403 -> "You don't have permission to perform that action.", 401 -> "Missing required scope...", 429 -> rate-limit notice, other 4xx pass through the Helix message)
- `lib/services/emote_manager.dart` - `ChangeNotifier`-based emote caching with 24h TTL on wifi / 48h on cellular (connectivity_plus probe, cached 60s); TTL-gated fetches go through a serialized queue with a 1.5s stagger (the one-by-one "rake"); fresh caches skip the network entirely, Twitch channel emotes refresh in the background per open; `updateSevenTvEmotes` applies live WebSocket deltas
- `lib/services/seven_tv_event_client.dart` - 7TV live emote update WebSocket client (add/remove/rename events)
- `lib/services/twitch_badge_service.dart` - global + channel badge fetching from Twitch API
- `lib/services/user_store.dart` - recent chatter tracking per channel (LRU, max 5000)
- `lib/services/foreground_task.dart` - Android foreground service keepalive via `flutter_foreground_task`
- `lib/services/suggestion.dart` - `getCurrentWord`, `replaceCurrentWord`, and `Suggestion` sealed class hierarchy (emote/user/command autocomplete); `filterSuggestions` takes an optional `commands` list (slash words match commands only)

#### Emote providers
- `lib/services/emote_providers/twitch_emotes.dart` - Twitch global + user emotes via Helix API
- `lib/services/emote_providers/bttv_emotes.dart` - BTTV global + channel emotes
- `lib/services/emote_providers/ffz_emotes.dart` - FFZ global + channel emotes
- `lib/services/emote_providers/seven_tv_emotes.dart` - 7TV global + channel emotes

#### Widgets
- `lib/widgets/chat_message_tile.dart` - reusable chat message tile (badges, text spans, timestamps, tap/long-press handlers)
- `lib/widgets/emote_text.dart` - emote-aware text rendering with inline image spans, clickable links, zero-width overlay support
- `lib/widgets/emote_sheet.dart` - emote detail bottom sheet (copy/share/trackpad)
- `lib/widgets/emote_menu_panel.dart` - emote selection panel with provider tabs (Twitch/BTTV/FFZ/7TV) in a draggable scrollable sheet
- `lib/widgets/thread_panel.dart` - reply thread panel with input box
- `lib/widgets/mentions_panel.dart` - mentions + whispers filtered view
- `lib/widgets/tabbed_layout.dart` - swipeable tab layout with custom physics for channel switching
- `lib/widgets/message_input.dart` - chat input box with reply indicator, send button, emote toggle
- `lib/widgets/user_profile_sheet.dart` - user profile bottom sheet (PFP, display name, created date, Mention/Whisper/Block/Report buttons)
- `lib/widgets/autocomplete_dropdown.dart` - autocomplete dropdown for emotes/users/commands
- `lib/widgets/settings.dart` - shared settings button (navigates to settings screen)

#### Utilities
- `lib/color_utils.dart` - Twitch username color picking (`pickColor`, `parseColor`, `normalizeColor`)
- `lib/twitch_config.dart` - compile‑time Client ID constant
- `lib/util/text_bypass.dart` - text duplication bypass helpers for anti-duplicate send detection

### test/

#### test/unit/
- `color_utils_test.dart` - 15 tests: color picking, luminance, normalizeColor
- `emote_manager_test.dart` - emote manager state, GenericEmote creation, relativeScale/aspectRatio JSON round-trip
- `emote_text_test.dart` - text parsing with emotes, segment building, whole-token matching, zero-width overlays
- `twitch_auth_test.dart` - 9 tests: credential persistence and accessors
- `twitch_config_test.dart` - 1 test: client ID constant
- `twitch_message_test.dart` - 3 tests: model creation and reply threading
- `chat_connection_manager_test.dart` - connection manager tests (pending messages, duplicate detection, channel subscription)
- `seven_tv_event_client_test.dart` - 7TV WebSocket protocol tests (hello, emote-set update, reconnect)
- `suggestion_filter_test.dart` - suggestion filtering/relevance tests
- `current_word_test.dart` - getCurrentWord edge cases (spaces, punctuation, empty, cursor at bounds)
- `text_bypass_test.dart` - bypassTextDuplicate tests
- `command_handler_test.dart` - slash command tests (ban/timeout/unban/untimeout/delete/clear/announce/shoutout/color, mod/vip, chat modes, commercial/raid/shield/marker/whisper, block/unblock, Helix success, DankChat-style failure reporting, exception handling)
- `user_store_test.dart` - UserStore add/retrieve/remove/capacity tests
- `analytics_service_test.dart` - AnalyticsService counter accuracy, system/history/backfill exclusion, emote + word tokenization against a fake emote map, stopword filter, 60-min msgs/min rolloff (injected clock), moderation counts, resets, listener notification
- `twitch_oauth_test.dart` - OAuth fragment parsing tests
- `twitch_eventsub_service_test.dart` - EventSub service tests
- `twitch_irc_service_test.dart` - IRC service tests
- `twitch_irc_read_service_test.dart` - IRC read service tests
- `mention_test.dart` - isMention edge cases (case, punctuation, substrings, empty)

#### test/data/
- `twitch_eventsub_test.dart` - EventSub channel.moderate v2 routing tests (ban/timeout with duration/delete/clear, shared_chat mapping, unknown subscription types dropped)
- `twitch_api_test.dart` - 38 tests: Helix API calls (getUser, createEventSubSubscription, deleteEventSubSubscription, getEventSubSubscriptions, sendChatMessage, ban/unban, block/unblock, mods/vips, chat settings, commercial/raid/shield/marker/whisper, error capture) with MockClient
- `twitch_irc_test.dart` - IRC message parsing (PRIVMSG, USERNOTICE, CLEARCHAT with/without duration, CLEARMSG, NOTICE, JOIN, PART, PING, WHO)
- `recent_messages_test.dart` - Robotty IRC line parsing (TwitchMessage creation, ban/timeout, USERNOTICE subs/announcements, highlights)

#### test/widgets/
- `widget_test.dart` - 40+ tests: main screen renders, channel bar, reply threads (10), system messages (7), settings screen (7), connected/disconnected dedup, join channel dialog, message cutoff, autocomplete, emote menu
- `channel_bar_test.dart` - channel bar rendering, selection, underline painting, font weight, disappearance
- `user_profile_sheet_test.dart` - profile sheet report button URL/launch failure
- `draggable_scrollable_sheet_spike_test.dart` - draggable scrollable sheet interaction tests
- `analytics_screen_test.dart` - analytics screen rendering, channel selector, stopword toggle, per-channel reset, moderation display

## Test naming convention

- Widget tests in `test/widgets/widget_test.dart`
- Unit tests for each service/model file named `test/unit/<file_name>_test.dart`
- Integration/high-level tests in `test/widgets/widget_test.dart`

## Setup

1. Open `lib/twitch_config.dart` and replace `YOUR_CLIENT_ID_HERE` with your Twitch app's Client ID (get one at https://dev.twitch.tv/console/apps, set OAuth Redirect URL to `https://banan-guh.github.io/twitch-app-oauth/`).

## Notes

- Dart SDK `^3.12.2`, Flutter stable channel
- No custom lint rules; uses `package:flutter_lints/flutter.yaml`
- No codegen, migrations, or build artifacts to manage
- Standard Flutter `.gitignore` in use
- `parseIrcMessage` (top-level in `twitch_irc.dart`), `parseIrcChatMessage` (shared PRIVMSG -> `TwitchMessage`), `buildUserNoticeText` (USERNOTICE system text), and `RecentMessagesService.parseIrcLine` (public static) are exposed for unit testing
- `TwitchApi` uses `http.Client _client` with `@visibleForTesting set client()` for MockClient injection
- `EventSubService` exposes `@visibleForTesting void handleRawMessage(Map<String, dynamic>)`, `@visibleForTesting void emitConnected()`, and `@visibleForTesting Future<String?> waitForSession()` for test injection
- `IrcService` exposes `@visibleForTesting emitChatMessage(TwitchMessage)` and `@visibleForTesting emitUserNotice(UserNoticeEvent)` for chat/USERNOTICE injection
- `SettingsScreen` accepts optional `OAuthStarter? oAuthStarter` param for mocking OAuth
- `AccountScreen` accepts optional `TwitchApi? twitchApi` param for mocking the "Connected as {login}" user lookup
- `TwitchChatApp` accepts optional `EventSubService`, `IrcService`, `IrcReadService`, `RecentMessagesService`, `initialCurrentUserLogin` for injection
- `HomeScreen` accepts optional `EventSubService`, `IrcService`, `IrcReadService`, `RecentMessagesService`, `initialCurrentUserLogin` for injection
- `ChatConnectionManager` orchestrates EventSub, IRC, IRC read, recent messages, emote manager, badge service, and user store - instantiated inside `HomeScreen`
- IRC is the chat pipeline (PRIVMSG + USERNOTICE + CLEARCHAT/CLEARMSG/NOTICE); EventSub carries only `channel.moderate` v2 (moderation actions) in channels where the subscription succeeds (i.e. the user is a moderator) - see `_moderationChannels`
- The OAuth URL intentionally omits EventSub-only scopes (`user:read:chat`, `channel:moderate`); it includes the `moderator:read:*` scopes required by `channel.moderate` v2
- `EmoteManager` is a `ChangeNotifier` - subscribe via `addListener`/`ListenableBuilder` for UI updates
- Announcements (DankChat-style) render as two rows on the `msg-param-color` accent: the announcement text as a normal child chat message (emotes, badges, username) followed by the "Announcement" label system message; history (`recent_messages`) mirrors this via `parseAnnouncementChild` + a 1ms label timestamp offset, and `applyBanSweep` keys on `isBanNotice` so announcements never trigger deletions
- Full-channel `/clear` arrives as CLEARCHAT with no target user -> `onChannelClear` -> "Chat was cleared." + all non-system messages marked deleted (skipped in `_moderationChannels` where EventSub `clear` handles it); history CLEARMSG lines mark the target message deleted via `clearMsgTargetId`/`applyMessageDeletions`, and NOTICE lines parse into system messages
- `SevenTvEventClient` is a standalone WebSocket client (not injected by default in tests)
- `IrcReadService` is a separate read-only IRC connection (distinct from `IrcService` which handles sends); exposes `@visibleForTesting void emitOwnMessage(IrcMessage)` for simulating own-message echoes
- `ChatConnectionManager` orchestrates EventSub, IRC, IRC read, recent messages, emote manager, badge service, and user store - instantiated inside `HomeScreen`
- `StreamController.broadcast()` uses `sync: true` for synchronous event delivery in tests

## Consistency

When adding or modifying UI, keep patterns consistent across the codebase:
- **Long-press menus**: Use `InkWell` (not `GestureDetector`) for `onLongPress` handlers on messages. `InkWell` provides `HitTestBehavior.opaque` by default, which works correctly inside `ListView.builder`. `GestureDetector` defaults to `deferToChild` and can silently fail in scrollable contexts.
- **Message rendering**: The main chat (`_buildChat`) and thread panel (`ThreadPanelWidget`) are separate code paths. When adding message features (long-press menus, tap handlers, layout), apply the same pattern to both.
- **Test coverage**: When fixing a gesture or interaction bug, add a test that reproduces the exact gesture (e.g., `tester.longPress`) in the affected context (e.g., inside the thread panel, not just the main chat).
- **Emote providers**: Each provider (`emote_providers/*`) implements static `fetchGlobal()` and `fetchChannel(channelId)` returning `List<GenericEmote>` (exception: 7TV exposes `fetchChannelResponse` since it needs the emote-set ID; `fetchChannel` is omitted there). Priority order for dedup: 7TV > BTTV > FFZ > Twitch.
- **Autocomplete**: `Suggestion` is a sealed class with `EmoteSuggestion`, `UserSuggestion`, and `CommandSuggestion` subtypes. Use `getCurrentWord`/`replaceCurrentWord` from `suggestion.dart`. Slash words match commands only; the caller passes `CommandHandler.allCommands` (all commands, no permission filter).
- **NO em-dashes on new additions**: self-explanatory. Refrain from non-ASCII when writing code unless strictly necessary.

## Refactoring status

See [PLAN.md](PLAN.md) for the detailed home_screen.dart split plan. Key milestones:
- **Stage 1** (extract widgets): Completed - all 6 widget classes extracted to `lib/widgets/`
- **Stage 2** (command handler): Completed - `CommandHandler` lives in `lib/services/command_handler.dart`
- **Stage 3** (connection manager): Completed - `ChatConnectionManager` lives in `lib/services/chat_connection_manager.dart`
- **Stage 4** (cleanup): `home_screen.dart` reduced from ~3847 to 2234 lines
