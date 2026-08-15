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
- `lib/models/twitch_command.dart` - `TwitchCommand` data class (name only; `allCommands` in command_handler lists all of them)
- `lib/models/emote_fetch_tier.dart` - `EmoteFetchTier` (nothing/low/medium/high) with label/subtitle/resolution + pref keys `emote_fetch_tier` / `emote_cache_max` (default 500, 0-2000), `EmoteFetchAutoMode` (off/balanced/aggressive, default balanced) with labels/subtitles + `emote_fetch_auto` pref key via `effectiveEmoteFetchTier` (a connectivity resolver used by home_screen's `_reconcileEmoteTier`)

#### Screens
- `lib/screens/home_screen.dart` - 2941‑line main screen: multi‑channel layout, EventSub + IRC integration, reply threads, mentions/whispers view (Mentions + Whispers tabs; the Whispers tab composes whispers - plain text replies to the latest whisper partner, `/w` commands route through the command handler), message input, system messages, chat room state, user profiles, emote menu, autocomplete, broadcaster chat widgets, welcome dialog
- `lib/screens/settings/settings_screen.dart` - settings hub listing sub-screens (Channels, Customization, Chat, Analytics, Account, About)
- `lib/screens/settings/channel_settings_screen.dart` - channel management (add/leave/reorder)
- `lib/screens/settings/customization_screen.dart` - theme (light/dark, true-dark), keep-screen-on, accent color
- `lib/screens/settings/chat_settings_screen.dart` - message cutoff (log-scaled slider over `kMaxMessagesPerChannelValues` 100-5000 in 100s/1000s, legacy values snap to the nearest step), recent-history limit, reply-to-root, background service, mention push, emote/username ordering, timestamps toggle + format; links to Pings
- `lib/screens/settings/emotes_settings_screen.dart` - emote fetching tier slider (applies immediately) + a three-way emote auto-mode switch (off/balanced/aggressive; locks the tier slider when on, connectivity-picked) + emote image cache slider with Apply button (draft value, not applied on drag; Apply sets the cap on the cache manager and runs `enforceNow()` immediately, so the footer reflects the new cap without waiting for the next emote fetch). Takes a live `mobileNotifier` (`ValueNotifier<bool>`) so while auto mode is on the tier slider tracks the effective tier that connectivity is currently picking (animated via `TweenAnimationBuilder` + `AnimatedSwitcher`, not a jump); footer (`emote_cache_footer`) shows the emote disk-cache usage (file count + bytes) via `EmoteCacheManager.stats()`
- `lib/screens/settings/pings_screen.dart` - custom alt-ping highlight words
- `lib/screens/settings/analytics_screen.dart` - per-channel chat analytics (total messages, unique chatters, live msgs/min, top chatters/emotes/words, bans/timeouts) with a channel selector, raw-vs-stopword word toggle, and per-channel/all resets
- `lib/screens/settings/account_screen.dart` - account login (browser OAuth or paste-token), "Connected as {login}", logout, and the account switcher: lists every saved account (avatar from the saved `profileImageUrl`, falling back to the first letter; tap to switch, long-press to remove with an "are you sure" dialog), plus Add account / Disconnect buttons
- `lib/screens/settings/about_screen.dart` - version info; 7-tap hidden entry to dev settings
- `lib/screens/settings/dev_settings_screen.dart` - test switches (e.g. force chat widgets) for development

#### Services
- `lib/services/twitch_auth.dart` - credential holder (client ID + access token), persistence via FlutterSecureStorage; multi-account: `accounts` (`List<TwitchAccount>` registry, JSON-serialized with a one-time migration from the legacy single-account keys) with `switchTo`/`removeAccount`/`clear` (disconnect removes the active account and falls back to the next one). The active account's credentials are exposed via `accessToken`/`refreshToken`/`login`/`userId`/`profileImageUrl` (the avatar, saved from the Helix user lookup on login); a freshly OAuth'd credential whose user isn't resolved yet is kept as a "pending" credential across restarts. A serialized storage queue prevents fire-and-forget writes from racing reads. Also caches the logged-in `login`/`userId` so cold start skips the Helix user lookup (`setUser`, cleared by `setCredentials`/`clear`)
- `lib/services/twitch_oauth.dart` - OAuth implicit grant flow (browser-based login, fragment parsing); `startFlow({bool ephemeral})` - ephemeral (cookie-less) sessions are used for the switch-account re-auth path so Twitch skips the "hi again - not you? log out" interstitial (whose app-link button can hand the flow to the installed Twitch app)
- `lib/services/twitch_api.dart` - Twitch Helix API calls (user lookup, EventSub subscription creation, chat commands) with injectable `http.Client`
- `lib/services/twitch_eventsub.dart` - EventSub WebSocket transport for the moderation feed (channel.moderate v2 -> `onModeration`) plus broadcaster-only chat widgets (hype train / poll / prediction); keepalive, reconnect; exposes `handleRawMessage()`, `emitConnected()`, and `waitForSession()` for tests
- `lib/services/twitch_irc.dart` - IRC WebSocket: chat messages (`onMessage`), USERNOTICE subs/announcements/raids (`onUserNotice`), CLEARCHAT (bans/timeouts into `onBan`, full channel clears without a target into `onChannelClear`) and CLEARMSG (deletion) into `onMessageDeleted`, NOTICE, ROOMSTATE (`onRoomState`, feeds the chat status splash), USERSTATE/GLOBALUSERSTATE (`onUserState`/`onGlobalUserState`), WHISPER (`onWhisper`, not channel-bound), jtv; exports `parseIrcMessage` and shared `parseIrcChatMessage`/`buildUserNoticeText`
- `lib/services/twitch_irc_read.dart` - read-only IRC connection for own-message detection
- `lib/services/recent_messages.dart` - recent‑messages.robotty.de client; exports `RecentMessagesService.parseIrcLine`
- `lib/services/chat_connection_manager.dart` - central orchestrator: connection lifecycle, message routing, duplicate detection, chat status (room modes from ROOMSTATE + stream info from a 60s Helix poll, composed in `_composeChatStatus`); IRC is the chat pipeline, EventSub is moderation-only (channel.moderate v2 subscribed in channels where the user is a moderator, `_moderationChannels` suppresses duplicate IRC CLEARCHAT/CLEARMSG/NOTICE copies while active); optional `onAnalyticsMessage`/`onAnalyticsModeration` callbacks feed the AnalyticsService from the live message funnel (history merges bypass these, so backfill never pollutes stats); truncation is coalesced for the per-message hot path (`_truncateWithCoalesce` defers the O(n) thread-aware `truncateChannelMessages` pass within a 250ms window, bounded by a 2x hard cap; `truncateNow`/`truncateCoalesceWindow` config is clock-injectable, default `clock.now()` so widget tests advance it via `tester.pump`)
- `lib/services/analytics_service.dart` - `ChangeNotifier` per-channel chat stats accumulated live: total messages, unique chatters, top chatters, top emotes (Twitch positions + whole-token match against an injected `emoteLookup`, mirroring `EmoteText` semantics), top words with an optional stopword filter, a 60-minute rolling msgs/min window, and ban/timeout counters; no persistence, resets on app close or manually
- `lib/services/base_irc_connection.dart` - shared abstract base for IRC WebSocket connections (reconnect, ping/pong, auth, disposal; public `disconnect({emitStatus})` for credential-change teardown)
- `lib/services/command_handler.dart` - command dispatcher (41 commands: `/me`, `/color`, `/ban`, `/timeout`, `/unban`, `/untimeout`, `/delete`, `/clear`, `/announce` + color variants, `/mod` `/unmod` `/mods`, `/vip` `/unvip` `/vips`, chat modes `/slow` `/followers` `/emoteonly` `/subscribers` `/r9kbeta` `/uniquechat` + off variants, `/shoutout`, `/raid` `/unraid`, `/shield` `/shieldoff`, `/commercial`, `/marker`, `/w`, `/block` `/unblock`) via Helix API (`/me` is the only IRC command - Twitch deprecated the rest in Feb 2023); `/w` is account-scoped (no broadcaster channel needed) and can route feedback into the whispers list via `whisperAddSystemMessage` plus a local echo through `onWhisperSent` (Twitch does not echo your own whispers); exposes `allCommands` (`List<TwitchCommand>`, single source for / autocomplete, suggested to everyone regardless of permission - the API rejects with a clean error notice); failure notices follow DankChat wording (403 -> "You don't have permission to perform that action.", 401 -> "Missing required scope...", 429 -> rate-limit notice, other 4xx pass through the Helix message)
- `lib/services/emote_manager.dart` - `ChangeNotifier`-based emote caching. The metadata TTL (12h wifi / 24h cellular on high, flat 24h on medium, infinite on low/nothing; connectivity_plus probe, cached 60s) is a *refresh* flag only - it re-runs the provider rake for stale channels, never wipes image files. TTL-gated fetches go through a serialized queue with a 1.5s stagger (the one-by-one "rake"); fresh caches skip the network entirely, Twitch channel emotes refresh in the background per open. `updateSevenTvEmotes` applies live WebSocket deltas; `_reconcileSevenTv` fetches the 7TV set once per launch on a fresh cache (medium/high only) and diffs it against the loaded cache to apply add/remove/rename deltas at startup. `markEmoteViewed` feeds the usage registry (chat messages via `emoteById` lookup in `ChatConnectionManager.onMessage` - history/backfill excluded - plus emote menu/autocomplete). The registry is a `Map<String, EmoteUsageRecord>` (last-used time + a rolling 24h hourly histogram, `EmoteUsageRecord` pure scoring: recency `exp(-h/6h)` + steady term `min(uses24h/50, 1) * entropy`, so steadily-used emotes outrank one-hour spam bursts; persisted as v2 JSON, trimmed by score to max(300, cap)). `cacheCap` forwards the settings cap to `EmoteCacheManager`; `startCacheGc` runs the one-time migrations and registers the registry as the cache's priority source
- `lib/services/emote_cache_manager.dart` - dedicated emote image disk cache singleton used by every emote render via `CachedNetworkImageProvider.defaultCacheManager`; never exceeds the settings cap (`maxObjects`): a write reserves a slot while the repo count (plus in-flight writes) is below the cap; when full it evicts the lowest-priority file first (`priorityScore` registry score, falling back to a recency decay from the file's stored time; candidates used/stored within the last 2s are skipped so a mid-read render is never deleted, serialized via an eviction tail), and only when nothing is evictable does it serve from an OS temp file (30s grace) instead of persisting. `isFull()` backs the precacher's skip decision. `enforceNow()` (settings Apply / startup) evicts down to a newly reduced cap with the same ordering; cap 0 evicts everything. The 2000-file/30d flutter_cache_manager config is a safety net only. `stats()` returns `EmoteCacheStats` (file count + total bytes) for the settings footer; a `forTesting` ctor accepts a custom `Config`
- `lib/services/seven_tv_event_client.dart` - 7TV live emote update WebSocket client (add/remove/rename events)
- `lib/services/twitch_badge_service.dart` - global + channel badge fetching from Twitch API
- `lib/services/user_store.dart` - recent chatter tracking per channel (LRU, max 5000)
- `lib/services/foreground_task.dart` - Android foreground service keepalive via `flutter_foreground_task`
- `lib/services/notification_service.dart` - local mention notifications via `flutter_local_notifications` (init, `showMentionNotification`, tap-to-channel via payload, clear on foreground)
- `lib/services/suggestion.dart` - `getCurrentWord`, `replaceCurrentWord`, and `Suggestion` sealed class hierarchy (emote/user/command autocomplete); `filterSuggestions` takes an optional `commands` list (slash words match commands only)

#### Emote providers
- `lib/services/emote_providers/twitch_emotes.dart` - Twitch global + user emotes via Helix API
- `lib/services/emote_providers/bttv_emotes.dart` - BTTV global + channel emotes
- `lib/services/emote_providers/ffz_emotes.dart` - FFZ global + channel emotes
- `lib/services/emote_providers/seven_tv_emotes.dart` - 7TV global + channel emotes

#### Widgets
- `lib/widgets/chat_message_tile.dart` - reusable chat message tile (badges, text spans, timestamps, tap/long-press handlers)
- `lib/widgets/chat_view.dart` - channel chat list view (scroll handling, message cutoff, keyed reconciliation; `idToIndex` for `findChildIndexCallback` is built only over cached tile ids, bounded by `_maxCachedTiles` rather than the whole channel buffer)
- `lib/widgets/message_builder.dart` - message widget construction shared by chat and threads (message spans cached per-message and validated against `EmoteManager.version` + `TwitchMessage.cachedSpansVersion`, so emote changes recompute lazily instead of clearing every message's spans)
- `lib/widgets/emote_image.dart` - emote renderer: thin stock-`Image` wrapper with a loading overlay (bare shimmer or cached smaller scale under a faint shimmer, expanded to fill the box via `_loadingStack`) driven by `frameBuilder`; memory-cached alternates seed the required URL's playback clock (`EmoteUrlProvider.seedPlayback`) so the swap continues the animation in phase; the decode stack (`decodeEmoteBytes`, animated WebP via native libwebp + pure-Dart fallback, `sniffEmoteFormat`/`webpIsAnimated`, `decodeWebpPureDart`) lives here too
- `lib/widgets/emote_image_provider.dart` - `EmoteUrlProvider` (URL-keyed `ImageProvider`, so the stock `ImageCache` dedups fetches and shares one playback stream per URL) + the Timer-driven frame-sequence completer (pauses when the last listener detaches, resumes on re-attach, frees frames in `onDisposed`, self-evicts on error so failed loads retry); `fetchEmoteBytes` (emote disk cache + memory overflow path) and the decode semaphore moved here. `seedPlayback(url, sourceUrl)` seeds a completer's playback start from another URL's current frame (a higher-res copy continues a cached smaller scale's animation in phase, applied when the frames land); the completer mirrors the engine completer's private frame counter (non-sync forwards only, `_engineCodec` captured for `frameCount`) so engine-path completers can report `currentFrameIndex`; animated GIFs are decoded through `decodeEmoteBytes` (own playback clock) instead of the engine completer only when a seed was requested
- `lib/widgets/emote_text.dart` - emote-aware text rendering with inline image spans, clickable links, zero-width overlay support
- `lib/widgets/emote_sheet.dart` - emote detail bottom sheet (copy/share/trackpad)
- `lib/widgets/emote_menu_panel.dart` - emote selection panel with provider tabs (Twitch/BTTV/FFZ/7TV) in a draggable scrollable sheet
- `lib/widgets/thread_panel.dart` - reply thread panel with input box
- `lib/widgets/mentions_panel.dart` - mentions + whispers filtered view (reused for both the Mentions and Whispers tabs; `emptyText` is customizable)
- `lib/widgets/tabbed_layout.dart` - swipeable tab layout with custom physics for channel switching
- `lib/widgets/message_input.dart` - chat input box with reply indicator, send button, emote toggle
- `lib/widgets/user_profile_sheet.dart` - user profile bottom sheet (PFP, display name, created date, Mention/Whisper/Block/Report buttons)
- `lib/widgets/autocomplete_dropdown.dart` - autocomplete dropdown for emotes/users/commands
- `lib/widgets/account_carousel.dart` - (removed; the account switcher now lives in `account_screen.dart`)
- `lib/widgets/chat_widget_cutout.dart` - fixed cutout above chat hosting broadcaster widget cards (hype train / poll / prediction; inner `PageView` slides only)
- `lib/widgets/join_channel_dialog.dart` - add-channel dialog
- `lib/widgets/welcome_dialog.dart` - first-run welcome dialog
- `lib/widgets/predictive_back_handler.dart` - predictive back gesture handling
- `lib/widgets/settings.dart` - shared settings button (navigates to settings screen)

#### Utilities
- `lib/color_utils.dart` - Twitch username color picking (`pickColor`, `parseColor`, `normalizeColor`)
- `lib/theme_colors.dart` - accent color presets + `kDefaultAccent` (shared by main.dart and customization screen)
- `lib/twitch_config.dart` - Client ID constant + OAuth redirect URI / callback scheme
- `lib/util/constants.dart` - shared constants (timeouts, prefs keys)
- `lib/util/mention.dart` - `isMention` / `isMentionOf` (word-boundary ping detection, shared by live/history/backfill scans)
- `lib/util/irc_utils.dart` - IRC parsing helpers
- `lib/util/sheet_drag.dart` - bottom sheet drag helpers
- `lib/util/thread_utils.dart` - reply thread helpers
- `lib/util/timestamp_formatter.dart` - timestamp formats + `formatTimestamp`
- `lib/util/text_bypass.dart` - text duplication bypass helpers for anti-duplicate send detection

### test/

#### test/helpers/
- `fake_cache_repo.dart` - in-memory `CacheInfoRepository` (seeded via `seed`, observable via `keys`) shared by the cache manager unit tests and the emote-settings widget test

#### test/unit/
- `color_utils_test.dart` - 18 tests: color picking, luminance, normalizeColor
- `emote_manager_test.dart` - 67 tests: EmoteUsageRecord scoring (just-used beats stale, steady beats one-hour spam burst, day-unused evicted, uniform beats clustered, window rollover, JSON round-trip), emote manager state, GenericEmote creation, relativeScale/aspectRatio JSON round-trip, per-tier TTL (12h/24h), cache cap + usage registry (cap forwarding, markEmoteViewed, registry persistence, precache-skip-at-0, one-time migrations), 7TV startup reconcile (add/remove/rename deltas, tier/broadcaster gating, failure swallow), 7TV live updates, nothing-tier no-fetch guards, tier-tag staleness
- `emote_cache_manager_test.dart` - 7 tests: inline cap enforcement (evicts to maxObjects by least-recently-touched, registry score overrides file touched time, cap 0 empties all, no-op under cap), write-time eviction (lowest score evicted, grace skips candidates, full-cache temp fallback), isFull false under the cap, via a fake repo
- `emote_image_test.dart` - 24 tests: format sniffing, animated-WebP dispatch fallback, production decode of the real fixtures, stock-Image widget behavior (placeholder/error/animation/shared fetch/sync re-render from cache/retry after failure, cached smaller-scale placeholder under shimmer)
- `native_emote_codec_test.dart` - 5 tests (gated on `EMOTE_CODEC_SO`): shim load/unavailable, decode equality vs the pure-Dart reference, garbage input, repeated-decode state sanity
- `message_builder_test.dart` - 2 tests: span cache reuse while emote version unchanged, lazy recompute on version bump
- `emote_text_test.dart` - 16 tests: text parsing with emotes, segment building, whole-token matching, zero-width overlays
- `twitch_auth_test.dart` - 9 tests: credential persistence and accessors
- `twitch_config_test.dart` - 1 test: client ID constant
- `twitch_message_test.dart` - 3 tests: model creation and reply threading
- `chat_connection_manager_test.dart` - 47 tests: connection manager (pending messages, duplicate detection, channel subscription, coalesced truncation, usage-registry feed from live messages, history excluded)
- `seven_tv_event_client_test.dart` - 24 tests: 7TV WebSocket protocol (hello, emote-set update, reconnect)
- `seven_tv_emotes_test.dart` - 11 tests: 7TV emote provider + resolution variants (no 4x)
- `twitch_emotes_resolution_test.dart` - 4 tests: Twitch resolution URL selection per tier (no 4x)
- `bttv_emotes_resolution_test.dart` - 3 tests: BTTV resolution variants (no 4x)
- `ffz_emotes_resolution_test.dart` - 4 tests: FFZ resolution variants (no 4x)
- `suggestion_filter_test.dart` - 15 tests: suggestion filtering/relevance
- `current_word_test.dart` - 13 tests: getCurrentWord edge cases (spaces, punctuation, empty, cursor at bounds)
- `emote_fetch_tier_test.dart` - 6 tests: effective tier resolver matrix (auto off passthrough, balanced wifi/cellular, aggressive wifi/cellular), labels/subtitles, prefs-key distinctness, default auto mode
- `text_bypass_test.dart` - 7 tests: bypassTextDuplicate
- `command_handler_test.dart` - 61 tests: slash commands (ban/timeout/unban/untimeout/delete/clear/announce/shoutout/color, mod/vip, chat modes, commercial/raid/shield/marker/whisper, block/unblock, Helix success, DankChat-style failure reporting, exception handling)
- `user_store_test.dart` - 7 tests: UserStore add/retrieve/remove/capacity
- `analytics_service_test.dart` - 15 tests: AnalyticsService counter accuracy, system/history/backfill exclusion, emote + word tokenization against a fake emote map, stopword filter, 60-min msgs/min rolloff (injected clock), moderation counts, resets, listener notification
- `twitch_oauth_test.dart` - 11 tests: OAuth fragment parsing
- `twitch_eventsub_service_test.dart` - 8 tests: EventSub service
- `twitch_irc_service_test.dart` - 23 tests: IRC service
- `twitch_irc_read_service_test.dart` - 4 tests: IRC read service
- `base_irc_connection_test.dart` - 18 tests: shared IRC connection base (reconnect, ping/pong, auth, disposal)
- `mention_test.dart` - 14 tests: isMention edge cases (case, punctuation, substrings, empty)
- `timestamp_formatter_test.dart` - 5 tests: timestamp formats + formatTimestamp
- `theme_test.dart` - 3 tests: light/dark theme building
- `predictive_back_handler_test.dart` - 3 tests: predictive back gesture handling

#### test/data/
- `twitch_eventsub_test.dart` - 16 tests: EventSub channel.moderate v2 routing (ban/timeout with duration/delete/clear, shared_chat mapping, unknown subscription types dropped)
- `twitch_api_test.dart` - 37 tests: Helix API calls (getUser, createEventSubSubscription, deleteEventSubSubscription, getEventSubSubscriptions, sendChatMessage, ban/unban, block/unblock, mods/vips, chat settings, commercial/raid/shield/marker/whisper, error capture) with MockClient
- `twitch_irc_test.dart` - 19 tests: IRC message parsing (PRIVMSG, USERNOTICE, CLEARCHAT with/without duration, CLEARMSG, NOTICE, JOIN, PART, PING, WHO)
- `recent_messages_test.dart` - 37 tests: Robotty IRC line parsing (TwitchMessage creation, ban/timeout, USERNOTICE subs/announcements, highlights)

#### test/widgets/
- `widget_test.dart` - 95 tests: main screen renders, channel bar, reply threads (10), system messages (7), settings screen (10), connected/disconnected dedup, join channel dialog, message cutoff, autocomplete, emote menu
- `channel_bar_test.dart` - 12 tests: channel bar rendering, selection, underline painting, font weight, disappearance
- `user_profile_sheet_test.dart` - 2 tests: profile sheet report button URL/launch failure
- `draggable_scrollable_sheet_spike_test.dart` - 2 tests: draggable scrollable sheet interaction
- `analytics_screen_test.dart` - 6 tests: analytics screen rendering, channel selector, stopword toggle, per-channel reset, moderation display
- `emote_sheet_test.dart` - 6 tests: emote detail sheet
- `chat_widget_cutout_test.dart` - 2 tests: broadcaster widget cutout rendering

## Test naming convention

- Widget tests in `test/widgets/widget_test.dart`
- Unit tests for each service/model file named `test/unit/<file_name>_test.dart`
- Integration/high-level tests in `test/widgets/widget_test.dart`

## Setup

1. Clone with submodules: `git clone --recursive <repo-url>` (or `git submodule update --init` in an existing checkout). `third_party/libwebp` (pinned v1.4.0) is required to build `libemote_codec`.
2. Open `lib/twitch_config.dart` and set `clientId` to your Twitch app's Client ID (get one at https://dev.twitch.tv/console/apps). Add the `redirectUri` (e.g. `https://banan-guh.github.io/twitch-app-oauth`) to your app's "OAuth Redirect URLs" - it must match exactly.

## Notes

- Dart SDK `^3.12.2`, Flutter stable channel; app version `0.5.1`
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
- IRC is the chat pipeline (PRIVMSG + USERNOTICE + CLEARCHAT/CLEARMSG/NOTICE); EventSub carries `channel.moderate` v2 (moderation actions) in channels where the user is a moderator plus the broadcaster-only chat widgets (hype train / poll / prediction) - see `_moderationChannels` / `_widgetChannels`
- The OAuth URL intentionally omits EventSub-only scopes (`user:read:chat`, `channel:moderate`); it includes the `moderator:read:*` scopes required by `channel.moderate` v2
- Chat widgets (hype train / poll / prediction) are broadcaster-only: `EventSubService` routes `channel.hype_train.*` v2, `channel.poll.*` v1, `channel.prediction.*` v1 into `onHypeTrain`/`onPoll`/`onPrediction`; `ChatConnectionManager._subscribeWidgets` only attempts them when the logged-in user is the broadcaster of the channel (`getCurrentUserId() == channelUserId`), with the same 403-skip + session-scoped active-set pattern as moderation. The OAuth URL includes the `channel:read:hype_train` / `channel:read:polls` / `channel:read:predictions` scopes (they only take effect for the broadcaster's own channels). Widgets render in the swipeable `ChatWidgetCutout`/`ChatWidgetMinimizedBar` (fixed cutout frame, only the inner `PageView` slides; per-channel state in `_hypeTrains`/`_polls`/`_predictions`/`_widgetsMinimized`, page reset on channel switch, cleanup in `_removeChannel`). Voting isn't supported (no public vote API), so poll/prediction cards are read-only
- `EmoteManager` is a `ChangeNotifier` - subscribe via `addListener`/`ListenableBuilder` for UI updates
- Announcements (DankChat-style) render as two rows on the `msg-param-color` accent: the announcement text as a normal child chat message (emotes, badges, username) followed by the "Announcement" label system message; history (`recent_messages`) mirrors this via `parseAnnouncementChild` + a 1ms label timestamp offset, and `applyBanSweep` keys on `isBanNotice` so announcements never trigger deletions
- Full-channel `/clear` arrives as CLEARCHAT with no target user -> `onChannelClear` -> "Chat was cleared." + all non-system messages marked deleted (skipped in `_moderationChannels` where EventSub `clear` handles it); history CLEARMSG lines mark the target message deleted via `clearMsgTargetId`/`applyMessageDeletions`, and NOTICE lines parse into system messages
- `SevenTvEventClient` is a standalone WebSocket client (not injected by default in tests)
- `IrcReadService` is a separate read-only IRC connection (distinct from `IrcService` which handles sends); exposes `@visibleForTesting void emitOwnMessage(IrcMessage)` for simulating own-message echoes
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
- **Stage 4** (cleanup): `home_screen.dart` reduced from ~3847 to 2941 lines (chat/thread rendering later extracted to `chat_view.dart`/`message_builder.dart`)
