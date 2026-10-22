import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../emotes/emote.dart';
import '../emotes/emote_picker.dart';
import '../models/emote_fetch_tier.dart';
import '../util/data_usage.dart';
import '../util/set_notifier.dart';
import 'emote_cache_manager.dart';
import 'emote_probe_memo.dart';
import 'emote_usage_registry.dart';

/// The image black box: owns every emote image byte on disk and in flight.
///
/// Wraps the capped [EmoteCacheManager] (disk repo and byte-budget trim) and
/// the [EmoteProbeMemo] existence cache. Priority scoring arrives through an
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

  // ── Render tier + cache availability ────────────────────────────────
  EmoteFetchTier _tier = EmoteFetchTier.high;

  EmoteFetchTier get tier => _tier;

  /// Bumped when the tier or a cached URL changes, so render layers recompute.
  final SetValueNotifier<int> scaleRevision = SetValueNotifier<int>(0);

  void setTier(EmoteFetchTier value) {
    if (value == _tier) return;
    _tier = value;
    scaleRevision.value++;
  }

  /// Whether [url] is currently present in the disk cache. Probe failures are
  /// treated as not cached so a render degrades instead of throwing.
  Future<bool> isCached(String url) async {
    try {
      return await _probe.probe(
        url,
        (u) async => (await _cache.getFileFromCache(u)) != null,
      );
    } catch (_) {
      // A failed lookup reads as not cached.
      return false;
    }
  }

  /// Resolves the URL to render for [surface], probing every known scale.
  Future<({String url, String? placeholder})?> resolve(
    Emote emote,
    EmoteSurface surface,
  ) async {
    final available = <String, bool>{};
    for (final url in emote.scales.values) {
      available[url] = await isCached(url);
    }
    return EmotePicker.resolve(
      emote,
      surface,
      _tier,
      (u) => available[u] ?? false,
    );
  }

  /// Synchronous [resolve] when every scale's cache state is already memoized,
  /// so a warm emote paints on the first frame. Null defers to [resolve].
  ({String url, String? placeholder})? resolveSync(
    Emote emote,
    EmoteSurface surface,
  ) {
    final available = <String, bool>{};
    for (final url in emote.scales.values) {
      final cached = _probe.cached(url);
      if (cached == null) return null;
      available[url] = cached;
    }
    return EmotePicker.resolve(
      emote,
      surface,
      _tier,
      (u) => available[u] ?? false,
    );
  }

  // ── Cap config ──────────────────────────────────────────────────────
  int _cacheCapMb = defaultEmoteCacheMb;

  int get cacheCapMb => _cacheCapMb;

  set cacheCapMb(int value) {
    final next = value.clamp(minEmoteCacheMb, maxEmoteCacheMb).toInt();
    _cacheCapMb = next;
    _cache.maxBytes = _cacheCapMb * bytesPerMb;
  }

  /// Wires the cap and enforces it once. Usage loading happens in the
  /// coordinator before this.
  Future<void> startCacheGc() async {
    _started = true;
    _cache.maxBytes = _cacheCapMb * bytesPerMb;
    await _cache.enforceNow();
  }

  // ── Bytes ───────────────────────────────────────────────────────────
  /// Fetches emote bytes through the disk cache, downloading on a miss.
  Future<Uint8List> bytes(String url) async {
    // A background eviction can delete the file between lookup and read, so
    // one failed read retries through a fresh lookup.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await for (final response in _cache.getFileStream(url)) {
          if (response is FileInfo) {
            final bytes = await response.file.readAsBytes();
            if (response.source == FileSource.Online) {
              _noteDownload(url);
            } else if (!_downloaded.contains(url)) {
              DataUsageStats.I.recordEmoteImage(
                fromDisk: true,
                bytes: bytes.length,
              );
            }
            return bytes;
          }
        }
      } on FileSystemException {
        if (attempt == 1) rethrow;
      }
    }
    throw StateError('no emote bytes for $url');
  }

  // Urls downloaded this session, so a later disk read of one counts as
  // neither a saving nor a second download.
  final Set<String> _downloaded = {};
  static const _maxDownloaded = 2000;

  void _noteDownload(String url) {
    DataUsageStats.I.recordEmoteImage(fromDisk: false);
    _downloaded.add(url);
    if (_downloaded.length > _maxDownloaded) {
      _downloaded.remove(_downloaded.first);
    }
  }

  /// Removes [url] from the disk cache (live 7TV eviction).
  Future<void> removeFile(String url) async {
    await _removeCachedFile(url);
    _probe.forget(url);
  }

  /// Counts cached emote files on disk and their total size.
  Future<EmoteCacheStats> stats() => _cache.stats();

  /// Empties the entire emote image disk cache (nuke).
  Future<void> clear() async {
    await _cache.emptyCache();
    _probe.reset();
  }

  /// Releases the disk cache this owner created.
  /// Safe to call more than once.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    scaleRevision.dispose();
    // An unopened repo can throw on close; the cache is being torn down anyway.
    if (_ownsCache && _started) {
      unawaited(_cache.dispose().catchError((Object _) {}));
    }
  }
}
