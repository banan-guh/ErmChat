import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import '../emotes/emote.dart';
import '../util/log.dart';
import '../util/prefs.dart';

/// Eviction-priority contract the image byte cache reads.
///
/// Implemented by the emote usage registry. The image module depends only on
/// this interface, never on the registry type, so bytes -> policy is a
/// one-way dependency.
abstract interface class EmoteImagePolicy {
  /// Keep-priority score for [url], or null when the URL has no history.
  double? score(String url);

  /// Last-use time for [url], or null when the URL has no history.
  DateTime? lastUsedAt(String url);
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
/// Pure logic (no I/O); [EmoteUsageRegistry] owns persistence. The bucket
/// index is anchored at [bucketBase] (unix hour of the oldest bucket) so
/// advancing an hour never shifts the list.
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
    final index = (hour - rolled.bucketBase) % _bucketCount;
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

/// Persisted view history plus recent-emote ids.
///
/// Owns the usage histogram that feeds cache eviction priority and the
/// most-recently-used emote id list that boosts autocomplete. Plain Dart:
/// it resolves recents through a caller-supplied lookup, so it knows nothing
/// about the catalog, the store, or images.
class EmoteUsageRegistry implements EmoteImagePolicy {
  EmoteUsageRegistry({
    required this._capacity,
    DateTime Function()? now,
    this._flushDelay = _defaultFlushDelay,
  }) : _now = now ?? DateTime.now;

  static const _usageMinEntries = 300;
  static const _maxRecent = 100;
  static const _hourMs = 3600000;

  /// Bound on view touches queued before the registry loads; the oldest drop
  /// so an unloaded registry cannot accrete references.
  static const _maxPendingTouches = 2000;

  // How long view-touch flushes wait for quiet before persisting. The emote
  // menu marks dozens of cells viewed on open; the debounce collapses that
  // burst into a single prefs write.
  static const _defaultFlushDelay = Duration(milliseconds: 250);

  final int Function() _capacity;
  final DateTime Function() _now;
  final Duration _flushDelay;

  Prefs? _prefs;
  bool _usageLoaded = false;
  bool _usageDirty = false;
  Timer? _usageFlushTimer;
  final Map<String, EmoteUsageRecord> _emoteUsage = {};
  final Set<String> _pendingUsageTouches = {};

  List<String> _recentIds = [];
  bool _recentLoaded = false;

  // ── Usage policy ────────────────────────────────────────────────────
  /// Usage registry capped at max(300, capacity()).
  int get _usageMaxEntries {
    final cap = _capacity();
    return cap > _usageMinEntries ? cap : _usageMinEntries;
  }

  @override
  double? score(String url) {
    final record = _emoteUsage[url];
    if (record == null) return null;
    final now = _now();
    final hour = now.millisecondsSinceEpoch ~/ _hourMs;
    final rolled = EmoteUsageRecord.rolledForward(record, hour);
    if (!identical(rolled, record)) _emoteUsage[url] = rolled;
    return rolled.score(now);
  }

  @override
  DateTime? lastUsedAt(String url) => _emoteUsage[url]?.lastUsedAt;

  /// Records a view for eviction scoring; flushes on a quiet debounce.
  void touch(String url) {
    _touchUsage(url);
    scheduleFlush();
  }

  /// Records [urls] as used without scheduling a flush (the caller batches).
  void touchAll(Iterable<String> urls) {
    for (final url in urls) {
      _touchUsage(url);
    }
  }

  void _touchUsage(String url) {
    if (url.isEmpty) return;
    if (!_usageLoaded) {
      // Defer until loaded to avoid clobbering persisted registry.
      _pendingUsageTouches.add(url);
      while (_pendingUsageTouches.length > _maxPendingTouches) {
        _pendingUsageTouches.remove(_pendingUsageTouches.first);
      }
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

  /// Drops usage records for [urls] (live 7TV eviction) and flushes.
  Future<void> forgetUrls(Iterable<String> urls) async {
    await _ensureUsageLoaded();
    var removed = false;
    for (final url in urls) {
      if (url.isEmpty) continue;
      if (_emoteUsage.remove(url) != null) removed = true;
    }
    if (!removed) return;
    _usageDirty = true;
    await _flushUsage();
  }

  /// Debounced flush for high-frequency view tracking.
  /// Schedules a debounced usage flush (no-op before the registry loads).
  void scheduleFlush() {
    if (!_usageLoaded) return;
    _usageFlushTimer?.cancel();
    _usageFlushTimer = Timer(_flushDelay, () {
      _usageFlushTimer = null;
      unawaited(_flushUsage());
    });
  }

  Future<void> _ensureUsageLoaded() async {
    if (_usageLoaded) return;
    _usageLoaded = true;
    final prefs = await _getPrefs();
    final raw = prefs.emoteUsage;
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
        logDebug('[EmoteUsageRegistry] failed to parse emote usage registry');
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
    await prefs.setEmoteUsage(encoded);
  }

  /// Loads the persisted usage registry. Safe to call from cache setup.
  Future<void> ensureLoaded() => _ensureUsageLoaded();

  Future<Prefs> _getPrefs() async {
    _prefs ??= await Prefs.load();
    return _prefs!;
  }

  Future<void> flushForTesting() async {
    await _ensureUsageLoaded();
    await _flushUsage();
  }

  // ── Recents ─────────────────────────────────────────────────────────
  Future<void> _ensureRecentLoaded() async {
    if (_recentLoaded) return;
    _recentLoaded = true;
    final prefs = await _getPrefs();
    final raw = prefs.recentEmotes;
    if (raw == null) return;
    try {
      _recentIds = List<String>.from(jsonDecode(raw) as List<dynamic>);
    } catch (_) {
      logDebug('[EmoteUsageRegistry] failed to parse recent emotes');
    }
  }

  Future<void> _saveRecent() async {
    final prefs = await _getPrefs();
    await prefs.setRecentEmotes(jsonEncode(_recentIds));
  }

  /// Recently used emote ids as an unordered set (membership is all the
  /// ranking needs; the backing list is most-recent-first). The persisted list
  /// loads lazily, so the first keystroke after launch may rank without it.
  Set<String> get recentEmoteIds {
    if (!_recentLoaded) unawaited(_ensureRecentLoaded());
    return _recentIds.toSet();
  }

  /// Records [emote] as most recently used, then flushes immediately.
  Future<void> markEmoteUsed(Emote emote) async {
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

  /// Resolves recent ids to emotes via [resolve], dropping dead ids.
  Future<List<Emote>> recentEmotes(Emote? Function(String id) resolve) async {
    await _ensureRecentLoaded();
    final result = <Emote>[];
    for (final id in _recentIds) {
      final emote = resolve(id);
      if (emote != null) result.add(emote);
    }
    return result;
  }

  /// Resolves recents to channel-local codes via [suggestions].
  List<Emote> resolveRecentsForChannel(
    List<Emote> recents,
    List<Emote> suggestions,
  ) {
    final byId = <String, Emote>{};
    for (final e in suggestions) {
      byId.putIfAbsent(e.id, () => e);
    }
    final result = <Emote>[];
    for (final recent in recents) {
      final resolved = byId[recent.id];
      if (resolved != null) result.add(resolved);
    }
    return result;
  }

  void dispose() {
    _usageFlushTimer?.cancel();
    _usageFlushTimer = null;
    // Best-effort flush so a pending debounce is not dropped on teardown.
    if (_usageDirty) unawaited(_flushUsage());
    _pendingUsageTouches.clear();
  }
}
