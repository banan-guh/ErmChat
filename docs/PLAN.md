## Group 1: obvious fix, no tradeoff

13. `[med]` Mod View rebuilds all kept-alive tabs on every thread reply. `home_screen.dart:1078`
17. `[low]` Stream play/pause flips rebuild the whole home body. `stream_layout.dart:145`
19. `[low]` Mod loaders fire duplicate concurrent requests; dedupe in flight. `scope.dart:97`
20. `[low]` Thread panel builds a whole-buffer parent map, then usually discards it. `panel_manager.dart:478`
21. `[low]` Emote menu re-merges and re-sorts the catalog per rebuild. `emote_store.dart:530`
26. `[low]` Catalog save JSON-encodes on the main isolate (load already offloads). `emote_persistence.dart:106`
30. `[med]` Mod tabs build every row eagerly; use `ListView.builder`. `users_tab.dart`, `queue_tab.dart`
31. `[low]` Usage flush spawns an isolate for a small encode; encode inline. `emote_usage_registry.dart:346`
32. `[low]` Highlight tint math (16-step search) per row build; memoize. `chat_message_tile.dart:483`
35. `[low]` PiP callbacks never unbound on dispose (latent leak). `home_screen.dart:633` [X] 
36. `[low]` `Listenable.merge` / timer allocated per build or frame in sheets. `user_sheet.dart:272`, `user_profile_sheet.dart:165`, `home_app_bar.dart:115`
37. [VER] `[low]` Dead field `hasEverAttached`. `stream_player_controller.dart:34` [X] // kept as example

## Group 2: obvious fix, but a tradeoff

1. [VER] `[high]` **Stream player reloads on rotate, theater, PiP in/out**: `ValueKey` across different parents, so the WebView remounts (rebuffer, often a fresh pre-roll). Fix with a `GlobalKey`. Tradeoff: moving a platform view to a new parent can be flaky on Android; needs device testing. `stream_layout.dart:181` [X]
2. [VER] `[med]` **Analytics tokenizes every message even if never opened** (x3). Tradeoff: gating means stats start only once enabled. `analytics_service.dart:121`
3. `[med]` Hidden thread and mentions panels rebuild their rows on every home rebuild (x2). Tradeoff: unmounting resets their scroll position. `threads.dart:544`, `mentions.dart:242`
4. `[low]` History refetched for every channel on every reconnect. Tradeoff: a throttle delays missed-message recovery while flapping. `chat_lifecycle.dart:280`
5. [VER] `[med]` Watchdog PINGs both sockets every 30s, also in background. Tradeoff: battery vs slower zombie-socket detection. `chat_liveness.dart:41`
6. `[low]` Cold start waits on liquid glass shaders even with glass off. Tradeoff: first glass frame may show the fallback once. `main.dart:63`
7. [VER] `[low]` Stream status polled every 30s forever, also in background. Tradeoff: staler viewer count. `chat_status_composer.dart:157`
8. `[med]` Mod channel tab fetches every ban/mod/VIP unbounded into a non-lazy Column. Tradeoff: needs a "load more" flow. `channel_tab.dart:103`
9. `[low]` 1Hz cooldown timer runs all session. Tradeoff: armed on demand, a cooldown can appear up to 1s late. `composer_controller.dart:55`
10. `[low]` Boot history warm fetches all channels at once. Tradeoff: capping delays non-selected channels. `main.dart:104`
11. `[low]` Retroactive mention scan is synchronous at login and account switch. Tradeoff: mentions populate a frame later. `chat_history_controller.dart:177`
12. `[med]` Points queue re-fetches from Helix per redemption. Tradeoff: rendering from kernel state misses rewards from other clients. `points_section.dart:44`
13. `[low]` Split-view drag resizes the WebView every pointer move. Tradeoff: applying on release feels laggier. `stream_layout.dart:250`

## Group 3: murky

1. `[med]` A second decode pipeline for an emote whose row is only paused; the `_visible` guard looks deliberate. `emote_url_provider.dart:62`
2. `[high]` Startup gated on serialized secure-storage reads; the fix means anonymous-first connects and a reconnect. `main.dart:239`
3. `[med]` Own messages parsed and stamped twice; the fix touches event ordering. `chat_ingestion.dart:487`
4. `[med]` Decoded-frame cache can exceed its cap with many animated emotes on screen. `emote_url_provider.dart:229`
5. `[low]` PiP play/pause may target the wrong document inside the Twitch iframe (unverified). `stream_player_view.dart:114`
6. `[low]` `EmoteScaleResolver` always runs the async resolve, even when sync succeeded. `emote_scale_resolver.dart:55`
7. `[med]` `Messages.byId` O(n) scan for missing thread roots; a sentinel needs invalidation. `messages.dart:117`
8. `[low]` Third-party badge lookups may keep a POST cycle alive in busy chat. `third_party_badge_service.dart:214`
9. `[low]` Possibly redundant outer rebuild of the chat page per message. `channel_stack.dart:190`
10. `[low]` Glass clearance easing rebuilds the chat list per frame for ~220ms. `glass_chrome.dart:79`
11. `[low]` Hype train event without an expiry never shows a countdown (correctness). `chat_widget_cutout.dart:154`
12. `[med]` Thread-aware truncation makes ~7 buffer passes, coalesced to 4x/s. `messages.dart:588`
13. `[low]` Tab strip `ShaderMask` allocates a shader per repaint, if it repaints at all. `tabbed_layout.dart:511`
14. `[low]` `Messages.insert(0)` memmove; only matters at a large buffer cap. `messages.dart:139`
15. `[high]` Audio-only still decodes video; no fix short of a native audio player. `stream_layout.dart:44`
