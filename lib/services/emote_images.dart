import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../emotes/emote.dart';
import '../models/emote_fetch_tier.dart';
import '../util/log.dart';
import '../util/prefs.dart';
import 'emote_cache_manager.dart';
import 'emote_image_policy.dart';
import 'emote_probe_memo.dart';

/// The image black box: owns every emote image byte on disk and in flight.
///
/// Wraps the capped [EmoteCacheManager] (disk repo, eviction, overflow temp
/// files), the [EmoteProbeMemo] existence cache, the seen-emote precache
/// queue, and the cache-GC migrations. Priority scoring arrives through an
/// [EmoteImagePolicy], so bytes depend on policy and policy depends on
/// nothing here.
class EmoteImages {
  EmoteImages({
    EmoteImagePolicy? policy,
    EmoteCacheManager? cacheManager,
    EmoteProbeMemo? probeMemo,
    Future<void> Function(String url)? removeCachedFile,
    DateTime Function()? now,
  }) : _ownsCache = cacheManager == null,
       _cache = cacheManager ?? EmoteCacheManager(),
       _probe = probeMemo ?? EmoteProbeMemo(now: now) {
    _cache.policy = policy;
    _removeCachedFile =
        removeCachedFile ?? ((String url) => _cache.removeFile(url));
  }

  final EmoteCacheManager _cache;

  /// Whether this owner created the cache; an injected cache stays the
  /// caller's to close.
  final bool _ownsCache;

  bool _disposed = false;

  /// Whether [startCacheGc] ran, so teardown never closes a cache whose repo
  /// open is still in flight.
  bool _started = false;

  /// Memoized existence probes, shared by every render path.
  final EmoteProbeMemo _probe;

  late final Future<void> Function(String url) _removeCachedFile;

  EmoteProbeMemo get probe => _probe;

  EmoteCacheManager get cache => _cache;

  // ── Cap config ──────────────────────────────────────────────────────
  int _cacheCap = defaultEmoteCacheMax;

  int get cacheCap => _cacheCap;

  set cacheCap(int value) {
    _cacheCap = value.clamp(minEmoteCacheMax, maxEmoteCacheMax).toInt();
    _cache.maxObjects = _cacheCap;
  }

  /// Runs cache migrations, wires the cap, and enforces it once. One-time
  /// cache GC; usage loading happens in the coordinator before this.
  Future<void> startCacheGc() async {
    _started = true;
    _cache.maxObjects = _cacheCap;
    final prefs = await Prefs.load();
    if (!_migrationRan) {
      if (prefs.emoteGcMigratedV1) {
        _migrationRan = true;
      } else {
        // First launch after GC: clear old cache (untracked by usage registry).
        await _emptyLegacyCache('cache migration');
        _migrationRan = true;
        await prefs.setEmoteGcMigratedV1(true);
      }
    }
    if (!_migrationRanV2) {
      if (prefs.emoteGcMigratedV2) {
        _migrationRanV2 = true;
      } else {
        // v2 migration: clear v1 DefaultCacheManager leftovers.
        await _emptyLegacyCache('cache v2 migration');
        _migrationRanV2 = true;
        await prefs.setEmoteGcMigratedV2(true);
      }
    }
    await _cache.enforceNow();
  }

  Future<void> _emptyLegacyCache(String label) async {
    try {
      await DefaultCacheManager().emptyCache();
    } catch (_) {
      logDebug('[EmoteImages] $label emptyCache failed');
    }
  }

  bool _migrationRan = false;
  bool _migrationRanV2 = false;

  // ── Bytes ───────────────────────────────────────────────────────────
  /// Fetches emote bytes, streaming through the disk cache when there is room.
  Future<Uint8List> bytes(String url) async {
    // Stream through disk cache when room; skip to memory when full (the
    // overflow path is racy).
    if (!await _cache.isFull()) {
      await for (final response in _cache.getFileStream(url)) {
        if (response is FileInfo) {
          return response.file.readAsBytes();
        }
      }
      throw StateError('no emote bytes for $url');
    }
    // Full cache: try disk cache, then one shared network download.
    final cached = await _cache.getCachedFile(url);
    if (cached != null) {
      return cached.readAsBytes();
    }
    return _cache.getOverflowBytes(url, const {'User-Agent': 'ermchat'});
  }

  /// Removes [url] from the disk cache (live 7TV eviction).
  Future<void> removeFile(String url) => _removeCachedFile(url);

  /// Counts cached emote files on disk and their total size.
  Future<EmoteCacheStats> stats() => _cache.stats();

  /// Empties the entire emote image disk cache (nuke).
  Future<void> clear() => _cache.emptyCache();

  // ── Precache queue for seen emotes ──────────────────────────────────
  final Set<String> _seenEmoteIds = {};
  final _precacheQueue = <Emote>[];
  bool _isProcessingPrecache = false;
  static const _maxConcurrentPrecache = 5;
  // Bounded dedup and queue to prevent unbounded growth.
  static const _maxSeenEmoteIds = 2000;
  static const _maxPrecacheQueue = 300;

  /// Queues unseen [emotes] for background disk precache and returns the
  /// newly seen subset. Duplicates and over-cap ids are dropped; the queue
  /// drains at a bounded concurrency.
  List<Emote> precache(List<Emote> emotes) {
    final fresh = <Emote>[];
    for (final e in emotes) {
      if (_seenEmoteIds.add(e.id)) {
        fresh.add(e);
      }
    }
    if (fresh.isEmpty) return const [];
    // Evict oldest-seen ids instead of clearing the set.
    while (_seenEmoteIds.length > _maxSeenEmoteIds) {
      final it = _seenEmoteIds.iterator;
      it.moveNext();
      _seenEmoteIds.remove(it.current);
    }
    // Zero cap: skip precache (eviction would delete immediately).
    if (_cacheCap <= 0) return fresh;
    _precacheQueue.addAll(fresh);
    // Bound queue: drop oldest pending when outpacing drain.
    if (_precacheQueue.length > _maxPrecacheQueue) {
      _precacheQueue.removeRange(0, _precacheQueue.length - _maxPrecacheQueue);
    }
    if (!_isProcessingPrecache) {
      _processPrecacheQueue();
    }
    return fresh;
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

  Future<void> _precacheEmote(Emote emote) async {
    if (await _cache.isFull()) return;
    try {
      await _cache.getSingleFile(emote.url);
    } catch (_) {
      logDebug('[EmoteImages] failed to precache emote: ${emote.code}');
    }
  }

  int get precacheQueueLength => _precacheQueue.length;

  /// Releases the disk cache this owner created and drops the precache queue.
  /// Safe to call more than once.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _precacheQueue.clear();
    // An unopened repo can throw on close; the cache is being torn down anyway.
    if (_ownsCache && _started) {
      unawaited(_cache.dispose().catchError((Object _) {}));
    }
  }
}
