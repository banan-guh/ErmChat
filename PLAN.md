Here's the emote issue report:
Emote System Investigation Report
Critical
*C1 — Mass span invalidation on every emote change (home_screen.dart:384-391)
Whenever any emote finishes loading (any channel, any provider), _onEmotesChanged nulls cachedSpans on every single message across all channels, forcing full InlineSpan recomputation for the entire app. With N channels, startup triggers ~2N+2 full rebuilds via redundant notifyListeners() calls in the EmoteManager.
High
H1 — No memCacheWidth/cacheWidth on emote images (emote_text.dart:228,250,264 + 5 other locations)
Emote CachedNetworkImage widgets decode images at full CDN resolution (3x, ~84-108px) while rendering at 28px. Wastes GPU memory, especially with 30+ visible messages × 2 emotes each.
H2 — DefaultCacheManager default 200-file limit (emote_manager.dart:507)
No custom CacheManager config. The default evicts after 200 files, but 4 providers can easily exceed that → cache thrashing, re-downloading frequently used emotes.
*H3 — 7TV API called twice per channel join (emote_manager.dart:405 + chat_connection_manager.dart:471)
Same 7tv.io/v3/users/twitch/{id} endpoint hit once by _fetchAllChannel and again immediately by _resolveSevenTvAndSubscribe. Doubles API load.
H4 — Sequential provider fetching (emote_manager.dart:367-374, 384-407)
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
Want me to dive deeper into any specific item or create a plan for fixing them?