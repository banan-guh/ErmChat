Here's the emote issue report:
Emote System Investigation Report
Critical
*C1 — Mass span invalidation on every emote change (home_screen.dart:384-391)
Whenever any emote finishes loading (any channel, any provider), _onEmotesChanged nulls cachedSpans on every single message across all channels, forcing full InlineSpan recomputation for the entire app. With N channels, startup triggers ~2N+2 full rebuilds via redundant notifyListeners() calls in the EmoteManager.
High
*H1 — No memCacheWidth/cacheWidth on emote images (emote_text.dart:228,250,264 + 5 other locations)
Emote CachedNetworkImage widgets decode images at full CDN resolution (3x, ~84-108px) while rendering at 28px. Wastes GPU memory, especially with 30+ visible messages × 2 emotes each.
*H2 — DefaultCacheManager default 200-file limit (emote_manager.dart:507)
No custom CacheManager config. The default evicts after 200 files, but 4 providers can easily exceed that → cache thrashing, re-downloading frequently used emotes.
*H3 — 7TV API called twice per channel join (emote_manager.dart:405 + chat_connection_manager.dart:471)
Same 7tv.io/v3/users/twitch/{id} endpoint hit once by _fetchAllChannel and again immediately by _resolveSevenTvAndSubscribe. Doubles API load.
*H4 — Sequential provider fetching (emote_manager.dart:367-374, 384-407)
Twitch → BTTV → FFZ → 7TV fetched with await. One slow provider blocks all others. Should use Future.wait.
Medium
M1 — cachedSpans stored without scale awareness (twitch_message.dart:39) — no recording of what textScale was used, could return stale wrong-scale spans on font size change.
M2 — Twitch emotes excluded from SharedPreferences (emote_manager.dart:447-464) — intentional but undocumented; always requires network on restart.
M3 — SharedPreferences.getInstance() called repeatedly — no cached instance, platform channel round-trip on every markEmoteUsed call.
M4 — Zero-width emote spacing logic fragile (emote_text.dart:70-95) — breaks with multiple spaces/tabs between base and zero-width emote.
M5 — No retry on failed emote fetches (emote_manager.dart:229-251) — transient network failure → channel has no emotes for the entire session.
M6 — putIfAbsent('', ...) silently drops orphaned emotes (twitch_emotes.dart:65) — null ownerId keys are skipped by _loadUserTwitchEmotes.
M7 — No HTTP timeout on any emote provider API call — any hanging server blocks the pipeline indefinitely.
Low
L1 — _emoteSheetCtrl listener added twice (home_screen.dart:217-221) — _onSheetSizeChanged fires twice per drag.
L2 — _onEmotesChanged doesn't push panel data (home_screen.dart:384-391) — thread/mentions panels may show stale spans until next unrelated _chatVersion bump.
L3 — channelNonTwitchEmotes excludes subscriber Twitch emotes (emote_manager.dart:98-103) — emote menu "Channel" tab may miss subscriber emotes.
L4 — Zero test coverage for EmoteManager class itself — no tests for resolveEmotes, preloadGlobalEmotes, _buildChannelMap priority logic, etc.
Recommended first targets (highest impact per effort):
1. C1 — Only invalidate spans for the specific channel whose emotes changed, and batch/coalesce notifyListeners() during startup to avoid redundant rebuilds.
2. H4 — Switch _fetchAllGlobal and _fetchAllChannel to Future.wait with eagerError: false.
3. H1 — Add memCacheWidth: width.toInt() to all emote CachedNetworkImage calls.
4. H3 — Deduplicate the 7TV API call by extracting the user lookup result from emote fetch.


Here's the optimization plan, ranked by ROI:
Findings: Performance & Memory Issues
Service Layer
#	Severity	File	Issue
1	HIGH	chat_connection_manager.dart:285-381	truncateChannelMessages is O(n) called per incoming message — builds reply graph + BFS traversal on every single message. 20 msg/s × 500 messages = 10,000 iterations/second
2	HIGH	chat_connection_manager.dart:45	ownMessageIds Set grows forever — entries only added, never removed. Long session = thousands of UUID strings leaked
3	HIGH	emote_manager.dart:482	_seenEmoteIds Set grows forever — every unique emote ID ever seen. Never cleaned
4	HIGH	chat_connection_manager.dart:847-848, home_screen:1253	mentionsChannel message list never truncated — explicitly skipped in the truncation loop
5	MEDIUM	chat_connection_manager.dart:41-42	pendingLocals / _pendingLocalsByNorm have no timeout — orphans persist if IRC echo never arrives
UI Layer
#	Severity	File	Lines	Issue
6	CRITICAL	home_screen.dart	1367	ListenableBuilder on _chatVersion rebuilds entire TabbedLayout + all pages on every message. 5-10 rebuilds/sec on active chat
7	CRITICAL	tabbed_layout.dart	206, 229	List.generate creates new widget lists every build — combined with #6, every message recreates all tabs + pages
8	CRITICAL	home_screen.dart	1942	GlobalKey allocation inside ListView.builder itemBuilder — map lookup + closure allocation per visible item per rebuild
9	HIGH	chat_message_tile.dart	82-84	New TapGestureRecognizer per tile per build
10	HIGH	chat_message_tile.dart	40-41	Timestamp formatted fresh on every build (calls toLocal() twice)
11	MEDIUM	home_screen.dart	365	filterSuggestions no debounce — full emote/user scan on every keystroke
12	MEDIUM	home_screen.dart	395-406	Thread/mentions panels rebuilt on every _chatVersion bump even when hidden
The command_handler missing-break concern was a false alarm — the code compiles and tests pass under Dart 3.12.
Proposed Fixes (in priority order)
1. Throttle truncateChannelMessages (service, HIGH)
Replace per-message truncation with periodic: run it every 500ms via a Timer, or only when message count exceeds limit by a batch threshold (e.g., trim only when length > max * 1.2). Single-line change at lines 838 and 989.
2. Cap/evict unbounded Sets (service, HIGH)
- ownMessageIds → evict entries older than N (or cap at ~500)
- _seenEmoteIds → periodically clear or cap at ~2000
- mentionsChannel → apply same truncation as regular channels
- pendingLocals → add 10-second timeout eviction
3. Narrow _chatVersion rebuild scope (UI, CRITICAL)
Replace the single ListenableBuilder wrapping the entire TabbedLayout with per-channel ValueNotifiers. Only the active channel's chat view rebuilds on new messages — the TabBar stays stable.
4. Cache TabbedLayout widget lists (UI, CRITICAL)
In didUpdateWidget, only regenerate tabs/children lists when tabs array actually changes, not on every build.
5. Remove GlobalKey from ListView itemBuilder (UI, CRITICAL)
Replace with ValueKey('$channel:${msg.messageId}') or just remove the key wrapper entirely (messages don't need scroll-state preservation).
6. Cache timestamp + TapGestureRecognizer on message (UI, HIGH)
Compute formatted timestamp once at TwitchMessage creation. Cache the recognizer on the message model or use InkWell wrapper instead.
7. Debounce filterSuggestions (UI, MEDIUM)
Add 150ms debounce so rapid typing doesn't re-scan the emote list on every keystroke.
8. Guard hidden panel rebuilds (UI, MEDIUM)
Skip _computeThreadMessages() and mentions panel data update when the respective panel is not open.
Want me to break this into phases and start implementing? Or adjust priorities?