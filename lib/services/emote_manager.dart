import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/generic_emote.dart';
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
  // the TTL. Unmetered connections refresh every 24h; cellular gets 48h so
  // the rake uses less data.
  // TODO(expand): connectivity-based refresh policy - e.g. a "refresh only on
  // wifi" settings toggle, skip channel rakes entirely on cellular,
  // per-connection image precache policy, data-usage stats.
  static const _wifiTtl = Duration(hours: 24);
  static const _mobileTtl = Duration(hours: 48);
  static const _connectivityProbeTtl = Duration(seconds: 60);
  static const _defaultFetchStagger = Duration(milliseconds: 1500);
  static const _providerPriority = {
    EmoteType.sevenTv: 0,
    EmoteType.bttv: 1,
    EmoteType.ffz: 2,
    EmoteType.twitch: 3,
  };

  // ── Disk-cache garbage collection ────────────────────────────────────
  // The flutter_cache_manager disk cache defaults to a 200-file count cap
  // with a 30-day stale period, which lets it balloon to hundreds of MB of
  // emote images. We GC it aggressively instead: keep at most [_gcMaxEmotes]
  // emotes, evicting overflow only once it's been unused for [_gcHotTtl],
  // and hard-evict anything unused for [_gcHardTtl] regardless of count.
  static const _gcMaxEmotes = 80;
  static const _gcHotTtl = Duration(hours: 1);
  static const _gcHardTtl = Duration(hours: 24);
  static const _gcInterval = Duration(minutes: 30);
  static const _usageKey = 'emote_usage';
  static const _usageMaxEntries = 300;
  static const _migrationKey = 'emote_gc_migrated_v1';

  final Future<void> Function(String url) _removeCachedFile;
  final DateTime Function() _now;
  final Map<String, DateTime> _emoteUsage = {};
  bool _usageLoaded = false;
  bool _usageDirty = false;
  bool _migrationRan = false;
  Timer? _gcTimer;

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
  }) : _connectivityProbe = probe,
       _removeCachedFile =
           removeCachedFile ??
           ((String url) => DefaultCacheManager().removeFile(url)),
       _now = now ?? DateTime.now;

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

  void _notify([String? channel]) {
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

  List<GenericEmote> globalEmotes() => _globalCache?.suggestions ?? [];

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
    final result = <String, List<GenericEmote>>{};
    final keys = _channelTwitchEmotes.keys.toList()..sort();
    for (final channel in keys) {
      final raw = _channelTwitchEmotes[channel];
      if (raw == null) continue;
      final subs =
          raw
              .where((e) => e.emoteType == 'subscriptions' || e.tier != null)
              .toList()
            ..sort((a, b) => a.code.compareTo(b.code));
      if (subs.isNotEmpty) result[channel] = subs;
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
        // Twitch global emotes aren't persisted (see _saveToPrefs), so they
        // refresh in the background on every launch — mirrors the channel
        // behavior. Non-blocking.
        unawaited(_enqueueFetch(_refreshTwitchGlobalEmotes));
        return;
      }
    }
    // Stale or missing: keep showing stale data while revalidating.
    final emotes = await _enqueueFetch(_fetchAllGlobal);
    _globalCache = _buildChannelMap(emotes);
    await _saveToPrefs('emotes3_global', _globalCache!, ttl);
    _notify();
  }

  Future<void> storeUserTwitchEmotes(
    Map<String, List<GenericEmote>> perChannel,
  ) async {
    for (final entry in perChannel.entries) {
      final channel = entry.key;
      final emotes = entry.value;
      if (emotes.isEmpty) continue;
      final existing = _channelTwitchEmotes[channel] ?? [];
      final merged = <GenericEmote>[
        for (final e in existing)
          if (e.tier == null) e,
        ...emotes,
      ];
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
      // The persisted cache never contains Twitch emotes, so re-merge any
      // subscriber emotes already stored for this channel (they come from the
      // account's own emote list and must not be clobbered by re-applying the
      // persisted cache).
      final subs = _channelTwitchEmotes[channel] ?? const <GenericEmote>[];
      _channelCaches[channel] = subs.isEmpty
          ? cached
          : _buildChannelMap([...cached.suggestions, ...subs]);
      _channelFetchTimes[channel] = DateTime.now();
      _notify(channel);
      if (loaded.fresh) {
        // Fresh cache: render immediately, then refresh only the Twitch
        // channel emotes in the background (they aren't persisted, so
        // sub-tier status changes between opens). Non-blocking.
        unawaited(
          _enqueueFetch(
            () => _refreshTwitchChannelEmotes(channel, broadcasterId),
          ),
        );
        return;
      }
      // Stale: keep showing stale data while revalidating below.
    }
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
    _channelFetchTimes[channel] = DateTime.now();
    _notify(channel);
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
      _notify(channel);
    } catch (e) {
      debugPrint('[EmoteManager] twitch refresh failed for $channel: $e');
    }
  }

  Future<void> _refreshTwitchGlobalEmotes() async {
    try {
      final emotes = await TwitchEmoteProvider.fetchGlobal(
        accessToken: _accessToken,
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

  void evictChannel(String channel) {
    _channelCaches.remove(channel);
    _channelFetchTimes.remove(channel);
    _channelTwitchEmotes.remove(channel);
    _subsByChannelCache = null;
    _sevenTvEmoteSetIds.remove(channel);
    _sevenTvUserIds.remove(channel);
    _channelProviderEmotes.remove(channel);
    _mergedCache.remove(channel);
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
  // WebSocket. Only affects 7TV-type emotes. Add checks scope and provider
  // priority to avoid downgrading higher-priority entries from other providers.
  void updateSevenTvEmotes(
    String channel, {
    List<GenericEmote> added = const [],
    List<String> removedIds = const [],
    Map<String, ({String newName, String oldName})> renamed = const {},
  }) {
    final cache = _channelCaches[channel];
    if (cache == null && added.isEmpty) return;

    final byCode = Map<String, GenericEmote>.from(cache?.byCode ?? {});

    for (final id in removedIds) {
      byCode.removeWhere((_, e) => e.id == id && e.type == EmoteType.sevenTv);
    }

    for (final entry in renamed.entries) {
      for (final e in byCode.values.toList()) {
        if (e.id == entry.key && e.type == EmoteType.sevenTv) {
          byCode.remove(e.code);
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
          byCode[entry.value.newName] = renamedEmote;
          break;
        }
      }
    }

    for (final emote in added) {
      final existing = byCode[emote.code];
      if (existing == null ||
          (existing.scope.index <= emote.scope.index &&
              _providerPriority[emote.type]! <
                  _providerPriority[existing.type]!)) {
        byCode[emote.code] = emote;
      }
    }

    final suggestions = byCode.values.toList()
      ..sort((a, b) => a.code.compareTo(b.code));
    _channelCaches[channel] = ChannelEmotes(
      byCode: byCode,
      suggestions: suggestions,
    );
    _notify(channel);
  }

  /// Connectivity-aware refresh TTL: refresh is cheaper on unmetered
  /// connections, so cellular gets a longer TTL to avoid data usage.
  Future<Duration> _effectiveTtl() async {
    final isMobile = await _probeConnectivity() == ConnectivityResult.mobile;
    return isMobile ? _mobileTtl : _wifiTtl;
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
        );
        _globalProviderEmotes['Twitch'] = emotes;
        return emotes;
      },
      'BTTV': () async {
        final emotes = await BttvEmoteProvider.fetchGlobal();
        _globalProviderEmotes['BTTV'] = emotes;
        return emotes;
      },
      'FFZ': () async {
        final emotes = await FfzEmoteProvider.fetchGlobal();
        _globalProviderEmotes['FFZ'] = emotes;
        return emotes;
      },
      '7TV': () async {
        final emotes = await SevenTvEmoteProvider.fetchGlobal();
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
        final emotes = await BttvEmoteProvider.fetchChannel(broadcasterId);
        map['BTTV'] = emotes;
        return emotes;
      },
      'FFZ': () async {
        final emotes = await FfzEmoteProvider.fetchChannel(broadcasterId);
        map['FFZ'] = emotes;
        return emotes;
      },
      '7TV': () async {
        final resp = await SevenTvEmoteProvider.fetchChannelResponse(
          broadcasterId,
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
      final fresh = DateTime.now().difference(cachedTime) <= ttl;
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
    final nonTwitch = channelEmotes.suggestions
        .where((e) => e.type != EmoteType.twitch)
        .toList();
    if (nonTwitch.isEmpty) return;
    try {
      final prefs = await _getPrefs();
      final data = {
        'ts': DateTime.now().toIso8601String(),
        'emotes': nonTwitch.map((e) => e.toJson()).toList(),
      };
      await prefs.setString(key, jsonEncode(data));
    } catch (_) {
      debugPrint('[EmoteManager] failed to save nonTwitch emotes to prefs');
    }
  }

  // ── Disk-cache GC: usage tracking ───────────────────────────────────

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

  // ── Disk-cache GC: sweep ────────────────────────────────────────────

  /// Starts the disk-cache garbage collector: runs the one-time migration,
  /// an immediate sweep, then a periodic sweep every [_gcInterval].
  Future<void> startCacheGc() async {
    await _ensureUsageLoaded();
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
    await runCacheGc();
    _gcTimer?.cancel();
    _gcTimer = Timer.periodic(_gcInterval, (_) => runCacheGc());
  }

  /// Runs one sweep of the disk-cache GC. Evicts anything unused for
  /// [_gcHardTtl] regardless of count, then trims to [_gcMaxEmotes] by
  /// evicting the oldest entries that are also unused for [_gcHotTtl].
  /// Exposed for tests; also cancellable via [dispose].
  Future<void> runCacheGc() async {
    await _ensureUsageLoaded();
    final now = _now();
    final evict = <String>[];
    for (final entry in _emoteUsage.entries) {
      if (now.difference(entry.value) > _gcHardTtl) {
        evict.add(entry.key);
      }
    }
    if (_emoteUsage.length > _gcMaxEmotes) {
      final sorted = _emoteUsage.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      final evictSet = evict.toSet();
      for (final entry in sorted) {
        if (_emoteUsage.length - evict.length <= _gcMaxEmotes) break;
        if (evictSet.contains(entry.key)) continue;
        if (now.difference(entry.value) > _gcHotTtl) {
          evict.add(entry.key);
        }
      }
    }
    if (evict.isEmpty) {
      await _flushUsage();
      return;
    }
    await Future.wait(
      evict.map((url) async {
        try {
          await _removeCachedFile(url);
        } catch (_) {
          debugPrint('[EmoteManager] cache GC failed to remove $url');
        }
      }),
      eagerError: false,
    );
    for (final url in evict) {
      _emoteUsage.remove(url);
      _usageDirty = true;
    }
    await _flushUsage();
  }

  /// Cancels the periodic GC sweep. Safe to call even if GC never started.
  @override
  void dispose() {
    _gcTimer?.cancel();
    _gcTimer = null;
    super.dispose();
  }

  // ── Pre-cache queue for seen emotes ──────────────────────────────────

  final Set<String> _seenEmoteIds = {};
  final _precacheQueue = <GenericEmote>[];
  bool _isProcessingPrecache = false;
  static const _maxConcurrentPrecache = 5;

  void enqueueSeenEmotes(List<GenericEmote> emotes) {
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
    _precacheQueue.addAll(fresh);
    if (!_isProcessingPrecache) {
      _processPrecacheQueue();
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
    try {
      await DefaultCacheManager().getSingleFile(emote.url);
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
