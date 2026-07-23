# Investigation Results

## Reconnect System — **Bugged**

There are **8 bugs** in the reconnect system, several critical/severe. Here's a summary:

### Critical/High

| # | Bug | File |
|---|---|---|
| 1 | `EventSubService` has no `_disposed` guard — pending reconnect Timers survive `dispose()` and re-open WebSockets on a dead service | `twitch_eventsub.dart:118` |
| 2 | `Timer`/`Future.delayed` in all 3 services is never stored/cancelled — stale reconnect timers fire after external `connect()`/`disconnect()`, causing **duplicate connections** | `twitch_eventsub.dart:128`, `twitch_irc.dart:135`, `twitch_irc_read.dart:110` |
| 3 | Keepalive timeout calls `connect()` directly with **zero backoff** — tight reconnect loop every ~20s indefinitely if keepalives stop arriving | `twitch_eventsub.dart:199` |
| 4 | **No max retry limit** on EventSub, IRC, or IRC Read — they will reconnect forever even in permanently unrecoverable scenarios | all 3 service files |
| 5 | No guard against concurrent `connect()` calls — a keepalive-timeout `connect()` can race with a stream `onDone` → `_scheduleReconnect()` → new connect, creating duplicate connections | all 3 service files |
| 6 | `ChatConnectionManager.connect()` has no guard against repeated calls — if called twice (initState + settings close), spawns duplicate WebSocket connections | `chat_connection_manager.dart:610` |

### Medium
| 7 | `_reconnectAttempt` not reset in `_disconnect()` — stale backoff state carries over to new manual connections in IRC services | `twitch_irc.dart:111` |
| 8 | `_reconnectAttempt` reset logic inconsistent between URL/non-URL connect paths in EventSub | `twitch_eventsub.dart:82-83` |

**Key takeaway**: Bugs 2 and 3 together are the most dangerous. If keepalives stop, you get a reconnect at a fixed ~20s interval. If a disconnect also triggers `_scheduleReconnect`, the stale timer from bug 2 fires mid-connection and creates a second connection, which itself may fail and start its own timer — amplifying into a cascade.

---

## Twitch Emote Loading — Mostly Okay, Some Issues

Emote loading **is asynchronous and non-blocking** at the UI level, but has performance concerns:

| Severity | Issue | Location |
|---|---|---|
| Medium-High | **Mass `cachedSpans` invalidation**: when emotes change, ALL message spans across ALL channels are set to null — forces re-computation of every visible message's spans on next frame, potentially causing jank | `home_screen.dart:384-389` |
| Medium | **Sequential provider fetching**: Twitch, BTTV, FFZ, 7TV fetched one-by-one with `await`. A slow Twitch Helix API call blocks all other providers | `emote_manager.dart:364-376` |
| Medium | **`DefaultCacheManager` limit of 200 files**: with thousands of emotes from 4 providers, cache thrashing is possible | `emote_manager.dart:507` |
| Medium | **No `cacheWidth`/`memCacheWidth`**: emote images decoded at full resolution (3x scale from CDN) but displayed at ~28px — wastes GPU memory | `emote_text.dart:228,250,264` |
| Low | **Twitch emotes excluded from SharedPreferences persistence**: metadata must be re-fetched on every restart (images are still disk-cached) | `emote_manager.dart:452` |

**Key takeaway**: Image loading is properly async via `CachedNetworkImage`. The main performance risk is the mass span invalidation when emotes finish loading, which forces all visible messages to rebuild their spans synchronously. No dedicated image cache/config is used — just `DefaultCacheManager` defaults.