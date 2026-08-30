import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/emote_fetch_tier.dart';
import '../models/generic_emote.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../util/log.dart';
import 'emote_cache_manager.dart';
import 'emote_meta_store.dart';
import 'emote_providers/twitch_emotes.dart';
import 'emote_providers/bttv_emotes.dart';
import 'emote_providers/ffz_emotes.dart';
import 'emote_providers/seven_tv_emotes.dart';

class ChannelEmotes {
  final Map<String, GenericEmote> byCode;
  final List<GenericEmote> suggestions;

  ChannelEmotes({required this.byCode, required this.suggestions});
}

/// Per-URL usage history feeding the disk-cache eviction priority.
///
/// Tracks the last-use time plus a rolling 24-hour histogram of view counts
/// in hourly buckets, so the cache can keep emotes that are *steadily* used
/// over time and evict ones that were spammed in a single burst then went
/// quiet. The score combines:
///
///   recency r = exp(-hoursSinceLastUse / [_recencyHalfLife])
///   total   T = views in the last 24 hours
///   entropy H = normalized entropy of the bucket distribution (1 = spread
///               evenly across the day, 0 = all views in one hour)
///   steady  s = min(T / [_steadyRate], 1) * H
///   score   = r + [_steadyWeight] * s
///
/// Pure logic (no I/O); the [EmoteManager] owns persistence. The bucket
/// index is anchored at [_EmoteUsageRecord.bucketBase] (unix hour of the
/// oldest bucket) so advancing an hour never shifts the list.
class EmoteUsageRecord {
  EmoteUsageRecord({
    required this.lastUsedAt,
    required this.bucketBase,
    required List<int> buckets,
  }) : buckets = List.unmodifiable(buckets) {
    assert(buckets.length == _bucketCount);
  }

  /// Views within the last [Duration] window are counted in these buckets.
  static const int _bucketCount = 24;
  // A long, lax recency window for the usage score: it keeps the emote
  // priority score stable so the cache eviction admission check (see
  // EmoteCacheManager._evictLowest) does not thrash long-lived favorites for
  // one-off emotes.
  static const _recencyHalfLife = Duration(days: 3);
  static const _steadyRate = 50;
  static const _steadyWeight = 0.75;

  /// Unix hour of [buckets] index 0; buckets are zeroed as the window rolls
  /// past them, so older data simply ages out.
  final int bucketBase;

  final DateTime lastUsedAt;
  final List<int> buckets;

  /// Records a view at the given unix hour (0-23 UTC is not used; the hour is
  /// an absolute unix hour). Rolls the window forward first so stale buckets
  /// age out.
  static EmoteUsageRecord bumped(
    EmoteUsageRecord record,
    int hour, {
    required DateTime now,
  }) {
    final rolled = rolledForward(record, hour);
    final index = ((hour - rolled.bucketBase) % _bucketCount).toInt();
    final buckets = List<int>.of(rolled.buckets);
    buckets[index]++;
    return EmoteUsageRecord(
      lastUsedAt: now,
      buckets: buckets,
      bucketBase: rolled.bucketBase,
    );
  }

  /// Instance form of [bumped] for a just-created zero record.
  EmoteUsageRecord bumpedAt(int hour, {required DateTime now}) =>
      EmoteUsageRecord.bumped(this, hour, now: now);

  /// Returns a record whose window starts at (or covers) [hour], zeroing
  /// buckets that rolled out. Cheap for records that were just bumped; only
  /// stale records pay for the roll.
  static EmoteUsageRecord rolledForward(EmoteUsageRecord record, int hour) {
    var base = record.bucketBase;
    if (hour < base || hour - base >= _bucketCount) {
      // Clock moved backwards or the whole window is stale: rebuild empty.
      if (hour < base) return record;
      return EmoteUsageRecord(
        lastUsedAt: record.lastUsedAt,
        buckets: List.filled(_bucketCount, 0),
        bucketBase: hour,
      );
    }
    if (hour == base) return record;
    final buckets = List<int>.of(record.buckets);
    final advance = hour - base;
    // Bucket i covers hour (base + i), so hours that rolled out are exactly
    // buckets 0..advance-1 (the bucket list wraps, but the base never does).
    for (var i = 0; i < advance; i++) {
      buckets[i] = 0;
    }
    return EmoteUsageRecord(
      lastUsedAt: record.lastUsedAt,
      buckets: buckets,
      bucketBase: hour,
    );
  }

  /// Keep-priority score at [now]; higher means the emote should stay cached.
  /// Only meaningful for records whose window covers [now] (roll first).
  double score(DateTime now) {
    final hours = now.difference(lastUsedAt).inHours;
    final r = math.exp(-hours / _recencyHalfLife.inHours.toDouble());
    var total = 0;
    for (final b in buckets) {
      total += b;
    }
    if (total == 0) return r;
    final steady = (total / _steadyRate).clamp(0.0, 1.0) * _entropy();
    return r + _steadyWeight * steady;
  }

  double _entropy() {
    var total = 0;
    for (final b in buckets) {
      total += b;
    }
    if (total == 0) return 0;
    var entropy = 0.0;
    for (final b in buckets) {
      if (b == 0) continue;
      final p = b / total;
      entropy -= p * math.log(p);
    }
    return entropy / math.log(_bucketCount.toDouble());
  }

  Map<String, dynamic> toJson() => {
    't': lastUsedAt.millisecondsSinceEpoch,
    'h': bucketBase,
    'b': buckets.join(','),
  };

  static EmoteUsageRecord? fromJson(Map<String, dynamic> json) {
    final t = json['t'];
    final h = json['h'];
    final b = json['b'];
    if (t is! int || h is! int || b is! String) return null;
    final buckets = <int>[];
    for (final part in b.split(',')) {
      final v = int.tryParse(part);
      if (v == null || v < 0) return null;
      buckets.add(v);
    }
    if (buckets.length != _bucketCount) return null;
    return EmoteUsageRecord(
      lastUsedAt: DateTime.fromMillisecondsSinceEpoch(t),
      buckets: buckets,
      bucketBase: h,
    );
  }
}

class EmoteManager extends ChangeNotifier {
  // Refresh TTLs: emote caches are only refetched once they're older than
  // the TTL. Unmetered connections refresh every 12h; cellular gets 24h so
  // the rake uses less data.
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
  final Future<List<GenericEmote>> Function(EmoteResolution resolution)
  _sevenTvGlobalFetcher;
  final EmoteCacheManager? _injectedCacheManager;
  EmoteCacheManager? _cacheManagerInstance;
  final EmoteMetaStore _metaStore;
  final Map<String, EmoteUsageRecord> _emoteUsage = {};

  /// Resolved lazily so constructing an [EmoteManager] (e.g. in tests) never
  /// instantiates the path-provider-backed cache singleton until it's needed.
  EmoteCacheManager get _cacheManager =>
      _cacheManagerInstance ??= (_injectedCacheManager ?? EmoteCacheManager());
  bool _usageLoaded = false;
  bool _usageDirty = false;
  bool _migrationRan = false;
  bool _migrationRanV2 = false;
  bool _disposed = false;

  final Future<List<ConnectivityResult>> Function()? _connectivityProbe;
  final Duration _fetchStagger;
  ConnectivityResult _probeResult = ConnectivityResult.wifi;
  DateTime? _probeAt;
  // Bounds in-flight provider fetches so a full refresh doesn't burst the
  // network, while letting more than one channel refresh at a time.
  static const _maxConcurrentFetches = 2;
  final _fetchGate = _Semaphore(_maxConcurrentFetches);

  // How long view-touch flushes wait for quiet before persisting. The emote
  // menu marks dozens of cells viewed on open; the debounce collapses that
  // burst into a single prefs write.
  static const _defaultUsageFlushDelay = Duration(milliseconds: 250);
  final Duration _usageFlushDelay;
  Timer? _usageFlushTimer;

  EmoteManager({
    Future<List<ConnectivityResult>> Function()? probe,
    this._fetchStagger = _defaultFetchStagger,
    Future<void> Function(String url)? removeCachedFile,
    DateTime Function()? now,
    EmoteFetchTier tier = EmoteFetchTier.high,
    int cacheCap = defaultEmoteCacheMax,
    this._usageFlushDelay = _defaultUsageFlushDelay,
    Future<SevenTvChannelResponse> Function(
      String channelId,
      EmoteResolution resolution,
    )?
    sevenTvChannelFetcher,
    Future<List<GenericEmote>> Function(EmoteResolution resolution)?
    sevenTvGlobalFetcher,
    EmoteCacheManager? cacheManager,
    EmoteMetaStore? metaStore,
    Future<Map<String, String>> Function(TwitchAuth auth, List<String> ids)?
    resolveOwnerLogins,
    Future<Map<String, List<GenericEmote>>> Function(
      List<String> setIds, {
      String? accessToken,
      EmoteResolution? resolution,
    })?
    fetchUserEmoteSets,
  }) : _connectivityProbe = probe,
       _injectedCacheManager = cacheManager,
       _metaStore = metaStore ?? EmoteMetaStore.I,
       _sevenTvChannelFetcher =
           sevenTvChannelFetcher ??
           ((String channelId, EmoteResolution resolution) =>
               SevenTvEmoteProvider.fetchChannelResponse(
                 channelId,
                 resolution: resolution,
               )),
       _sevenTvGlobalFetcher =
           sevenTvGlobalFetcher ??
           ((EmoteResolution resolution) =>
               SevenTvEmoteProvider.fetchGlobal(resolution: resolution)),
       _resolveOwnerLogins =
           resolveOwnerLogins ?? TwitchApi().getUserLoginsByIds,
       _fetchUserEmoteSets =
           fetchUserEmoteSets ??
           ((
             List<String> ids, {
             String? accessToken,
             EmoteResolution? resolution,
           }) => TwitchEmoteProvider.fetchEmoteSets(
             ids,
             accessToken: accessToken,
             resolution: resolution ?? EmoteResolution.high,
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
    cache.priorityScore = _registryScore;
    cache.lastUsedAt = (url) => _emoteUsage[url]?.lastUsedAt;
  }

  ChannelEmotes? _globalCache;
  final _channelCaches = <String, ChannelEmotes>{};
  final _channelFetchTimes = <String, DateTime>{};
  final _channelTwitchEmotes = <String, List<GenericEmote>>{};

  /// Resolves sub-emote owner ids to logins (default: Helix /users). Injected
  /// for tests; the manager owns the cache so grouping never needs a parallel
  /// map and reconnect can re-resolve without re-fetching.
  final Future<Map<String, String>> Function(TwitchAuth auth, List<String> ids)
  _resolveOwnerLogins;

  /// Fetches emote sets by id (default: Twitch EmoteProvider). Injected for
  /// tests so the daemon's fetch + resolve + store path is fully exercised
  /// without network access.
  final Future<Map<String, List<GenericEmote>>> Function(
    List<String> setIds, {
    String? accessToken,
    EmoteResolution? resolution,
  })
  _fetchUserEmoteSets;

  /// Emote-set ids already fetched via the IRC emote-sets path, so repeated
  /// USERSTATE (per channel join / message send) doesn't refetch them. Owned
  /// by the manager now so the daemon is the single source of fetch state.
  final Set<String> _fetchedEmoteSetIds = {};

  /// Set ids currently in flight; dropped on failure so the next event retries.
  final Set<String> _inflightEmoteSetIds = {};

  /// owner id -> login, built up across resolves and reused between reconnects.
  final Map<String, String> _emoteOwnerLogins = {};

  /// Last fetched user sub-emote sets keyed by owner id. Kept in memory so a
  /// reconnect can re-stamp resolved logins and re-store without re-fetching.
  final Map<String, List<GenericEmote>> _fetchedSubEmotesByOwner = {};
  final _sevenTvEmoteSetIds = <String, String>{};
  final _sevenTvUserIds = <String, String>{};
  // Last seen broadcaster id per channel, so targeted provider refetches can
  // run without the caller re-supplying it.
  final _channelBroadcasterIds = <String, String>{};
  // Per-provider retention: each provider's fetch result is kept separately so
  // a single flaky provider (429/5xx, timeout) never clobbers that provider's
  // previous good data or the other providers' entries in the merged cache.
  // Provider stash keys are ALWAYS EmoteType.name ('twitch', 'bttv', 'ffz',
  // 'sevenTv') — the same scheme _hasGlobalStash/_hasChannelStash and
  // _hydrateStashesFromCache read. Never write display labels here.
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
    if (_disposed) return;
    if (bumpVersion) _version++;
    _emoteIndexDirty = true;
    _changedChannel = channel;
    if (channel != null) {
      _mergedCache.remove(channel);
    } else {
      _mergedCache.clear();
    }
    super.notifyListeners();
  }

  /// Channel whose emotes changed; cleared on read.
  String? consumeChangedChannel() {
    final c = _changedChannel;
    _changedChannel = null;
    return c;
  }

  // 7TV delta codes per channel; absent after non-delta notifies.
  final _lastChangedCodes = <String, Set<String>>{};

  /// Last 7TV delta codes for [channel]; null means full refetch.
  Set<String>? consumeChangedCodes(String channel) {
    return _lastChangedCodes.remove(channel);
  }

  // Targets whose emote fetch failed since the last take (channel names, or
  // 'global emotes'), so a manual reload can surface partial failures instead
  // of reporting success.
  final Set<String> _fetchFailures = {};

  /// Targets (channel names, or 'global emotes') whose emote fetch failed
  /// since the last call; sorted, empty afterwards.
  List<String> takeFetchFailures() {
    final failed = _fetchFailures.toList()..sort();
    _fetchFailures.clear();
    return failed;
  }

  // Live 7TV list; re-applied after fetch rebuilds to avoid clobbering.
  final _sevenTvLive = <String, List<GenericEmote>>{};

  set accessToken(String? value) => _accessToken = value;

  // Merged emotes: channel overrides global. Cached until notify.
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
    result = _filterVisible(result);
    _mergedCache[channel] = result;
    return result;
  }

  // Display order for global grid (differs from dedup priority).
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

  // Global emotes by provider, in display order, sorted by code.
  Map<String, List<GenericEmote>> globalEmotesByProvider() {
    final cached = _filterVisible(_globalCache);
    if (cached == null) return {};
    final grouped = <EmoteType, List<GenericEmote>>{};
    for (final e in cached.suggestions) {
      (grouped[e.type] ??= []).add(e);
    }
    final result = <String, List<GenericEmote>>{};
    for (final t in _globalSortPriority.keys) {
      final list = grouped[t];
      if (list == null || list.isEmpty) continue;
      list.sort((a, b) => a.code.compareTo(b.code));
      result[_globalProviderLabels[t] ?? ''] = list;
    }
    return result;
  }

  List<GenericEmote> channelNonTwitchEmotes(String channel) {
    final cached = _filterVisible(_channelCaches[channel]);
    if (cached == null) return [];
    return cached.suggestions.where((e) => e.type != EmoteType.twitch).toList()
      ..sort((a, b) => a.code.compareTo(b.code));
  }

  /// Whether [channel]'s cache exists (stale is fine).
  bool hasChannelCache(String channel) => _channelCaches.containsKey(channel);

  /// Whether the global emote cache has been resolved at least once.
  bool get hasGlobalCache => _globalCache != null;

  Map<String, List<GenericEmote>>? _subsByChannelCache;

  Map<String, List<GenericEmote>> subscriberEmotesByChannel() {
    if (!_isProviderOn(EmoteType.twitch)) return {};
    final cached = _subsByChannelCache;
    if (cached != null) return cached;
    // Group subs by ownerChannel (or ownerId), dedup by id.
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
        ownerOf[key] = e.ownerChannel ?? e.ownerId ?? channel;
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

  // ── Provider visibility toggles ─────────────────────────────────────
  static const _disabledProvidersKey = 'emote_providers_disabled';
  final Set<EmoteType> _disabledProviders = {};
  bool _providersLoaded = false;

  // Whether unlisted 7TV emotes render. Fetch-only; flip rebuilds caches.
  static const _allowUnlisted7tvKey = 'emote_7tv_allow_unlisted';
  bool _allowUnlisted7tv = false;

  Future<void> _ensureProvidersLoaded() async {
    if (_providersLoaded) return;
    _providersLoaded = true;
    final prefs = await _getPrefs();
    final raw = prefs.getStringList(_disabledProvidersKey);
    var migrated = false;
    if (raw != null) {
      for (final t in EmoteType.values) {
        if (raw.contains(t.name)) _disabledProviders.add(t);
      }
      // Migrate: Twitch is no longer toggleable.
      if (_disabledProviders.remove(EmoteType.twitch)) migrated = true;
    }
    _allowUnlisted7tv = prefs.getBool(_allowUnlisted7tvKey) ?? false;
    if (!migrated) return;
    await prefs.setStringList(
      _disabledProvidersKey,
      _disabledProviders.map((t) => t.name).toList(),
    );
  }

  /// Whether [type] is fetched and rendered (sync view).
  bool isProviderEnabled(EmoteType type) {
    if (!_providersLoaded) unawaited(_ensureProvidersLoaded());
    return !_disabledProviders.contains(type);
  }

  /// Current enabled providers, awaiting the persisted load first.
  Future<Set<EmoteType>> enabledProviders() async {
    await _ensureProvidersLoaded();
    return {
      for (final t in EmoteType.values)
        if (!_disabledProviders.contains(t)) t,
    };
  }

  Future<void> setProviderEnabled(EmoteType type, bool enabled) async {
    await _ensureProvidersLoaded();
    final changed = enabled
        ? _disabledProviders.remove(type)
        : _disabledProviders.add(type);
    if (!changed) return;
    final prefs = await _getPrefs();
    await prefs.setStringList(
      _disabledProvidersKey,
      _disabledProviders.map((t) => t.name).toList(),
    );
    _rebuildCachesForProviderToggles();
  }

  /// Whether unlisted 7TV emotes render (sync view).
  bool get allowUnlisted7tv {
    if (!_providersLoaded) unawaited(_ensureProvidersLoaded());
    return _allowUnlisted7tv;
  }

  Future<void> setAllowUnlisted7tv(bool allowed) async {
    await _ensureProvidersLoaded();
    if (allowed == _allowUnlisted7tv) return;
    _allowUnlisted7tv = allowed;
    final prefs = await _getPrefs();
    await prefs.setBool(_allowUnlisted7tvKey, allowed);
    _rebuildCachesForProviderToggles();
  }

  // Filters disabled providers and unlisted 7TV from merged caches.
  ChannelEmotes? _filterVisible(ChannelEmotes? cache) {
    if (cache == null) return null;
    final hideUnlisted = !_allowUnlisted7tv;
    if (_disabledProviders.isEmpty && !hideUnlisted) return cache;
    final visible = cache.suggestions.where((e) {
      if (_disabledProviders.contains(e.type)) return false;
      if (hideUnlisted && e.isUnlisted) return false;
      return true;
    }).toList();
    return ChannelEmotes(
      byCode: {for (final e in visible) e.code: e},
      suggestions: visible,
    );
  }

  // Rebuilds caches from stashes on toggle; prefs-only sessions lack stashes.
  void _rebuildCachesForProviderToggles() {
    if (_globalProviderEmotes.isNotEmpty) {
      _globalCache = _buildChannelMap([
        for (final list in _globalProviderEmotes.values) ...list,
      ]);
    }
    for (final entry in _channelProviderEmotes.entries) {
      final subs = _channelTwitchEmotes[entry.key];
      if (entry.value.isEmpty && subs == null) continue;
      _channelCaches[entry.key] = _buildChannelMap([
        for (final list in entry.value.values) ...list,
        ...?subs,
      ]);
      _reapplyLiveSevenTv(entry.key);
    }
    _subsByChannelCache = null;
    _mergedCache.clear();
    _notify();
  }

  // Splits merged cache into per-provider stashes for toggle rebuilds.
  void _hydrateStashesFromCache(ChannelEmotes cache, {String? channel}) {
    final grouped = <String, List<GenericEmote>>{};
    for (final e in cache.suggestions) {
      (grouped[e.type.name] ??= []).add(e);
    }
    if (channel == null) {
      for (final entry in grouped.entries) {
        final existing = _globalProviderEmotes[entry.key];
        _globalProviderEmotes[entry.key] = [...?existing, ...entry.value];
      }
    } else {
      final map = _channelProviderEmotes[channel] ??=
          <String, List<GenericEmote>>{};
      for (final entry in grouped.entries) {
        final existing = map[entry.key];
        map[entry.key] = [...?existing, ...entry.value];
      }
    }
  }

  bool _hasGlobalStash(EmoteType type) =>
      _globalProviderEmotes[type.name]?.isNotEmpty ?? false;

  bool _hasChannelStash(String channel, EmoteType type) =>
      _channelProviderEmotes[channel]?[type.name]?.isNotEmpty ?? false;

  // Force refetches start from evict-wiped stashes; seed the missing
  // providers from the persisted cache so a flaky provider (429/5xx/timeout)
  // keeps its previous emotes instead of dropping out of the merged cache.
  void _seedMissingStashes(ChannelEmotes? cache, {String? channel}) {
    if (cache == null) return;
    final grouped = <String, List<GenericEmote>>{};
    for (final e in cache.suggestions) {
      (grouped[e.type.name] ??= []).add(e);
    }
    if (channel == null) {
      for (final entry in grouped.entries) {
        if (_globalProviderEmotes[entry.key]?.isNotEmpty ?? false) continue;
        _globalProviderEmotes[entry.key] = entry.value;
      }
    } else {
      final map = _channelProviderEmotes[channel] ??=
          <String, List<GenericEmote>>{};
      for (final entry in grouped.entries) {
        if (map[entry.key]?.isNotEmpty ?? false) continue;
        map[entry.key] = entry.value;
      }
    }
  }

  /// Refetches globals + channels for types with no retained stash.
  Future<void> ensureStashed(Set<EmoteType> types) async {
    await _ensureProvidersLoaded();
    if (_registryFrozen || _tier == EmoteFetchTier.nothing || types.isEmpty) {
      return;
    }
    final resolution = _tier.resolution;
    if (resolution == null) return;
    final targets = [
      for (final t in types)
        if (_isProviderOn(t)) t,
    ];
    if (targets.isEmpty) return;
    var fetched = false;
    await _enqueueFetch(() async {
      for (final type in targets.where((t) => !_hasGlobalStash(t))) {
        try {
          final emotes = await _fetchGlobalForProvider(type, resolution);
          _globalProviderEmotes[type.name] = emotes;
          if (emotes.isNotEmpty) fetched = true;
        } catch (e) {
          logDebug('[EmoteManager] stash refetch failed for ${type.name}: $e');
        }
      }
      for (final channel in _channelCaches.keys.toList()) {
        final broadcasterId = _channelBroadcasterIds[channel];
        if (broadcasterId == null) continue;
        final missing = [
          for (final t in targets)
            if (!_hasChannelStash(channel, t)) t,
        ];
        if (missing.isEmpty) continue;
        final map = _channelProviderEmotes[channel] ??=
            <String, List<GenericEmote>>{};
        for (final type in missing) {
          try {
            final emotes = await _fetchChannelForProvider(
              type,
              broadcasterId,
              channelName: channel,
              resolution: resolution,
            );
            map[type.name] = emotes;
            if (emotes.isNotEmpty) fetched = true;
          } catch (e) {
            logDebug(
              '[EmoteManager] stash refetch failed for '
              '${type.name}@$channel: $e',
            );
          }
        }
      }
    });
    if (fetched) _rebuildCachesForProviderToggles();
  }

  Future<List<GenericEmote>> _fetchGlobalForProvider(
    EmoteType type,
    EmoteResolution resolution,
  ) async {
    switch (type) {
      case EmoteType.twitch:
        return TwitchEmoteProvider.fetchGlobal(
          accessToken: _accessToken,
          resolution: resolution,
        );
      case EmoteType.bttv:
        return BttvEmoteProvider.fetchGlobal(resolution: resolution);
      case EmoteType.ffz:
        return FfzEmoteProvider.fetchGlobal(resolution: resolution);
      case EmoteType.sevenTv:
        return _sevenTvGlobalFetcher(resolution);
    }
  }

  Future<List<GenericEmote>> _fetchChannelForProvider(
    EmoteType type,
    String broadcasterId, {
    String? channelName,
    required EmoteResolution resolution,
  }) async {
    switch (type) {
      case EmoteType.twitch:
        final fetched = await TwitchEmoteProvider.fetchChannel(
          broadcasterId,
          accessToken: _accessToken,
          channelName: channelName,
          resolution: resolution,
        );
        // Subs live in _channelTwitchEmotes, not the provider stash.
        return fetched
            .where(
              (e) =>
                  !(e.type == EmoteType.twitch &&
                      (e.tier != null || e.emoteType == 'subscriptions')),
            )
            .toList();
      case EmoteType.bttv:
        return BttvEmoteProvider.fetchChannel(
          broadcasterId,
          resolution: resolution,
        );
      case EmoteType.ffz:
        return FfzEmoteProvider.fetchChannel(
          broadcasterId,
          resolution: resolution,
        );
      case EmoteType.sevenTv:
        final resp = await _sevenTvChannelFetcher(broadcasterId, resolution);
        if (channelName != null) {
          if (resp.emoteSetId != null) {
            setSevenTvEmoteSetId(channelName, resp.emoteSetId!);
          }
          if (resp.userId != null) {
            _sevenTvUserIds[channelName] = resp.userId!;
          }
        }
        return resp.emotes;
    }
  }

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
      logDebug('[EmoteManager] failed to parse recent emotes');
    }
  }

  Future<void> _saveRecent() async {
    final prefs = await _getPrefs();
    await prefs.setString(_recentKey, jsonEncode(_recentIds));
  }

  /// Recently used emote ids (most recent first), used to boost autocomplete
  /// ranking. The persisted list loads lazily, so the first keystroke after
  /// launch may rank without it.
  Set<String> get recentEmoteIds {
    if (!_recentLoaded) unawaited(_ensureRecentLoaded());
    return _recentIds.toSet();
  }

  /// Resolve an emote by ID across all caches.
  GenericEmote? emoteById(String id) => _emoteById(id);

  // Hot-path id index; rebuilt on notify/eviction.
  Map<String, GenericEmote> _emoteByIdIndex = {};
  bool _emoteIndexDirty = true;

  void _rebuildEmoteIndex() {
    final index = <String, GenericEmote>{};
    void addAll(Iterable<GenericEmote> emotes) {
      for (final e in emotes) {
        // putIfAbsent keeps scan-order precedence on id collisions.
        index.putIfAbsent(e.id, () => e);
      }
    }

    if (_globalCache != null) addAll(_globalCache!.suggestions);
    for (final cached in _channelCaches.values) {
      addAll(cached.suggestions);
    }
    for (final raw in _channelTwitchEmotes.values) {
      addAll(raw);
    }
    _emoteByIdIndex = index;
    _emoteIndexDirty = false;
  }

  /// Resolve an emote by ID across all caches.
  GenericEmote? _emoteById(String id) {
    if (_emoteIndexDirty) _rebuildEmoteIndex();
    return _emoteByIdIndex[id];
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

  /// Records emote display for cache eviction scoring.
  void markEmoteViewed(GenericEmote emote) {
    if (_tier == EmoteFetchTier.nothing) return;
    _touchUsage(emote.url);
    _scheduleUsageFlush();
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

  /// Resolves recents to channel-local codes via [suggestions].
  List<GenericEmote> resolveRecentsForChannel(
    List<GenericEmote> recents,
    List<GenericEmote> suggestions,
  ) {
    final byId = <String, GenericEmote>{};
    for (final e in suggestions) {
      byId.putIfAbsent(e.id, () => e);
    }
    final result = <GenericEmote>[];
    for (final recent in recents) {
      final resolved = byId[recent.id];
      if (resolved != null) result.add(resolved);
    }
    return result;
  }

  /// Loads global emotes. [force] skips cache, fetches from network.
  Future<void> preloadGlobalEmotes({bool force = false}) async {
    await _ensureProvidersLoaded();
    if (_globalCache != null && !force) return;
    final ttl = await _effectiveTtl();
    if (!force) {
      final loaded = await _loadPersistedCache('emotes3_global', ttl);
      final cached = loaded.cached;
      if (cached != null) {
        _globalCache = cached;
        // Hydrate stashes from persisted cache for offline toggle rebuild.
        _hydrateStashesFromCache(cached);
        _notify();
        if (loaded.fresh ||
            _registryFrozen ||
            _tier == EmoteFetchTier.nothing) {
          // Fresh cache: render, then background-refresh Twitch globals.
          if (!_skipTwitchBackgroundRefresh) {
            unawaited(_enqueueFetch(_refreshTwitchGlobalEmotes));
          }
          return;
        }
      }
      // Stale: keep stale data, revalidate below.
    }
    // Fetch every enabled provider.
    if (_tier == EmoteFetchTier.nothing) return;
    _seedMissingStashes(
      (await _loadPersistedCache('emotes3_global', ttl)).cached,
    );
    final emotes = await _enqueueFetch(_fetchAllGlobal);
    _globalCache = _buildChannelMap(emotes);
    await _savePersistedCache('emotes3_global', _globalCache!, ttl);
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
      // Fresh first, then non-tiered existing; dedup by id.
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

  /// Loads subscriber emotes: fetch, resolve owners, fan into channels.
  Future<void> loadUserEmoteSets(
    List<String> emoteSetIds,
    TwitchAuth auth,
    Map<String, String> openChannelUserIds,
  ) async {
    if (_tier == EmoteFetchTier.nothing) return;
    // Skip "0" (Twitch global, already loaded).
    final newSetIds = emoteSetIds
        .where(
          (id) =>
              id != '0' &&
              !_fetchedEmoteSetIds.contains(id) &&
              !_inflightEmoteSetIds.contains(id),
        )
        .toList();
    if (newSetIds.isEmpty) {
      // No new sets, but heal owner labels on reconnect.
      await _resolveOwners(auth, openChannelUserIds);
      await _reStoreCachedSubs(openChannelUserIds);
      return;
    }
    _inflightEmoteSetIds.addAll(newSetIds);
    try {
      final byOwner = await _fetchUserEmoteSets(
        newSetIds,
        accessToken: auth.accessToken,
        resolution: _tier.resolution!,
      );
      final perOwner = <String, List<GenericEmote>>{};
      for (final entry in byOwner.entries) {
        if (entry.key.isEmpty) continue;
        perOwner[entry.key] = entry.value;
        _fetchedSubEmotesByOwner[entry.key] = entry.value;
      }
      if (perOwner.isEmpty) {
        logDebug(
          'loadUserEmoteSets: ${newSetIds.length} sets fetched, no channel emotes',
        );
        return;
      }
      await _resolveOwners(auth, openChannelUserIds, ownerIds: perOwner.keys);
      final targets = openChannelUserIds.keys.toList();
      if (targets.isEmpty) {
        logDebug('loadUserEmoteSets: no channel targets');
        return;
      }
      final perChannel = _buildPerChannelEmotes(perOwner, targets);
      await storeUserTwitchEmotes(perChannel);
      _fetchedEmoteSetIds.addAll(newSetIds);
    } catch (e) {
      logDebug('loadUserEmoteSets failed: $e');
    } finally {
      // Keep fetched ids; failed ones retry on next USERSTATE.
      _inflightEmoteSetIds.removeAll(
        newSetIds.where((id) => !_fetchedEmoteSetIds.contains(id)),
      );
    }
  }

  /// Resolves owner ids to logins (open channels skip API).
  Future<void> _resolveOwners(
    TwitchAuth auth,
    Map<String, String> openChannelUserIds, {
    Iterable<String>? ownerIds,
  }) async {
    // Seed open-channel owners.
    for (final entry in openChannelUserIds.entries) {
      _emoteOwnerLogins[entry.value] = entry.key;
    }
    final owners = (ownerIds ?? _fetchedSubEmotesByOwner.keys)
        .where((id) => !_emoteOwnerLogins.containsKey(id))
        .toSet()
        .toList();
    if (owners.isEmpty) return;
    try {
      final resolved = await _resolveOwnerLogins(auth, owners);
      _emoteOwnerLogins.addAll(resolved);
    } catch (e) {
      logDebug('_resolveOwners failed: $e');
    }
  }

  /// Re-stores cached subs with resolved ownerChannel (reconnect heal).
  Future<void> _reStoreCachedSubs(
    Map<String, String> openChannelUserIds,
  ) async {
    if (_fetchedSubEmotesByOwner.isEmpty) return;
    final targets = openChannelUserIds.keys.toList();
    if (targets.isEmpty) return;
    await storeUserTwitchEmotes(
      _buildPerChannelEmotes(_fetchedSubEmotesByOwner, targets),
    );
  }

  /// Clears per-account emote state (account switch).
  void resetUserEmoteState() {
    _fetchedEmoteSetIds.clear();
    _inflightEmoteSetIds.clear();
    _emoteOwnerLogins.clear();
    _fetchedSubEmotesByOwner.clear();
    _subsByChannelCache = null;
  }

  /// Re-fetches subscriber emotes for the ids already known from a prior
  /// USERSTATE/GLOBALUSERSTATE. The manual emote reload would otherwise drop
  /// subs until the next IRC USERSTATE arrives, so call this from that path.
  Future<void> reloadUserEmoteSets(
    TwitchAuth auth,
    Map<String, String> openChannelUserIds,
  ) async {
    if (_tier == EmoteFetchTier.nothing) return;
    if (_fetchedEmoteSetIds.isEmpty) return;
    final ids = _fetchedEmoteSetIds.toList();
    _fetchedEmoteSetIds.clear();
    await loadUserEmoteSets(ids, auth, openChannelUserIds);
  }

  /// Builds per-channel subs map with owner stamps.
  Map<String, List<GenericEmote>> _buildPerChannelEmotes(
    Map<String, List<GenericEmote>> perOwner,
    List<String> targets,
  ) {
    final perChannel = <String, List<GenericEmote>>{};
    for (final target in targets) {
      perChannel[target] = <GenericEmote>[
        for (final entry in perOwner.entries)
          for (final e in entry.value)
            GenericEmote(
              id: e.id,
              code: e.code,
              type: e.type,
              url: e.url,
              url1x: e.url1x,
              url3x: e.url3x,
              isAnimated: e.isAnimated,
              scope: e.scope,
              tier: e.tier,
              emoteType: e.emoteType,
              ownerChannel: _emoteOwnerLogins[entry.key],
              ownerId: entry.key,
            ),
      ];
    }
    return perChannel;
  }

  /// Loads channel emotes. [force] skips cache, fetches from network.
  Future<void> resolveEmotes(
    String channel,
    String? broadcasterId, {
    bool force = false,
  }) async {
    await _ensureProvidersLoaded();
    if (broadcasterId != null) _channelBroadcasterIds[channel] = broadcasterId;
    final ttl = await _effectiveTtl();
    if (force) {
      // Nothing tier: render cached only.
      if (_tier == EmoteFetchTier.nothing) return;
      _seedMissingStashes(
        (await _loadPersistedCache('emotes3_$channel', ttl)).cached,
        channel: channel,
      );
      final emotes = await _enqueueFetch(
        () => _fetchAllChannel(broadcasterId, channelName: channel),
      );
      _applyChannelEmotes(channel, emotes);
      await _savePersistedCache(
        'emotes3_$channel',
        _channelCaches[channel]!,
        ttl,
      );
      return;
    }
    final loaded = await _loadPersistedCache(
      'emotes3_$channel',
      ttl,
      fetchTime: _channelFetchTimes[channel],
    );
    final cached = loaded.cached;
    if (cached != null) {
      // Re-merge subs not in persisted cache.
      final subs = _channelTwitchEmotes[channel] ?? const <GenericEmote>[];
      _channelCaches[channel] = subs.isEmpty
          ? cached
          : _buildChannelMap([...cached.suggestions, ...subs]);
      // Hydrate stashes from persisted cache.
      _hydrateStashesFromCache(cached, channel: channel);
      _reapplyLiveSevenTv(channel);
      _channelFetchTimes[channel] = DateTime.now();
      _notify(channel: channel);
      if (loaded.fresh || _registryFrozen || _tier == EmoteFetchTier.nothing) {
        // Fresh: render, background-refresh Twitch channel emotes.
        if (!_skipTwitchBackgroundRefresh) {
          unawaited(
            _enqueueFetch(
              () => _refreshTwitchChannelEmotes(channel, broadcasterId),
            ),
          );
        }
        // Reconcile 7TV deltas at startup.
        if (broadcasterId != null &&
            _tier.index >= EmoteFetchTier.medium.index) {
          unawaited(
            _enqueueFetch(() => _reconcileSevenTv(channel, broadcasterId)),
          );
        }
        return;
      }
      // Stale: keep stale data, revalidate below.
    }
    // Nothing tier: render cached only.
    if (_tier == EmoteFetchTier.nothing) return;
    final emotes = await _enqueueFetch(
      () => _fetchAllChannel(broadcasterId, channelName: channel),
    );
    _applyChannelEmotes(channel, emotes);
    await _savePersistedCache(
      'emotes3_$channel',
      _channelCaches[channel]!,
      ttl,
    );
  }

  void _applyChannelEmotes(String channel, List<GenericEmote> emotes) {
    // Empty fetch: keep cached emotes.
    if (emotes.isEmpty && _channelCaches[channel] != null) {
      logDebug('[EmoteManager] no emotes for $channel, keeping cached');
      return;
    }
    // Subs stored separately, re-merged via storeUserTwitchEmotes.
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

  // Re-applies live 7TV delta after fetch rebuild.
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

  // Merges fetch results with stored subs.
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
    await _ensureProvidersLoaded();
    if (!_isProviderOn(EmoteType.twitch)) return;
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
              <String, List<GenericEmote>>{})[EmoteType.twitch.name] =
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
      logDebug('[EmoteManager] twitch refresh failed for $channel: $e');
    }
  }

  Future<void> _refreshTwitchGlobalEmotes() async {
    await _ensureProvidersLoaded();
    if (!_isProviderOn(EmoteType.twitch)) return;
    try {
      final emotes = await TwitchEmoteProvider.fetchGlobal(
        accessToken: _accessToken,
        resolution: _tier.resolution!,
      );
      if (emotes.isEmpty) return;
      _globalProviderEmotes[EmoteType.twitch.name] = emotes;
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
      logDebug('[EmoteManager] twitch global refresh failed: $e');
    }
  }

  // Diffs 7TV set against cache at startup (medium/high).
  Future<void> _reconcileSevenTv(String channel, String broadcasterId) async {
    if (_tier.index < EmoteFetchTier.medium.index) return;
    await _ensureProvidersLoaded();
    if (!_isProviderOn(EmoteType.sevenTv)) return;
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
      // Empty fetch: keep cached 7TV emotes.
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
      logDebug('[EmoteManager] 7TV reconcile failed for $channel: $e');
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
    _channelBroadcasterIds.remove(channel);
    _mergedCache.remove(channel);
    _sevenTvLive.remove(channel);
    _emoteIndexDirty = true;
  }

  void evictGlobal() {
    _globalCache = null;
    _globalProviderEmotes.clear();
    _mergedCache.clear();
    _emoteIndexDirty = true;
  }

  /// Bumps the version and notifies listeners with the current (possibly
  /// empty) state, so cached message spans are discarded immediately.
  void notifyStateCleared() {
    _notify();
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

  // Applies 7TV WS deltas in place; evicts unused from disk cache.
  void updateSevenTvEmotes(
    String channel, {
    List<GenericEmote> added = const [],
    List<String> removedIds = const [],
    Map<String, ({String newName, String oldName})> renamed = const {},
  }) {
    if (_tier == EmoteFetchTier.nothing) return;
    if (!_isProviderOn(EmoteType.sevenTv)) return;
    var cache = _channelCaches[channel];
    if (cache == null && added.isEmpty) return;

    final changedCodes = <String>{};
    final removedIdsWithUrls = <(String, List<String>)>[];

    if (cache == null) {
      if (added.isEmpty) return;
      // No cache to diff against (not yet resolved, or evicted by a nuke).
      // Build a partial view so the delta's emotes render, but do NOT sync
      // it into the live view or provider stash: one delta isn't the full
      // set, and _reapplyLiveSevenTv would propagate it over the next full
      // fetch, wiping the channel's other emotes.
      final sorted = List.of(added)..sort((a, b) => a.code.compareTo(b.code));
      _channelCaches[channel] = ChannelEmotes(
        byCode: {for (final e in sorted) e.code: e},
        suggestions: sorted,
      );
      _emoteIndexDirty = true;
      _lastChangedCodes[channel] = {for (final e in added) e.code};
      _notify(channel: channel, bumpVersion: false);
      return;
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
            [
              e.url,
              if (e.url1x != null) e.url1x!,
              if (e.url3x != null) e.url3x!,
            ],
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
          url1x: e.url1x,
          url3x: e.url3x,
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

    // Sync stash and live list; concurrent fetch re-applies delta.
    final providerStash = _channelProviderEmotes[channel];
    if (providerStash != null &&
        providerStash.containsKey(EmoteType.sevenTv.name)) {
      providerStash[EmoteType.sevenTv.name] = cache.suggestions
          .where((e) => e.type == EmoteType.sevenTv)
          .toList();
    }
    _sevenTvLive[channel] = cache.suggestions
        .where((e) => e.type == EmoteType.sevenTv)
        .toList();

    _lastChangedCodes[channel] = changedCodes;
    // Live deltas don't bump span version (no retroactive re-render).
    _notify(channel: channel, bumpVersion: false);

    // Evict shared 7TV emotes from disk when gone from all channels.
    final unused = removedIdsWithUrls.where(
      (entry) => !_isEmoteUsedElsewhere(entry.$1),
    );
    if (unused.isNotEmpty) {
      unawaited(_evictEmoteImages([for (final entry in unused) ...entry.$2]));
    }
  }

  // Removes code from sorted list in place.
  void _removeFromSuggestions(List<GenericEmote> list, String code) {
    final index = list.indexWhere((e) => e.code == code);
    if (index != -1) list.removeAt(index);
  }

  // Inserts into sorted list, replacing same-code entry.
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
        logDebug('[EmoteManager] failed to evict unused emote $url');
      }
    }
    if (removed) {
      _usageDirty = true;
      await _flushUsage();
    }
  }

  /// Low/nothing tiers: no Twitch background refresh (infinite TTL).
  bool get _skipTwitchBackgroundRefresh =>
      _tier == EmoteFetchTier.low || _tier == EmoteFetchTier.nothing;

  /// Low tier: frozen registries (seed fetch only, force bypasses).
  bool get _registryFrozen => _tier == EmoteFetchTier.low;

  /// TTL varies by connectivity (longer on cellular).
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

  /// Cached connectivity probe (avoids per-fetch platform calls).
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

  /// Enqueues fetch with concurrency gate and stagger.
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

  /// Sync gate for fetch lambdas; callers must have awaited
  /// [_ensureProvidersLoaded] first.
  bool _isProviderOn(EmoteType type) => !_disabledProviders.contains(type);

  ChannelEmotes _buildChannelMap(List<GenericEmote> emotes) {
    // Disabled providers excluded from all caches.
    final visible = _disabledProviders.isEmpty
        ? emotes
        : emotes.where((e) => !_disabledProviders.contains(e.type)).toList();
    // Scope > provider priority dedup.
    final best = <String, GenericEmote>{};
    final seenScope = <String, int>{};
    for (final emote in visible) {
      final existing = best[emote.code];
      if (existing == null) {
        best[emote.code] = emote;
        seenScope[emote.code] = emote.scope.index;
        continue;
      }
      final existingScopePrio = seenScope[emote.code] ?? 0;
      final newScopePrio = emote.scope.index;
      // Channel scope wins over global.
      if (newScopePrio > existingScopePrio) {
        best[emote.code] = emote;
        seenScope[emote.code] = newScopePrio;
      } else if (newScopePrio == existingScopePrio) {
        // Same scope: provider precedence.
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
    await _ensureProvidersLoaded();
    final providers = <EmoteType, Future<List<GenericEmote>> Function()>{
      EmoteType.twitch: () async {
        if (!_isProviderOn(EmoteType.twitch)) return [];
        final emotes = await TwitchEmoteProvider.fetchGlobal(
          accessToken: _accessToken,
          resolution: _tier.resolution!,
        );
        // Empty fetch: keep the retained stash entry.
        if (emotes.isNotEmpty) {
          _globalProviderEmotes[EmoteType.twitch.name] = emotes;
        }
        return emotes;
      },
      EmoteType.bttv: () async {
        if (!_isProviderOn(EmoteType.bttv)) return [];
        final emotes = await BttvEmoteProvider.fetchGlobal(
          resolution: _tier.resolution!,
        );
        if (emotes.isNotEmpty) {
          _globalProviderEmotes[EmoteType.bttv.name] = emotes;
        }
        return emotes;
      },
      EmoteType.ffz: () async {
        if (!_isProviderOn(EmoteType.ffz)) return [];
        final emotes = await FfzEmoteProvider.fetchGlobal(
          resolution: _tier.resolution!,
        );
        if (emotes.isNotEmpty) {
          _globalProviderEmotes[EmoteType.ffz.name] = emotes;
        }
        return emotes;
      },
      EmoteType.sevenTv: () async {
        if (!_isProviderOn(EmoteType.sevenTv)) return [];
        final emotes = await _sevenTvGlobalFetcher(_tier.resolution!);
        if (emotes.isNotEmpty) {
          _globalProviderEmotes[EmoteType.sevenTv.name] = emotes;
        }
        return emotes;
      },
    };
    await _fetchConcurrent(
      providers,
      maxConcurrent: 2,
      target: 'global emotes',
    );
    return <GenericEmote>[
      for (final list in _globalProviderEmotes.values) ...list,
    ];
  }

  Future<List<GenericEmote>> _fetchAllChannel(
    String? broadcasterId, {
    String? channelName,
  }) async {
    await _ensureProvidersLoaded();
    if (broadcasterId == null) {
      // No broadcaster id: keep retained channel emotes.
      final retained = _channelProviderEmotes[channelName];
      if (retained == null) return [];
      return <GenericEmote>[for (final list in retained.values) ...list];
    }
    final channelKey = channelName ?? '';
    final map = _channelProviderEmotes[channelKey] ??=
        <String, List<GenericEmote>>{};
    final providers = <EmoteType, Future<List<GenericEmote>> Function()>{
      EmoteType.twitch: () async {
        if (!_isProviderOn(EmoteType.twitch)) return [];
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
        // Empty fetch: keep the retained stash entry (same rule as
        // _applyChannelEmotes) so a silent non-200 can't clobber it.
        if (nonSub.isNotEmpty) map[EmoteType.twitch.name] = nonSub;
        return nonSub;
      },
      EmoteType.bttv: () async {
        if (!_isProviderOn(EmoteType.bttv)) return [];
        final emotes = await BttvEmoteProvider.fetchChannel(
          broadcasterId,
          resolution: _tier.resolution!,
        );
        if (emotes.isNotEmpty) map[EmoteType.bttv.name] = emotes;
        return emotes;
      },
      EmoteType.ffz: () async {
        if (!_isProviderOn(EmoteType.ffz)) return [];
        final emotes = await FfzEmoteProvider.fetchChannel(
          broadcasterId,
          resolution: _tier.resolution!,
        );
        if (emotes.isNotEmpty) map[EmoteType.ffz.name] = emotes;
        return emotes;
      },
      EmoteType.sevenTv: () async {
        if (!_isProviderOn(EmoteType.sevenTv)) return [];
        final resp = await _sevenTvChannelFetcher(
          broadcasterId,
          _tier.resolution!,
        );
        if (channelName != null) {
          if (resp.emoteSetId != null) {
            setSevenTvEmoteSetId(channelName, resp.emoteSetId!);
          }
          if (resp.userId != null) {
            _sevenTvUserIds[channelName] = resp.userId!;
          }
        }
        if (resp.emotes.isNotEmpty) map[EmoteType.sevenTv.name] = resp.emotes;
        return resp.emotes;
      },
    };
    await _fetchConcurrent(providers, maxConcurrent: 3, target: channelName);
    return <GenericEmote>[for (final list in map.values) ...list];
  }

  Future<void> _fetchConcurrent(
    Map<EmoteType, Future<List<GenericEmote>> Function()> providers, {
    required int maxConcurrent,
    String? target,
  }) async {
    final sem = _Semaphore(maxConcurrent);
    final futures = <Future<void>>[];
    for (final entry in providers.entries) {
      futures.add(
        sem.withPermit(() async {
          try {
            await entry.value();
          } catch (e) {
            if (target != null) _fetchFailures.add(target);
            logDebug('EmoteManager: ${entry.key.name} failed: $e');
          }
        }),
      );
    }
    await Future.wait(futures, eagerError: false);
  }

  Future<({ChannelEmotes? cached, bool fresh})> _loadPersistedCache(
    String key,
    Duration ttl, {
    DateTime? fetchTime,
  }) async {
    final prefs = await _getPrefs();
    await _metaStore.migrateFromPrefs(prefs);
    final raw = await _metaStore.read(key);
    if (raw == null) return (cached: null, fresh: false);
    try {
      // Decode off main isolate for smooth startup.
      final tierIndex = _tier.index;
      final parsed = await Isolate.run(() {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final list = (data['emotes'] as List<dynamic>)
            .map((e) => GenericEmote.fromJson(e as Map<String, dynamic>))
            .toList();
        final tierMatches = data['tier'] is! int || data['tier'] == tierIndex;
        return (list: list, tierMatches: tierMatches, ts: data['ts'] as String);
      });
      final ts = DateTime.parse(parsed.ts);
      final cachedTime = fetchTime ?? ts;
      final withinTtl = DateTime.now().difference(cachedTime) <= ttl;
      final fresh = withinTtl && parsed.tierMatches;
      return (cached: _buildChannelMap(parsed.list), fresh: fresh);
    } catch (_) {
      logDebug('[EmoteManager] failed to parse cached emotes');
      return (cached: null, fresh: false);
    }
  }

  Future<void> _savePersistedCache(
    String key,
    ChannelEmotes channelEmotes,
    Duration ttl,
  ) async {
    // Low/nothing: persist Twitch too (zero network). Medium/high: non-Twitch only.
    final persistTwitch =
        _tier == EmoteFetchTier.low || _tier == EmoteFetchTier.nothing;
    final saved = channelEmotes.suggestions.where((e) {
      if (e.type != EmoteType.twitch) return true;
      if (!persistTwitch) return false;
      return !(e.emoteType == 'subscriptions' || e.tier != null);
    }).toList();
    if (saved.isEmpty) return;
    try {
      final data = {
        'ts': DateTime.now().toIso8601String(),
        'tier': _tier.index,
        'emotes': saved.map((e) => e.toJson()).toList(),
      };
      await _metaStore.write(key, jsonEncode(data));
    } catch (_) {
      logDebug('[EmoteManager] failed to save emotes to disk');
    }
  }

  /// Prunes persisted registries for left channels.
  Future<void> pruneStaleChannels(Set<String> activeChannels) async {
    try {
      for (final key in await _metaStore.keys()) {
        if (!key.startsWith('emotes3_')) continue;
        final channel = key.substring('emotes3_'.length);
        if (channel.isEmpty || channel == 'global') continue;
        if (!activeChannels.contains(channel)) {
          await _metaStore.delete(key);
        }
      }
    } catch (_) {}
  }

  /// Deletes all persisted emote metadata (global + per channel), including
  /// left channels. Used by the nuke action so the refetch rebuilds from the
  /// network instead of reseeding from disk.
  Future<void> wipePersisted() async {
    try {
      for (final key in await _metaStore.keys()) {
        if (key.startsWith('emotes3_')) await _metaStore.delete(key);
      }
    } catch (_) {
      logDebug('[EmoteManager] failed to wipe persisted emotes');
    }
  }

  // ── Disk-cache GC: usage tracking ───────────────────────────────────

  /// Usage registry capped at max(300, _cacheCap).
  int get _usageMaxEntries =>
      _cacheCap > _usageMinEntries ? _cacheCap : _usageMinEntries;

  final Set<String> _pendingUsageTouches = {};

  /// Eviction score; null falls back to recency decay.
  double? _registryScore(String url) {
    final record = _emoteUsage[url];
    if (record == null) return null;
    final now = _now();
    final hour = now.millisecondsSinceEpoch ~/ _hourMs;
    final rolled = EmoteUsageRecord.rolledForward(record, hour);
    if (!identical(rolled, record)) _emoteUsage[url] = rolled;
    return rolled.score(now);
  }

  static const _hourMs = 3600000;

  void _touchUsage(String url) {
    if (url.isEmpty) return;
    if (!_usageLoaded) {
      // Defer until loaded to avoid clobbering persisted registry.
      _pendingUsageTouches.add(url);
      return;
    }
    final now = _now();
    final hour = now.millisecondsSinceEpoch ~/ _hourMs;
    final existing = _emoteUsage[url];
    _emoteUsage[url] = existing == null
        ? EmoteUsageRecord(
            lastUsedAt: now,
            bucketBase: hour,
            buckets: List.filled(EmoteUsageRecord._bucketCount, 0),
          ).bumpedAt(hour, now: now)
        : EmoteUsageRecord.bumped(existing, hour, now: now);
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
        final entries = data['e'];
        if (entries is Map<String, dynamic>) {
          final now = _now();
          final hour = now.millisecondsSinceEpoch ~/ _hourMs;
          for (final entry in entries.entries) {
            final value = entry.value;
            if (value is! Map<String, dynamic>) continue;
            final record = EmoteUsageRecord.fromJson(value);
            if (record == null) continue;
            _emoteUsage[entry.key] = EmoteUsageRecord.rolledForward(
              record,
              hour,
            );
          }
        }
      } catch (_) {
        logDebug('[EmoteManager] failed to parse emote usage registry');
      }
    }
    if (_pendingUsageTouches.isNotEmpty) {
      for (final url in _pendingUsageTouches) {
        _touchUsage(url);
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
      // Drop lowest-scored entries.
      final now = _now();
      final entries = _emoteUsage.entries.toList()
        ..sort((a, b) => a.value.score(now).compareTo(b.value.score(now)));
      final overflow = entries.length - _usageMaxEntries;
      for (final entry in entries.take(overflow)) {
        _emoteUsage.remove(entry.key);
      }
    }
    final prefs = await _getPrefs();
    final data = <String, dynamic>{
      'v': 2,
      'e': {
        for (final entry in _emoteUsage.entries)
          entry.key: entry.value.toJson(),
      },
    };
    final encoded = await Isolate.run(() => jsonEncode(data));
    await prefs.setString(_usageKey, encoded);
  }

  /// Debounced flush for high-frequency view tracking.
  void _scheduleUsageFlush() {
    if (!_usageLoaded) return;
    _usageFlushTimer?.cancel();
    _usageFlushTimer = Timer(_usageFlushDelay, () {
      _usageFlushTimer = null;
      unawaited(_flushUsage());
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _usageFlushTimer?.cancel();
    _precacheQueue.clear();
    super.dispose();
  }

  // ── Cache init + migrations ─────────────────────────────────────────

  /// Runs migrations, registers priority source, enforces cap.
  Future<void> startCacheGc() async {
    await _ensureUsageLoaded();
    final cache = _cacheManager;
    cache.maxObjects = _cacheCap;
    cache.priorityScore = _registryScore;
    cache.lastUsedAt = (url) => _emoteUsage[url]?.lastUsedAt;
    if (!_migrationRan) {
      final prefs = await _getPrefs();
      if (prefs.getBool(_migrationKey) ?? false) {
        _migrationRan = true;
      } else {
        // First launch after GC: clear old cache (untracked by usage registry).
        try {
          await DefaultCacheManager().emptyCache();
        } catch (_) {
          logDebug('[EmoteManager] cache migration emptyCache failed');
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
        // v2 migration: clear v1 DefaultCacheManager leftovers.
        try {
          await DefaultCacheManager().emptyCache();
        } catch (_) {
          logDebug('[EmoteManager] cache v2 migration emptyCache failed');
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
  // Bounded dedup and queue to prevent unbounded growth.
  static const _maxSeenEmoteIds = 2000;
  static const _maxPrecacheQueue = 300;

  void enqueueSeenEmotes(List<GenericEmote> emotes) {
    // Nothing tier: skip fetch and usage tracking.
    if (_tier == EmoteFetchTier.nothing) return;
    final fresh = <GenericEmote>[];
    for (final e in emotes) {
      if (_seenEmoteIds.add(e.id)) {
        fresh.add(e);
      }
    }
    if (fresh.isEmpty) return;
    // Evict oldest-seen ids instead of clearing the set.
    while (_seenEmoteIds.length > _maxSeenEmoteIds) {
      final it = _seenEmoteIds.iterator;
      it.moveNext();
      _seenEmoteIds.remove(it.current);
    }
    for (final e in fresh) {
      _touchUsage(e.url);
    }
    // Zero cap: skip precache (eviction would delete immediately).
    if (_cacheCap > 0) {
      _precacheQueue.addAll(fresh);
      // Bound queue: drop oldest pending when outpacing drain.
      if (_precacheQueue.length > _maxPrecacheQueue) {
        _precacheQueue.removeRange(
          0,
          _precacheQueue.length - _maxPrecacheQueue,
        );
      }
      if (!_isProcessingPrecache) {
        _processPrecacheQueue();
      }
    }
    _scheduleUsageFlush();
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
      logDebug('[EmoteManager] failed to precache emote: ${emote.code}');
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
