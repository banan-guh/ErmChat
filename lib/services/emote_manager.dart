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
  // TODO(expand): connectivity-based refresh policy — e.g. a "refresh only on
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

  final Future<List<ConnectivityResult>> Function()? _connectivityProbe;
  final Duration _fetchStagger;
  ConnectivityResult _probeResult = ConnectivityResult.wifi;
  DateTime? _probeAt;
  Future<void> _fetchQueue = Future.value();

  EmoteManager({
    Future<List<ConnectivityResult>> Function()? probe,
    this._fetchStagger = _defaultFetchStagger,
  }) : _connectivityProbe = probe;
  ChannelEmotes? _globalCache;
  final _channelCaches = <String, ChannelEmotes>{};
  final _channelFetchTimes = <String, DateTime>{};
  final _lastErrors = <String, String>{};
  final _channelTwitchEmotes = <String, List<GenericEmote>>{};
  final _sevenTvEmoteSetIds = <String, String>{};
  final _sevenTvUserIds = <String, String>{};
  String? _accessToken;
  final _mergedCache = <String, ChannelEmotes?>{};
  String? _changedChannel;
  final recentNotifier = ChangeNotifier();

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

  String? get fetchError {
    if (_lastErrors.isEmpty) return null;
    return _lastErrors.entries.map((e) => '${e.key}: ${e.value}').join('; ');
  }

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

  List<String> get joinedChannels => _channelCaches.keys.toList()..sort();

  List<GenericEmote> globalEmotes() => _globalCache?.suggestions ?? [];

  List<GenericEmote> channelNonTwitchEmotes(String channel) {
    final cached = _channelCaches[channel];
    if (cached == null) return [];
    return cached.suggestions.where((e) => e.type != EmoteType.twitch).toList()
      ..sort((a, b) => a.code.compareTo(b.code));
  }

  List<GenericEmote> channelEmotes(String channel) {
    final cached = _channelCaches[channel];
    if (cached == null) return [];
    return cached.suggestions.toList()
      ..sort((a, b) => a.code.compareTo(b.code));
  }

  Map<String, List<GenericEmote>> subscriberEmotesByChannel() {
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
    return result;
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
    recentNotifier.notifyListeners();
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
    final loaded = await _loadFromPrefs('emotes2_global', ttl);
    final cached = loaded.cached;
    if (cached != null) {
      _globalCache = cached;
      _notify();
      if (loaded.fresh) return; // fresh cache — no network at all
    }
    // Stale or missing: keep showing stale data while revalidating.
    final emotes = await _enqueueFetch(_fetchAllGlobal);
    _globalCache = _buildChannelMap(emotes);
    await _saveToPrefs('emotes2_global', _globalCache!, ttl);
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
    _lastErrors.clear();
    final ttl = await _effectiveTtl();
    final loaded = await _loadFromPrefs(
      'emotes2_$channel',
      ttl,
      fetchTime: _channelFetchTimes[channel],
    );
    final cached = loaded.cached;
    if (cached != null) {
      _channelCaches[channel] = cached;
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
    await _saveToPrefs('emotes2_$channel', _channelCaches[channel]!, ttl);
  }

  void _applyChannelEmotes(String channel, List<GenericEmote> emotes) {
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
    _channelTwitchEmotes[channel] = nonSubEmotes
        .where((e) => e.type == EmoteType.twitch)
        .toList();
    _channelCaches[channel] = _buildChannelMap(nonSubEmotes);
    _channelFetchTimes[channel] = DateTime.now();
    _notify(channel);
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
      _channelTwitchEmotes[channel] = nonSub
          .where((e) => e.type == EmoteType.twitch)
          .toList();
      final existing = _channelCaches[channel];
      if (existing != null) {
        final merged = <GenericEmote>[
          ...existing.suggestions.where((e) => e.type != EmoteType.twitch),
          ...nonSub,
        ];
        _channelCaches[channel] = _buildChannelMap(merged);
      }
      _notify(channel);
    } catch (e) {
      debugPrint('[EmoteManager] twitch refresh failed for $channel: $e');
    }
  }

  void evictChannel(String channel) {
    _channelCaches.remove(channel);
    _channelFetchTimes.remove(channel);
    _channelTwitchEmotes.remove(channel);
    _sevenTvEmoteSetIds.remove(channel);
    _sevenTvUserIds.remove(channel);
    _mergedCache.remove(channel);
  }

  void evictGlobal() {
    _globalCache = null;
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
            isAnimated: e.isAnimated,
            scope: e.scope,
            isZeroWidth: e.isZeroWidth,
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

  /// Serializes all provider fetches into a single chain with a stagger
  /// between fetches, so a full refresh rakes channels one-by-one and the
  /// radio can idle between batches. Fresh caches never enter the queue.
  Future<T> _enqueueFetch<T>(Future<T> Function() action) {
    final result = _fetchQueue.then((_) async {
      await Future.delayed(_fetchStagger);
      return action();
    });
    _fetchQueue = result.then((_) {}, onError: (_) {});
    return result;
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
    _lastErrors.clear();
    final all = <GenericEmote>[];
    final providers = <String, Future<List<GenericEmote>> Function()>{
      'Twitch': () =>
          TwitchEmoteProvider.fetchGlobal(accessToken: _accessToken),
      'BTTV': BttvEmoteProvider.fetchGlobal,
      'FFZ': FfzEmoteProvider.fetchGlobal,
      '7TV': SevenTvEmoteProvider.fetchGlobal,
    };
    await _fetchConcurrent(providers, all, maxConcurrent: 2);
    return all;
  }

  Future<List<GenericEmote>> _fetchAllChannel(
    String? broadcasterId, {
    String? channelName,
  }) async {
    if (broadcasterId == null) return [];
    final all = <GenericEmote>[];
    final providers = <String, Future<List<GenericEmote>> Function()>{
      'Twitch': () => TwitchEmoteProvider.fetchChannel(
        broadcasterId,
        accessToken: _accessToken,
        channelName: channelName,
      ),
      'BTTV': () => BttvEmoteProvider.fetchChannel(broadcasterId),
      'FFZ': () => FfzEmoteProvider.fetchChannel(broadcasterId),
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
        return resp.emotes;
      },
    };
    await _fetchConcurrent(providers, all, maxConcurrent: 3);
    return all;
  }

  Future<void> _fetchConcurrent(
    Map<String, Future<List<GenericEmote>> Function()> providers,
    List<GenericEmote> out, {
    required int maxConcurrent,
  }) async {
    final sem = _Semaphore(maxConcurrent);
    final futures = <Future<void>>[];
    for (final entry in providers.entries) {
      futures.add(
        sem.withPermit(() async {
          try {
            out.addAll(await entry.value());
          } catch (e) {
            final msg = e.toString();
            debugPrint('EmoteManager: ${entry.key} failed: $msg');
            _lastErrors[entry.key] = msg;
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
    _precacheQueue.addAll(fresh);
    if (!_isProcessingPrecache) {
      _processPrecacheQueue();
    }
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

  @override
  void dispose() {
    _globalCache = null;
    _channelCaches.clear();
    _channelFetchTimes.clear();
    _channelTwitchEmotes.clear();
    _mergedCache.clear();
    super.dispose();
  }
}

class _Semaphore {
  final int maxPermits;
  int _permits;
  final List<Completer<void>> _queue = [];

  _Semaphore(this.maxPermits) : _permits = maxPermits;

  Future<void> withPermit(Future<void> Function() action) async {
    await _acquire();
    try {
      await action();
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
