import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/emote_fetch_tier.dart';
import '../models/generic_emote.dart';
import 'emote_cache_manager.dart';
import 'emote_providers/twitch_emotes.dart';
import 'emote_providers/bttv_emotes.dart';
import 'emote_providers/ffz_emotes.dart';
import 'emote_providers/seven_tv_emotes.dart';

class ChannelEmotes {
  final Map<String, GenericEmote> byCode;
  final List<GenericEmote> suggestions;

  ChannelEmotes({required this.byCode, required this.suggestions});
}

class EmoteManager extends ChangeNotifier {
  // Refresh TTLs: emote caches are only refetched once they're older than
  // the TTL. Unmetered connections refresh every 12h; cellular gets 24h so
  // the rake uses less data.
  // TODO(expand): connectivity-based refresh policy - e.g. a "refresh only on
  // wifi" settings toggle, skip channel rakes entirely on cellular,
  // per-connection image precache policy, data-usage stats.
  static const _wifiTtl = Duration(hours: 12);
  static const _mobileTtl = Duration(hours: 24);
  static const _connectivityProbeTtl = Duration(seconds: 60);
  static const _infiniteTtl = Duration(days: 365000);
  static const _defaultFetchStagger = Duration(milliseconds: 1500);
  static const _providerPriority = {
    EmoteType.sevenTv: 0,
    EmoteType.bttv: 1,
    EmoteType.ffz: 2,
    EmoteType.twitch: 3,
  };

  // ── Disk-cache cap + usage registry ─────────────────────────────────
  // The emote image cache is capped inline by EmoteCacheManager (evicting the
  // least-recently-used extras once it grows past maxObjects). This manager
  // only owns the usage registry that feeds that priority, plus the one-time
  // migrations from the old cache layouts.
  static const _usageKey = 'emote_usage';
  static const _usageMinEntries = 300;
  static const _migrationKey = 'emote_gc_migrated_v1';
  static const _migrationKeyV2 = 'emote_gc_migrated_v2';

  EmoteFetchTier _tier = EmoteFetchTier.high;
  int _cacheCap = defaultEmoteCacheMax;

  late final Future<void> Function(String url) _removeCachedFile;
  final DateTime Function() _now;
  final Future<SevenTvChannelResponse> Function(
    String channelId,
    EmoteResolution resolution,
  )
  _sevenTvChannelFetcher;
  final EmoteCacheManager? _injectedCacheManager;
  EmoteCacheManager? _cacheManagerInstance;
  final Map<String, DateTime> _emoteUsage = {};

  /// Resolved lazily so constructing an [EmoteManager] (e.g. in tests) never
  /// instantiates the path-provider-backed cache singleton until it's needed.
  EmoteCacheManager get _cacheManager =>
      _cacheManagerInstance ??= (_injectedCacheManager ?? EmoteCacheManager());
  bool _usageLoaded = false;
  bool _usageDirty = false;
  bool _migrationRan = false;
  bool _migrationRanV2 = false;

  final Future<List<ConnectivityResult>> Function()? _connectivityProbe;
  final Duration _fetchStagger;
  ConnectivityResult _probeResult = ConnectivityResult.wifi;
  DateTime? _probeAt;
  // Bounds in-flight provider fetches so a full refresh doesn't burst the
  // network, while letting more than one channel refresh at a time.
  static const _maxConcurrentFetches = 2;
  final _fetchGate = _Semaphore(_maxConcurrentFetches);

  EmoteManager({
    Future<List<ConnectivityResult>> Function()? probe,
    this._fetchStagger = _defaultFetchStagger,
    Future<void> Function(String url)? removeCachedFile,
    DateTime Function()? now,
    EmoteFetchTier tier = EmoteFetchTier.high,
    int cacheCap = defaultEmoteCacheMax,
    Future<SevenTvChannelResponse> Function(
      String channelId,
      EmoteResolution resolution,
    )?
    sevenTvChannelFetcher,
    EmoteCacheManager? cacheManager,
  }) : _connectivityProbe = probe,
       _injectedCacheManager = cacheManager,
       _sevenTvChannelFetcher =
           sevenTvChannelFetcher ??
           ((String channelId, EmoteResolution resolution) =>
               SevenTvEmoteProvider.fetchChannelResponse(
                 channelId,
                 resolution: resolution,
               )),
       _now = now ?? DateTime.now {
    _removeCachedFile =
        removeCachedFile ?? ((String url) => _cacheManager.removeFile(url));
    _tier = tier;
    _cacheCap = cacheCap.clamp(minEmoteCacheMax, maxEmoteCacheMax).toInt();
  }

  /// Fetching tier controlling resolution, cache TTL, and 7TV reconcile gating.
  EmoteFetchTier get tier => _tier;

  set tier(EmoteFetchTier value) {
    if (value == _tier) return;
    _tier = value;
    _notify();
  }

  /// Max emote image files the disk cache keeps (default [defaultEmoteCacheMax],
  /// clamped to [minEmoteCacheMax]..[maxEmoteCacheMax]). Enforced inline by the
  /// [EmoteCacheManager] on the next fetch.
  int get cacheCap => _cacheCap;

  set cacheCap(int value) {
    _cacheCap = value.clamp(minEmoteCacheMax, maxEmoteCacheMax).toInt();
    final cache = _cacheManager;
    cache.maxObjects = _cacheCap;
    cache.lastUsedAt = (url) => _emoteUsage[url];
  }

  ChannelEmotes? _globalCache;
  final _channelCaches = <String, ChannelEmotes>{};
  final _channelFetchTimes = <String, DateTime>{};
  final _channelTwitchEmotes = <String, List<GenericEmote>>{};
  final _sevenTvEmoteSetIds = <String, String>{};
  final _sevenTvUserIds = <String, String>{};
  // Per-provider retention: each provider's fetch result is kept separately so
  // a single flaky provider (429/5xx, timeout) never clobbers that provider's
  // previous good data or the other providers' entries in the merged cache.
  final _globalProviderEmotes = <String, List<GenericEmote>>{};
  final _channelProviderEmotes = <String, Map<String, List<GenericEmote>>>{};
  String? _accessToken;
  final _mergedCache = <String, ChannelEmotes?>{};
  String? _changedChannel;
  // Monotonic counter bumped on every notify; message span caches compare
  // against it so stale spans can be detected lazily instead of clearing
  // every message's cached spans on each emote change.
  int _version = 0;

  /// Current emote-data version. Increments on every [notifyListeners]
  /// emission (tier/cache changes, global or per-channel emote updates).
  int get version => _version;

  // [bumpVersion] controls whether the span-cache version advances. Live 7TV
  // deltas skip it so already-rendered messages keep the emote state they
  // were built with (no retroactive re-rendering); full refetches bump it.
  void _notify({String? channel, bool bumpVersion = true}) {
    if (bumpVersion) _version++;
    _changedChannel = channel;
    if (channel != null) {
      _mergedCache.remove(channel);
    } else {
      _mergedCache.clear();
    }
    super.notifyListeners();
  }

  /// Consumed by the home screen listener to only invalidate
  /// spans for the channel whose emotes actually changed.
  /// Side-effect getter renamed to method for clarity.
  String? consumeChangedChannel() {
    final c = _changedChannel;
    _changedChannel = null;
    return c;
  }

  // Emote codes touched by the last 7TV delta per channel (added codes,
  // removed codes, rename old+new). Only set by updateSevenTvEmotes; other
  // notifies leave it absent so callers can treat them as full refetches.
  final _lastChangedCodes = <String, Set<String>>{};

  /// Consumes and clears the emote codes touched by the last 7TV delta for
  /// [channel]. Returns null when the last notify was not a 7TV delta (full
  /// refetch, tier change), in which case callers should refresh everything.
  Set<String>? consumeChangedCodes(String channel) {
    return _lastChangedCodes.remove(channel);
  }

  // Live 7TV emote list per channel as of the last WebSocket delta. Re-applied
  // whenever a fetch rebuilds the channel cache, so an in-flight fetch that
  // started before a delta can't clobber the live add/remove/rename.
  final _sevenTvLive = <String, List<GenericEmote>>{};

  set accessToken(String? value) => _accessToken = value;

  // Three-way merge: channel-only, global-only, or global+channel with channel
  // overriding. Result cached in _mergedCache, invalidated on any notify().
  ChannelEmotes? byCode(String channel) {
    final cached = _mergedCache[channel];
    if (cached != null) return cached;
    final channelEmotes = _channelCaches[channel];
    ChannelEmotes? result;
    if (channelEmotes == null) {
      result = _globalCache;
    } else if (_globalCache == null) {
      result = channelEmotes;
    } else {
      final merged = {..._globalCache!.byCode, ...channelEmotes.byCode};
      final suggestions = merged.values.toList()
        ..sort((a, b) => a.code.compareTo(b.code));
      result = ChannelEmotes(byCode: merged, suggestions: suggestions);
    }
    _mergedCache[channel] = result;
    return result;
  }

  // Display order for the global emote grid: 7TV, Twitch, BTTV, FFZ (differs
  // from _providerPriority, which is the dedup precedence).
  static const _globalSortPriority = {
    EmoteType.sevenTv: 0,
    EmoteType.twitch: 1,
    EmoteType.bttv: 2,
    EmoteType.ffz: 3,
  };

  static const _globalProviderLabels = {
    EmoteType.sevenTv: 'SevenTV',
    EmoteType.twitch: 'Twitch',
    EmoteType.bttv: 'BetterTTV',
    EmoteType.ffz: 'FrankerFaceZ',
  };

  // Global emotes grouped by provider for the emote sheet, in display order
  // (7TV, Twitch, BTTV, FFZ); each group sorted by code.
  Map<String, List<GenericEmote>> globalEmotesByProvider() {
    final cached = _globalCache;
    if (cached == null) return {};
    final grouped = <EmoteType, List<GenericEmote>>{};
    for (final e in cached.suggestions) {
      (grouped[e.type] ??= []).add(e);
    }
    final result = <String, List<GenericEmote>>{};
    final types = _globalSortPriority.keys.toList()
      ..sort(
        (a, b) => _globalSortPriority[a]!.compareTo(_globalSortPriority[b]!),
      );
    for (final t in types) {
      final list = grouped[t];
      if (list == null || list.isEmpty) continue;
      list.sort((a, b) => a.code.compareTo(b.code));
      result[_globalProviderLabels[t] ?? ''] = list;
    }
    return result;
  }

  List<GenericEmote> channelNonTwitchEmotes(String channel) {
    final cached = _channelCaches[channel];
    if (cached == null) return [];
    return cached.suggestions.where((e) => e.type != EmoteType.twitch).toList()
      ..sort((a, b) => a.code.compareTo(b.code));
  }

  Map<String, List<GenericEmote>>? _subsByChannelCache;

  Map<String, List<GenericEmote>> subscriberEmotesByChannel() {
    final cached = _subsByChannelCache;
    if (cached != null) return cached;
    // The account's sub emotes are fanned into every open channel's store, so
    // group by the emote's real owner (ownerChannel) instead of the storage
    // channel and dedup by id: each emote appears exactly once, under the
    // channel that owns it. Unknown owners fall back to the storage channel.
    final byOwner = <String, GenericEmote>{};
    final ownerOf = <String, String>{};
    final keys = _channelTwitchEmotes.keys.toList()..sort();
    for (final channel in keys) {
      final raw = _channelTwitchEmotes[channel];
      if (raw == null) continue;
      for (final e in raw) {
        if (e.emoteType != 'subscriptions' && e.tier == null) continue;
        final key = e.id.isNotEmpty
            ? e.id
            : '${e.code}|${e.ownerChannel ?? channel}';
        if (byOwner.containsKey(key)) continue;
        byOwner[key] = e;
        ownerOf[key] = e.ownerChannel ?? channel;
      }
    }
    final grouped = <String, List<GenericEmote>>{};
    for (final entry in byOwner.entries) {
      (grouped[ownerOf[entry.key] ?? ''] ??= []).add(entry.value);
    }
    final owners = grouped.keys.toList()..sort();
    final result = <String, List<GenericEmote>>{};
    for (final owner in owners) {
      result[owner] = grouped[owner]!;
    }
    for (final list in result.values) {
      list.sort((a, b) => a.code.compareTo(b.code));
    }
    return _subsByChannelCache = result;
  }

  static const _recentKey = 'recent_emotes';
  static const _maxRecent = 100;
  List<String> _recentIds = [];
  bool _recentLoaded = false;
  SharedPreferences? _prefs;

  Future<SharedPreferences> _getPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  Future<void> _ensureRecentLoaded() async {
    if (_recentLoaded) return;
    _recentLoaded = true;
    final prefs = await _getPrefs();
    final raw = prefs.getString(_recentKey);
    if (raw == null) return;
    try {
      _recentIds = (jsonDecode(raw) as List<dynamic>).cast<String>();
    } catch (_) {
      debugPrint('[EmoteManager] failed to parse recent emotes');
    }
  }

  Future<void> _saveRecent() async {
    final prefs = await _getPrefs();
    await prefs.setString(_recentKey, jsonEncode(_recentIds));
  }

  /// Resolve an emote by ID across all caches.
  GenericEmote? _emoteById(String id) {
    if (_globalCache != null) {
      for (final e in _globalCache!.suggestions) {
        if (e.id == id) return e;
      }
    }
    for (final cached in _channelCaches.values) {
      for (final e in cached.suggestions) {
        if (e.id == id) return e;
      }
    }
    for (final raw in _channelTwitchEmotes.values) {
      for (final e in raw) {
        if (e.id == id) return e;
      }
    }
    return null;
  }

  Future<void> markEmoteUsed(GenericEmote emote) async {
    await _ensureRecentLoaded();
    _recentIds.remove(emote.id);
    _recentIds.insert(0, emote.id);
    if (_recentIds.length > _maxRecent) {
      _recentIds = _recentIds.sublist(0, _maxRecent);
    }
    await _saveRecent();
    _touchUsage(emote.url);
    await _flushUsage();
  }

  /// Records that an emote was displayed (emote menu / autocomplete render)
  /// so the cache cap evicts never-shown emotes before recently-viewed ones.
  void markEmoteViewed(GenericEmote emote) {
    if (_tier == EmoteFetchTier.nothing) return;
    _touchUsage(emote.url);
    unawaited(_flushUsage());
  }

  Future<List<GenericEmote>> recentEmotes() async {
    await _ensureRecentLoaded();
    final result = <GenericEmote>[];
    for (final id in _recentIds) {
      final emote = _emoteById(id);
      if (emote != null) result.add(emote);
    }
    return result;
  }

  Future<void> preloadGlobalEmotes() async {
    if (_globalCache != null) return;
    final ttl = await _effectiveTtl();
    final loaded = await _loadFromPrefs('emotes3_global', ttl);
    final cached = loaded.cached;
    if (cached != null) {
      _globalCache = cached;
      _notify();
      if (loaded.fresh) {
        // Twitch global emotes aren't persisted on medium/high (see
        // _saveToPrefs), so they refresh in the background on every launch —
        // mirrors the channel behavior. On low/nothing they're already
        // persisted and the cache is effectively infinite, so skip the
        // network entirely. Non-blocking.
        if (!_skipTwitchBackgroundRefresh) {
          unawaited(_enqueueFetch(_refreshTwitchGlobalEmotes));
        }
        return;
      }
    }
    // The nothing tier never fetches: render only what's already cached.
    if (_tier == EmoteFetchTier.nothing) return;
    // Stale or missing: keep showing stale data while revalidating.
    final emotes = await _enqueueFetch(_fetchAllGlobal);
    _globalCache = _buildChannelMap(emotes);
    await _saveToPrefs('emotes3_global', _globalCache!, ttl);
    _notify();
  }

  Future<void> storeUserTwitchEmotes(
    Map<String, List<GenericEmote>> perChannel,
  ) async {
    if (_tier == EmoteFetchTier.nothing) return;
    for (final entry in perChannel.entries) {
      final channel = entry.key;
      final emotes = entry.value;
      if (emotes.isEmpty) continue;
      final existing = _channelTwitchEmotes[channel] ?? [];
      // Freshly fetched emotes first (new wins over same-id entries from an
      // earlier store or channel fetch), then keep existing non-tiered
      // entries that aren't already present. Existing tiered entries are
      // replaced wholesale by the fresh fetch, and everything is deduped by
      // id so overlapping emote sets or concurrent stores can't stack the
      // same subscriber emote twice under one channel.
      final merged = <GenericEmote>[];
      final seen = <String>{};
      for (final e in emotes) {
        if (e.id.isEmpty || seen.add(e.id)) merged.add(e);
      }
      for (final e in existing) {
        if (e.tier == null && (e.id.isEmpty || seen.add(e.id))) {
          merged.add(e);
        }
      }
      _channelTwitchEmotes[channel] = merged;
      _subsByChannelCache = null;
      final existingCache = _channelCaches[channel];
      final allEmotes = <GenericEmote>[
        ...merged,
        if (existingCache != null)
          for (final e in existingCache.suggestions)
            if (e.type != EmoteType.twitch) e,
      ];
      _channelCaches[channel] = _buildChannelMap(allEmotes);
    }
    _notify();
  }

  Future<void> resolveEmotes(String channel, String? broadcasterId) async {
    final ttl = await _effectiveTtl();
    final loaded = await _loadFromPrefs(
      'emotes3_$channel',
      ttl,
      fetchTime: _channelFetchTimes[channel],
    );
    final cached = loaded.cached;
    if (cached != null) {
      // The persisted cache never contains Twitch emotes on medium/high, so
      // re-merge any subscriber emotes already stored for this channel (they
      // come from the account's own emote list and must not be clobbered by
      // re-applying the persisted cache).
      final subs = _channelTwitchEmotes[channel] ?? const <GenericEmote>[];
      _channelCaches[channel] = subs.isEmpty
          ? cached
          : _buildChannelMap([...cached.suggestions, ...subs]);
      _reapplyLiveSevenTv(channel);
      _channelFetchTimes[channel] = DateTime.now();
      _notify(channel: channel);
      if (loaded.fresh) {
        // Fresh cache: render immediately, then refresh only the Twitch
        // channel emotes in the background on medium/high (they aren't
        // persisted there, so sub-tier status changes between opens). On
        // low/nothing they're persisted and the cache is effectively
        // infinite, so skip the network entirely. Non-blocking.
        if (!_skipTwitchBackgroundRefresh) {
          unawaited(
            _enqueueFetch(
              () => _refreshTwitchChannelEmotes(channel, broadcasterId),
            ),
          );
        }
        // Reconcile 7TV deltas (medium/high) so cross-session changes are
        // reflected at startup without waiting for the TTL rake.
        if (broadcasterId != null &&
            _tier.index >= EmoteFetchTier.medium.index) {
          unawaited(
            _enqueueFetch(() => _reconcileSevenTv(channel, broadcasterId)),
          );
        }
        return;
      }
      // Stale: keep showing stale data while revalidating below.
    }
    // The nothing tier never fetches: render only what's already cached.
    if (_tier == EmoteFetchTier.nothing) return;
    final emotes = await _enqueueFetch(
      () => _fetchAllChannel(broadcasterId, channelName: channel),
    );
    _applyChannelEmotes(channel, emotes);
    await _saveToPrefs('emotes3_$channel', _channelCaches[channel]!, ttl);
  }

  void _applyChannelEmotes(String channel, List<GenericEmote> emotes) {
    // Nothing came back from any provider this cycle and we already have
    // cached emotes: keep showing them rather than wiping the channel.
    if (emotes.isEmpty && _channelCaches[channel] != null) {
      debugPrint('[EmoteManager] no emotes for $channel, keeping cached');
      return;
    }
    // Split subscriber-only Twitch emotes from the main cache. They're stored
    // separately and re-merged via storeUserTwitchEmotes, which preserves
    // tiered versions over non-tiered for sub-gated emotes.
    final nonSubEmotes = emotes
        .where(
          (e) =>
              !(e.type == EmoteType.twitch &&
                  (e.tier != null || e.emoteType == 'subscriptions')),
        )
        .toList();
    final merged = _mergeWithStoredSubs(channel, nonSubEmotes);
    _channelCaches[channel] = _buildChannelMap(merged);
    _reapplyLiveSevenTv(channel);
    _channelFetchTimes[channel] = DateTime.now();
    _notify(channel: channel);
  }

  // Re-applies the live 7TV delta state after a fetch rebuilds the channel
  // cache, so an in-flight fetch that started before a WebSocket delta can't
  // clobber the live add/remove/rename.
  void _reapplyLiveSevenTv(String channel) {
    final live = _sevenTvLive[channel];
    if (live == null) return;
    final cache = _channelCaches[channel];
    if (cache == null) return;
    final byCode = <String, GenericEmote>{};
    for (final e in cache.byCode.values) {
      if (e.type != EmoteType.sevenTv) byCode[e.code] = e;
    }
    for (final e in live) {
      byCode[e.code] = e;
    }
    final suggestions = byCode.values.toList()
      ..sort((a, b) => a.code.compareTo(b.code));
    _channelCaches[channel] = ChannelEmotes(
      byCode: byCode,
      suggestions: suggestions,
    );
  }

  // Merges freshly fetched channel emotes with any subscriber-only Twitch
  // emotes already stored for the channel. Subscriber emotes are sourced from
  // the account's own emote list (storeUserTwitchEmotes), so channel fetches
  // must preserve them. Returns the full list for the channel cache rebuild.
  List<GenericEmote> _mergeWithStoredSubs(
    String channel,
    List<GenericEmote> nonSub,
  ) {
    final subs = (_channelTwitchEmotes[channel] ?? const <GenericEmote>[])
        .where((e) => e.emoteType == 'subscriptions' || e.tier != null)
        .toList();
    _channelTwitchEmotes[channel] = [
      ...subs,
      ...nonSub.where((e) => e.type == EmoteType.twitch),
    ];
    _subsByChannelCache = null;
    return [...subs, ...nonSub];
  }

  Future<void> _refreshTwitchChannelEmotes(
    String channel,
    String? broadcasterId,
  ) async {
    if (broadcasterId == null) return;
    try {
      final emotes = await TwitchEmoteProvider.fetchChannel(
        broadcasterId,
        accessToken: _accessToken,
        channelName: channel,
        resolution: _tier.resolution!,
      );
      if (emotes.isEmpty) return;
      final nonSub = emotes
          .where(
            (e) =>
                !(e.type == EmoteType.twitch &&
                    (e.tier != null || e.emoteType == 'subscriptions')),
          )
          .toList();
      (_channelProviderEmotes[channel] ??=
              <String, List<GenericEmote>>{})['Twitch'] =
          nonSub;
      final merged = _mergeWithStoredSubs(channel, nonSub);
      final existing = _channelCaches[channel];
      if (existing != null) {
        final combined = <GenericEmote>[
          ...existing.suggestions.where((e) => e.type != EmoteType.twitch),
          ...merged,
        ];
        _channelCaches[channel] = _buildChannelMap(combined);
      }
      _notify(channel: channel);
    } catch (e) {
      debugPrint('[EmoteManager] twitch refresh failed for $channel: $e');
    }
  }

  Future<void> _refreshTwitchGlobalEmotes() async {
    try {
      final emotes = await TwitchEmoteProvider.fetchGlobal(
        accessToken: _accessToken,
        resolution: _tier.resolution!,
      );
      if (emotes.isEmpty) return;
      _globalProviderEmotes['Twitch'] = emotes;
      final current = _globalCache;
      final all = <GenericEmote>[
        if (current != null)
          for (final e in current.suggestions)
            if (e.type != EmoteType.twitch) e,
        ...emotes,
      ];
      _globalCache = _buildChannelMap(all);
      _notify();
    } catch (e) {
      debugPrint('[EmoteManager] twitch global refresh failed: $e');
    }
  }

  // Fetches the channel's 7TV emote set and diffs it against the loaded cache,
  // applying add/remove/rename deltas through the same pipeline the 7TV
  // WebSocket uses. Runs once on a fresh cache (medium/high) so 7TV changes
  // between sessions show up at startup without waiting for the TTL rake.
  // Nothing/low are fully cache-driven and never reach this.
  Future<void> _reconcileSevenTv(String channel, String broadcasterId) async {
    if (_tier.index < EmoteFetchTier.medium.index) return;
    try {
      final resp = await _sevenTvChannelFetcher(
        broadcasterId,
        _tier.resolution!,
      );
      final existing = _channelCaches[channel];
      if (existing == null) return;

      if (resp.emoteSetId != null) {
        setSevenTvEmoteSetId(channel, resp.emoteSetId!);
      }
      if (resp.userId != null) {
        _sevenTvUserIds[channel] = resp.userId!;
      }
      // A failed or genuinely empty fetch must not wipe cached 7TV emotes
      // (a non-200 response returns an empty list rather than throwing).
      if (resp.emotes.isEmpty) return;

      final current = existing.suggestions
          .where((e) => e.type == EmoteType.sevenTv)
          .toList();
      final currentById = {for (final e in current) e.id: e};
      final incomingById = {for (final e in resp.emotes) e.id: e};

      final added = <GenericEmote>[];
      final removedIds = <String>[];
      final renamed = <String, ({String newName, String oldName})>{};
      for (final e in resp.emotes) {
        final old = currentById[e.id];
        if (old == null) {
          added.add(e);
        } else if (old.code != e.code) {
          renamed[e.id] = (newName: e.code, oldName: old.code);
        }
      }
      for (final id in currentById.keys) {
        if (!incomingById.containsKey(id)) removedIds.add(id);
      }

      if (added.isEmpty && removedIds.isEmpty && renamed.isEmpty) return;
      updateSevenTvEmotes(
        channel,
        added: added,
        removedIds: removedIds,
        renamed: renamed,
      );
    } catch (e) {
      debugPrint('[EmoteManager] 7TV reconcile failed for $channel: $e');
    }
  }

  void evictChannel(String channel) {
    _channelCaches.remove(channel);
    _channelFetchTimes.remove(channel);
    _channelTwitchEmotes.remove(channel);
    _subsByChannelCache = null;
    _sevenTvEmoteSetIds.remove(channel);
    _sevenTvUserIds.remove(channel);
    _channelProviderEmotes.remove(channel);
    _mergedCache.remove(channel);
    _sevenTvLive.remove(channel);
  }

  void evictGlobal() {
    _globalCache = null;
    _globalProviderEmotes.clear();
    _mergedCache.clear();
  }

  void setSevenTvEmoteSetId(String channel, String emoteSetId) {
    _sevenTvEmoteSetIds[channel] = emoteSetId;
  }

  String? getSevenTvEmoteSetId(String channel) => _sevenTvEmoteSetIds[channel];

  String? getSevenTvUserId(String channel) => _sevenTvUserIds[channel];

  String? getChannelForSevenTvEmoteSet(String emoteSetId) {
    for (final entry in _sevenTvEmoteSetIds.entries) {
      if (entry.value == emoteSetId) return entry.key;
    }
    return null;
  }

  // Live 7TV emote patch: applies add/remove/rename deltas from the 7TV
  // WebSocket in place on the channel's sorted emote list, so an add/remove
  // at position k only shifts the entries below it. Only affects 7TV-type
  // emotes. Add checks scope and provider priority to avoid downgrading
  // higher-priority entries from other providers. Records the affected emote
  // codes (consumed via [consumeChangedCodes]) so callers can re-render only
  // what the delta touched, and evicts removed emotes from the disk cache
  // when no other channel uses them anymore.
  void updateSevenTvEmotes(
    String channel, {
    List<GenericEmote> added = const [],
    List<String> removedIds = const [],
    Map<String, ({String newName, String oldName})> renamed = const {},
  }) {
    if (_tier == EmoteFetchTier.nothing) return;
    var cache = _channelCaches[channel];
    if (cache == null && added.isEmpty) return;

    final changedCodes = <String>{};
    final removedIdsWithUrls = <(String, List<String>)>[];

    if (cache == null) {
      // No cache yet: build one from the added emotes.
      final sorted = List.of(added)..sort((a, b) => a.code.compareTo(b.code));
      cache = ChannelEmotes(
        byCode: {for (final e in sorted) e.code: e},
        suggestions: sorted,
      );
      _channelCaches[channel] = cache;
      changedCodes.addAll(added.map((e) => e.code));
    } else {
      final byCode = cache.byCode;
      final suggestions = cache.suggestions;

      for (final id in removedIds) {
        final removed = byCode.values
            .where((e) => e.id == id && e.type == EmoteType.sevenTv)
            .toList();
        for (final e in removed) {
          byCode.remove(e.code);
          _removeFromSuggestions(suggestions, e.code);
          changedCodes.add(e.code);
          removedIdsWithUrls.add((
            e.id,
            [e.url, if (e.urlLarge != null) e.urlLarge!],
          ));
        }
      }

      for (final entry in renamed.entries) {
        final e = byCode.values
            .where((x) => x.id == entry.key && x.type == EmoteType.sevenTv)
            .firstOrNull;
        if (e == null) continue;
        byCode.remove(e.code);
        _removeFromSuggestions(suggestions, e.code);
        final renamedEmote = GenericEmote(
          id: e.id,
          code: entry.value.newName,
          type: e.type,
          url: e.url,
          urlLarge: e.urlLarge,
          isAnimated: e.isAnimated,
          scope: e.scope,
          ownerChannel: e.ownerChannel,
          isZeroWidth: e.isZeroWidth,
          baseName: e.baseName,
          relativeScale: e.relativeScale,
          aspectRatio: e.aspectRatio,
        );
        byCode[renamedEmote.code] = renamedEmote;
        _insertSorted(suggestions, renamedEmote);
        changedCodes
          ..add(e.code)
          ..add(renamedEmote.code);
      }

      for (final emote in added) {
        final existing = byCode[emote.code];
        if (existing != null &&
            !(existing.scope.index <= emote.scope.index &&
                _providerPriority[emote.type]! <
                    _providerPriority[existing.type]!)) {
          continue;
        }
        if (existing != null) {
          _removeFromSuggestions(suggestions, emote.code);
        }
        byCode[emote.code] = emote;
        _insertSorted(suggestions, emote);
        changedCodes.add(emote.code);
      }

      _channelCaches[channel] = cache;
    }

    // Keep the per-provider stash in sync so a transient fetch miss can't
    // resurrect the delta from stale retained data, and record the live 7TV
    // list so any concurrent fetch rebuild re-applies it.
    final providerStash = _channelProviderEmotes[channel];
    if (providerStash != null && providerStash.containsKey('7TV')) {
      providerStash['7TV'] = cache.suggestions
          .where((e) => e.type == EmoteType.sevenTv)
          .toList();
    }
    _sevenTvLive[channel] = cache.suggestions
        .where((e) => e.type == EmoteType.sevenTv)
        .toList();

    _lastChangedCodes[channel] = changedCodes;
    // Live deltas don't bump the span-cache version: messages keep the emote
    // state they were rendered with (no retroactive re-rendering on add or
    // remove). The sheet, autocomplete and recents read the updated lists
    // directly through the listener.
    _notify(channel: channel, bumpVersion: false);

    // Evict removed emotes from the disk cache once they're gone from every
    // channel (7TV emotes can be shared across channels), so a removed emote
    // only lingers in RAM until the next restart.
    final unused = removedIdsWithUrls.where(
      (entry) => !_isEmoteUsedElsewhere(entry.$1),
    );
    if (unused.isNotEmpty) {
      unawaited(_evictEmoteImages([for (final entry in unused) ...entry.$2]));
    }
  }

  // Removes the entry with the given code from a code-sorted list in place.
  void _removeFromSuggestions(List<GenericEmote> list, String code) {
    final index = list.indexWhere((e) => e.code == code);
    if (index != -1) list.removeAt(index);
  }

  // Inserts an emote into a code-sorted list in place, replacing the entry
  // with the same code if one exists.
  void _insertSorted(List<GenericEmote> list, GenericEmote emote) {
    final existingIndex = list.indexWhere((e) => e.code == emote.code);
    if (existingIndex != -1) {
      list[existingIndex] = emote;
      return;
    }
    var i = 0;
    while (i < list.length && list[i].code.compareTo(emote.code) < 0) {
      i++;
    }
    list.insert(i, emote);
  }

  bool _isEmoteUsedElsewhere(String id) {
    for (final c in _channelCaches.values) {
      if (c.byCode.values.any((e) => e.id == id)) return true;
    }
    return _globalCache?.byCode.values.any((e) => e.id == id) ?? false;
  }

  Future<void> _evictEmoteImages(List<String> urls) async {
    await _ensureUsageLoaded();
    var removed = false;
    for (final url in urls) {
      if (url.isEmpty) continue;
      _emoteUsage.remove(url);
      removed = true;
      try {
        await _removeCachedFile(url);
      } catch (_) {
        debugPrint('[EmoteManager] failed to evict unused emote $url');
      }
    }
    if (removed) {
      _usageDirty = true;
      await _flushUsage();
    }
  }

  /// Low/nothing tiers persist Twitch emotes (see [_saveToPrefs]) with an
  /// effectively infinite TTL, so there's nothing to refresh in the
  /// background on launch.
  bool get _skipTwitchBackgroundRefresh =>
      _tier == EmoteFetchTier.low || _tier == EmoteFetchTier.nothing;

  /// Connectivity-aware refresh TTL: refresh is cheaper on unmetered
  /// connections, so cellular gets a longer TTL to avoid data usage.
  Future<Duration> _effectiveTtl() async {
    switch (_tier) {
      case EmoteFetchTier.low:
      case EmoteFetchTier.nothing:
        return _infiniteTtl;
      case EmoteFetchTier.medium:
        return const Duration(hours: 24);
      case EmoteFetchTier.high:
        final isMobile =
            await _probeConnectivity() == ConnectivityResult.mobile;
        return isMobile ? _mobileTtl : _wifiTtl;
    }
  }

  /// One-shot connectivity probe, cached for [_connectivityProbeTtl] so the
  /// rake doesn't hit the platform channel once per channel fetch.
  Future<ConnectivityResult> _probeConnectivity() async {
    final probe = _connectivityProbe;
    if (probe == null) return ConnectivityResult.wifi;
    final now = DateTime.now();
    final probedAt = _probeAt;
    if (probedAt != null && now.difference(probedAt) < _connectivityProbeTtl) {
      return _probeResult;
    }
    try {
      final results = await probe();
      _probeResult = results.contains(ConnectivityResult.mobile)
          ? ConnectivityResult.mobile
          : ConnectivityResult.wifi;
    } catch (_) {
      _probeResult = ConnectivityResult.wifi;
    }
    _probeAt = DateTime.now();
    return _probeResult;
  }

  /// Serializes fetches through a small concurrency gate with a stagger that
  /// is measured from when each fetch was enqueued (not from when the previous
  /// one finished). A single stale channel still idles the radio for one
  /// stagger, but N stale channels no longer stack N full stagger + fetch
  /// rounds behind each other; the [_maxConcurrentFetches] cap keeps a full
  /// refresh from bursting the network. Fresh caches never enter the queue.
  Future<T> _enqueueFetch<T>(Future<T> Function() action) {
    final enqueuedAt = DateTime.now();
    return _fetchGate.withPermit(() async {
      final elapsed = DateTime.now().difference(enqueuedAt);
      if (elapsed < _fetchStagger) {
        await Future.delayed(_fetchStagger - elapsed);
      }
      return action();
    });
  }

  @visibleForTesting
  Future<Duration> effectiveTtlForTesting() => _effectiveTtl();

  @visibleForTesting
  int get precacheQueueLengthForTesting => _precacheQueue.length;

  @visibleForTesting
  Future<void> enqueueFetchForTesting(Future<void> Function() action) =>
      _enqueueFetch(action);

  ChannelEmotes _buildChannelMap(List<GenericEmote> emotes) {
    // Scope precedence (channel > global) applied before provider precedence.
    // Provider precedence (tiebreaker within same scope): 7TV > BTTV > FFZ > Twitch
    final best = <String, GenericEmote>{};
    final seenScope = <String, int>{};
    for (final emote in emotes) {
      final existing = best[emote.code];
      if (existing == null) {
        best[emote.code] = emote;
        seenScope[emote.code] = emote.scope.index;
        continue;
      }
      final existingScopePrio = seenScope[emote.code] ?? 0;
      final newScopePrio = emote.scope.index;
      // Scope wins: channel (1) over global (0)
      if (newScopePrio > existingScopePrio) {
        best[emote.code] = emote;
        seenScope[emote.code] = newScopePrio;
      } else if (newScopePrio == existingScopePrio) {
        // Same scope – provider precedence
        final existingProvPrio = _providerPriority[existing.type] ?? 99;
        final newProvPrio = _providerPriority[emote.type] ?? 99;
        if (newProvPrio < existingProvPrio) {
          best[emote.code] = emote;
        }
      }
    }
    final suggestions = best.values.toList()
      ..sort((a, b) => a.code.compareTo(b.code));
    return ChannelEmotes(byCode: best, suggestions: suggestions);
  }

  Future<List<GenericEmote>> _fetchAllGlobal() async {
    final providers = <String, Future<List<GenericEmote>> Function()>{
      'Twitch': () async {
        final emotes = await TwitchEmoteProvider.fetchGlobal(
          accessToken: _accessToken,
          resolution: _tier.resolution!,
        );
        _globalProviderEmotes['Twitch'] = emotes;
        return emotes;
      },
      'BTTV': () async {
        final emotes = await BttvEmoteProvider.fetchGlobal(
          resolution: _tier.resolution!,
        );
        _globalProviderEmotes['BTTV'] = emotes;
        return emotes;
      },
      'FFZ': () async {
        final emotes = await FfzEmoteProvider.fetchGlobal(
          resolution: _tier.resolution!,
        );
        _globalProviderEmotes['FFZ'] = emotes;
        return emotes;
      },
      '7TV': () async {
        final emotes = await SevenTvEmoteProvider.fetchGlobal(
          resolution: _tier.resolution!,
        );
        _globalProviderEmotes['7TV'] = emotes;
        return emotes;
      },
    };
    await _fetchConcurrent(providers, maxConcurrent: 2);
    return <GenericEmote>[
      for (final list in _globalProviderEmotes.values) ...list,
    ];
  }

  Future<List<GenericEmote>> _fetchAllChannel(
    String? broadcasterId, {
    String? channelName,
  }) async {
    if (broadcasterId == null) {
      // Nothing to fetch (e.g. unknown user id): fall back to whatever this
      // channel already retained so a transient miss never wipes the cache.
      final retained = _channelProviderEmotes[channelName];
      if (retained == null) return [];
      return <GenericEmote>[for (final list in retained.values) ...list];
    }
    final channelKey = channelName ?? '';
    final map = _channelProviderEmotes[channelKey] ??=
        <String, List<GenericEmote>>{};
    final providers = <String, Future<List<GenericEmote>> Function()>{
      'Twitch': () async {
        final fetched = await TwitchEmoteProvider.fetchChannel(
          broadcasterId,
          accessToken: _accessToken,
          channelName: channelName,
          resolution: _tier.resolution!,
        );
        final nonSub = fetched
            .where(
              (e) =>
                  !(e.type == EmoteType.twitch &&
                      (e.tier != null || e.emoteType == 'subscriptions')),
            )
            .toList();
        map['Twitch'] = nonSub;
        return nonSub;
      },
      'BTTV': () async {
        final emotes = await BttvEmoteProvider.fetchChannel(
          broadcasterId,
          resolution: _tier.resolution!,
        );
        map['BTTV'] = emotes;
        return emotes;
      },
      'FFZ': () async {
        final emotes = await FfzEmoteProvider.fetchChannel(
          broadcasterId,
          resolution: _tier.resolution!,
        );
        map['FFZ'] = emotes;
        return emotes;
      },
      '7TV': () async {
        final resp = await SevenTvEmoteProvider.fetchChannelResponse(
          broadcasterId,
          resolution: _tier.resolution!,
        );
        if (channelName != null) {
          if (resp.emoteSetId != null) {
            setSevenTvEmoteSetId(channelName, resp.emoteSetId!);
          }
          if (resp.userId != null) {
            _sevenTvUserIds[channelName] = resp.userId!;
          }
        }
        map['7TV'] = resp.emotes;
        return resp.emotes;
      },
    };
    await _fetchConcurrent(providers, maxConcurrent: 3);
    return <GenericEmote>[for (final list in map.values) ...list];
  }

  Future<void> _fetchConcurrent(
    Map<String, Future<List<GenericEmote>> Function()> providers, {
    required int maxConcurrent,
  }) async {
    final sem = _Semaphore(maxConcurrent);
    final futures = <Future<void>>[];
    for (final entry in providers.entries) {
      futures.add(
        sem.withPermit(() async {
          try {
            await entry.value();
          } catch (e) {
            debugPrint('EmoteManager: ${entry.key} failed: $e');
          }
        }),
      );
    }
    await Future.wait(futures, eagerError: false);
  }

  Future<({ChannelEmotes? cached, bool fresh})> _loadFromPrefs(
    String key,
    Duration ttl, {
    DateTime? fetchTime,
  }) async {
    final prefs = await _getPrefs();
    final raw = prefs.getString(key);
    if (raw == null) return (cached: null, fresh: false);
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final ts = DateTime.parse(data['ts'] as String);
      final cachedTime = fetchTime ?? ts;
      final withinTtl = DateTime.now().difference(cachedTime) <= ttl;
      // A tier tag from a different fetching tier means the cached URLs are
      // at the wrong resolution; force a refetch (the 1x -> 2x overwrite).
      // Caches written before the feature have no tag and are treated as
      // matching.
      final tierMatches = data['tier'] is! int || data['tier'] == _tier.index;
      final fresh = withinTtl && tierMatches;
      final list = (data['emotes'] as List<dynamic>)
          .map((e) => GenericEmote.fromJson(e as Map<String, dynamic>))
          .toList();
      return (cached: _buildChannelMap(list), fresh: fresh);
    } catch (_) {
      debugPrint('[EmoteManager] failed to parse cached emotes');
      return (cached: null, fresh: false);
    }
  }

  Future<void> _saveToPrefs(
    String key,
    ChannelEmotes channelEmotes,
    Duration ttl,
  ) async {
    // Low/nothing cache forever, so persist non-sub Twitch emotes too (infinite
    // TTL must mean zero per-launch network). Medium/high keep the historical
    // behavior of persisting only non-Twitch emotes.
    final persistTwitch =
        _tier == EmoteFetchTier.low || _tier == EmoteFetchTier.nothing;
    final saved = channelEmotes.suggestions.where((e) {
      if (e.type != EmoteType.twitch) return true;
      if (!persistTwitch) return false;
      return !(e.emoteType == 'subscriptions' || e.tier != null);
    }).toList();
    if (saved.isEmpty) return;
    try {
      final prefs = await _getPrefs();
      final data = {
        'ts': DateTime.now().toIso8601String(),
        'tier': _tier.index,
        'emotes': saved.map((e) => e.toJson()).toList(),
      };
      await prefs.setString(key, jsonEncode(data));
    } catch (_) {
      debugPrint('[EmoteManager] failed to save emotes to prefs');
    }
  }

  // ── Disk-cache GC: usage tracking ───────────────────────────────────

  /// The usage registry must be able to hold at least the cache cap, so it
  /// trims to max(300, [_cacheCap]) entries.
  int get _usageMaxEntries =>
      _cacheCap > _usageMinEntries ? _cacheCap : _usageMinEntries;

  final Set<String> _pendingUsageTouches = {};

  void _touchUsage(String url) {
    if (url.isEmpty) return;
    if (!_usageLoaded) {
      // Not loaded yet: defer so we don't clobber the persisted registry
      // with a partial in-memory view on the first flush.
      _pendingUsageTouches.add(url);
      return;
    }
    _emoteUsage[url] = _now();
    _usageDirty = true;
  }

  Future<void> _ensureUsageLoaded() async {
    if (_usageLoaded) return;
    _usageLoaded = true;
    final prefs = await _getPrefs();
    final raw = prefs.getString(_usageKey);
    if (raw != null) {
      try {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in data.entries) {
          _emoteUsage[entry.key] = DateTime.parse(entry.value as String);
        }
      } catch (_) {
        debugPrint('[EmoteManager] failed to parse emote usage registry');
      }
    }
    if (_pendingUsageTouches.isNotEmpty) {
      final now = _now();
      for (final url in _pendingUsageTouches) {
        _emoteUsage[url] = now;
      }
      _pendingUsageTouches.clear();
      _usageDirty = true;
    }
  }

  Future<void> _flushUsage() async {
    if (!_usageLoaded) return;
    await _ensureUsageLoaded();
    if (!_usageDirty) return;
    _usageDirty = false;
    if (_emoteUsage.length > _usageMaxEntries) {
      final entries = _emoteUsage.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      final overflow = entries.length - _usageMaxEntries;
      for (final entry in entries.take(overflow)) {
        _emoteUsage.remove(entry.key);
      }
    }
    final prefs = await _getPrefs();
    final data = <String, String>{
      for (final entry in _emoteUsage.entries)
        entry.key: entry.value.toIso8601String(),
    };
    await prefs.setString(_usageKey, jsonEncode(data));
  }

  // ── Cache init + migrations ─────────────────────────────────────────

  /// Runs the one-time migrations, registers the usage registry as the cache's
  /// priority source, and enforces the cap once. There is no periodic sweep:
  /// [EmoteCacheManager] simply stops persisting once the cap is reached.
  Future<void> startCacheGc() async {
    await _ensureUsageLoaded();
    final cache = _cacheManager;
    cache.maxObjects = _cacheCap;
    cache.lastUsedAt = (url) => _emoteUsage[url];
    if (!_migrationRan) {
      final prefs = await _getPrefs();
      if (prefs.getBool(_migrationKey) ?? false) {
        _migrationRan = true;
      } else {
        // First launch after the GC landed: the pre-existing cache was
        // filled by the old 200-file/30-day policy and our usage registry
        // can't track it, so clear it once. Emotes re-download on demand.
        try {
          await DefaultCacheManager().emptyCache();
        } catch (_) {
          debugPrint('[EmoteManager] cache migration emptyCache failed');
        }
        _migrationRan = true;
        await prefs.setBool(_migrationKey, true);
      }
    }
    if (!_migrationRanV2) {
      final prefs = await _getPrefs();
      if (prefs.getBool(_migrationKeyV2) ?? false) {
        _migrationRanV2 = true;
      } else {
        // Emote images now read/write/precache through EmoteCacheManager
        // (emoteImageCacheV2). Clear the v1 DefaultCacheManager leftovers
        // once so the orphaned old files stop occupying disk.
        try {
          await DefaultCacheManager().emptyCache();
        } catch (_) {
          debugPrint('[EmoteManager] cache v2 migration emptyCache failed');
        }
        _migrationRanV2 = true;
        await prefs.setBool(_migrationKeyV2, true);
      }
    }
    await cache.enforceNow();
  }

  // ── Pre-cache queue for seen emotes ──────────────────────────────────

  final Set<String> _seenEmoteIds = {};
  final _precacheQueue = <GenericEmote>[];
  bool _isProcessingPrecache = false;
  static const _maxConcurrentPrecache = 5;

  void enqueueSeenEmotes(List<GenericEmote> emotes) {
    // The nothing tier never fetches or precaches: no usage tracking either.
    if (_tier == EmoteFetchTier.nothing) return;
    final fresh = <GenericEmote>[];
    for (final e in emotes) {
      if (_seenEmoteIds.add(e.id)) {
        fresh.add(e);
      }
    }
    if (fresh.isEmpty) return;
    if (_seenEmoteIds.length > 2000) _seenEmoteIds.clear();
    for (final e in fresh) {
      _touchUsage(e.url);
    }
    // A zero cap means nothing is kept: skip the download entirely instead of
    // precaching files the next enforcement pass would immediately evict.
    if (_cacheCap > 0) {
      _precacheQueue.addAll(fresh);
      if (!_isProcessingPrecache) {
        _processPrecacheQueue();
      }
    }
    unawaited(_flushUsage());
  }

  void _processPrecacheQueue() {
    _isProcessingPrecache = true;
    _stepPrecache();
  }

  void _stepPrecache() {
    if (_precacheQueue.isEmpty) {
      _isProcessingPrecache = false;
      return;
    }
    final batch = _precacheQueue.take(_maxConcurrentPrecache).toList();
    _precacheQueue.removeRange(0, batch.length);
    Future.wait(
      batch.map(_precacheEmote),
      eagerError: false,
    ).then((_) => _stepPrecache());
  }

  Future<void> _precacheEmote(GenericEmote emote) async {
    if (await _cacheManager.isFull()) return;
    try {
      await _cacheManager.getSingleFile(emote.url);
    } catch (_) {
      debugPrint('[EmoteManager] failed to precache emote: ${emote.code}');
    }
  }
}

class _Semaphore {
  final int maxPermits;
  int _permits;
  final List<Completer<void>> _queue = [];

  _Semaphore(this.maxPermits) : _permits = maxPermits;

  Future<T> withPermit<T>(Future<T> Function() action) async {
    await _acquire();
    try {
      return await action();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_permits > 0) {
      _permits--;
      return Future.value();
    }
    final c = Completer<void>();
    _queue.add(c);
    return c.future;
  }

  void _release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    } else {
      _permits++;
    }
  }
}
