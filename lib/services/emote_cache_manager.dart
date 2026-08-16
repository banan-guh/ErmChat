import 'dart:async';
import 'dart:math' as math;

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/emote_fetch_tier.dart';

/// Shared HTTP client for the cache-full fallback path, reused across calls so
/// a burst of overflow downloads doesn't spin up a connection per emote.
/// Also used by the emote image loader's full-cache direct fetch.
final http.Client emoteFetchClient = http.Client();

/// Snapshot of the emote image disk cache.
class EmoteCacheStats {
  const EmoteCacheStats({required this.fileCount, required this.totalBytes});

  /// Number of cached emote image files currently on disk.
  final int fileCount;

  /// Combined size of those files in bytes.
  final int totalBytes;
}

/// Dedicated disk cache for emote images. Every emote render (chat, emote
/// menu, sheet, autocomplete, analytics) goes through this cache via
/// [CachedNetworkImageProvider.defaultCacheManager].
///
/// The cache never exceeds [maxObjects]: a write is only accepted while the
/// repo count (plus in-flight writes) is below the cap, so a burst of new
/// emotes can't overshoot it. When the cache is full, new emotes are served
/// from an OS temp file without ever entering the repo, so renders keep
/// working but the disk cache stays put (temp files are evicted once older
/// than [_overflowGrace], so a consumer can never race a deletion mid-read).
/// [isFull] backs the precacher's skip decision, and [enforceNow] (settings
/// Apply / startup) evicts down to a newly reduced cap by priority
/// ([lastUsedAt] registry lookup, falling back to the file's touched time).
/// The 2000-file manager cap is a safety net only.
class EmoteCacheManager extends CacheManager {
  static final EmoteCacheManager _instance = EmoteCacheManager._();

  factory EmoteCacheManager() => _instance;

  EmoteCacheManager._()
    : super(
        Config(
          'emoteImageCacheV2',
          maxNrOfCacheObjects: 2000,
          stalePeriod: const Duration(days: 30),
        ),
      );

  @visibleForTesting
  EmoteCacheManager.forTesting(super.config);

  static const _downloadTimeout = Duration(seconds: 10);

  /// Overflow temp files younger than this are never deleted: a consumer may
  /// still be reading them. Reads complete in milliseconds, so the grace is
  /// generous; only files that have certainly been consumed are evicted.
  static const _overflowGrace = Duration(seconds: 30);

  /// How long a repo object-count read is trusted. Bursts of fetches (e.g. an
  /// emote menu opening with dozens of cells) share one count within the TTL
  /// instead of re-scanning the repo per emote; [isFull] only gates soft
  /// decisions (persist vs. temp-file serve), so slight staleness is fine.
  static const _countTtl = Duration(milliseconds: 1500);

  int _maxObjects = defaultEmoteCacheMax;

  /// Writes currently in flight through the parent [CacheManager]. They will
  /// land in the repo shortly, so they count toward the cap while pending.
  int _pendingWrites = 0;

  /// Serialized read of the repo object count, coalesced across simultaneous
  /// callers and reused within [_countTtl] for sequential ones.
  Future<int>? _countRead;
  int? _cachedCount;
  DateTime? _cachedCountAt;

  /// Temp files served while the cache was full. Evicted only once they're
  /// older than [_overflowGrace] (the consumer has certainly read them by
  /// then); fresh files are never deleted, so a concurrent fetch can't hit a
  /// PathNotFoundException mid-read.
  final List<({File file, DateTime createdAt})> _overflowFiles = [];

  /// Keep-priority score for a cached URL, or null when there is no usage
  /// data (the file then falls back to a recency decay from its stored time).
  /// Set by [EmoteManager] from its usage registry.
  double? Function(String url)? priorityScore;

  /// Last-use time for a cached URL (used only for the eviction grace check,
  /// so a file a render is still reading is never deleted mid-read). Null
  /// when the URL has no usage history.
  DateTime? Function(String url)? lastUsedAt;

  /// Recency half-life for the no-registry fallback, matching the usage
  /// registry's own recency term.
  static const _fallbackHalfLife = Duration(hours: 6);

  /// Eviction candidates used/stored within this window are skipped: a
  /// render may still be reading the file (the same reason overflow temp
  /// files get a grace period).
  static const _evictionGrace = Duration(seconds: 2);

  /// Hard cap on cached emote files. Once reached, new emotes are served from
  /// temp files instead of being written to the cache.
  int get maxObjects => _maxObjects;

  set maxObjects(int value) {
    _maxObjects = value.clamp(minEmoteCacheMax, maxEmoteCacheMax).toInt();
  }

  /// True when the cache is at/over [maxObjects] (counting writes in flight).
  /// New emotes should then be served without persisting.
  Future<bool> isFull() async {
    final count = await _objectCount();
    return count + _pendingWrites >= _maxObjects;
  }

  /// The cached file for [url] when the repo still has it, else null. Read
  /// path for the cache-full branch: an emote that was persisted before the
  /// cache filled up must be served from disk instead of re-downloaded.
  Future<File?> getCachedFile(String url) async {
    try {
      final info = await getFileFromCache(url);
      return info?.file;
    } catch (_) {
      // DB or file gone; the caller falls back to the network.
      return null;
    }
  }

  /// Runs an enforcement pass immediately (used by the settings Apply path and
  /// at startup). Normally a no-op since writes are already capped; it only
  /// does work after the cap was reduced.
  Future<void> enforceNow() => _enforceCap();

  /// Reserves a write slot: accepts while under the cap, or evicts the
  /// lowest-priority cached file to free one. Returns false when the cache is
  /// full and nothing is evictable (repo empty or every candidate within the
  /// read grace); callers then serve from a temp file instead.
  Future<bool> _acquireWriteSlot() async {
    if (await _tryReserve()) return true;
    if (!await _evictLowest()) return false;
    // The eviction freed a slot; the cached "full" count is now stale.
    _invalidateCount();
    _pendingWrites++;
    return true;
  }

  Future<void> _invalidateCount() {
    _cachedCount = null;
    _cachedCountAt = null;
    return Future.value();
  }

  /// Reserves a write slot, or returns false when the cache is full. Callers
  /// must release the slot (via [_pendingWrites]-- ) after the write lands.
  Future<bool> _tryReserve() async {
    if (await isFull()) return false;
    _pendingWrites++;
    return true;
  }

  @override
  Future<File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async {
    if (!await _acquireWriteSlot()) {
      // Full: serve the already-cached copy if there is one; otherwise the
      // precacher skips this emote (it only wants files the cache keeps).
      try {
        final object = await config.repo.get(url);
        if (object != null) {
          return super.getSingleFile(url, key: key, headers: headers);
        }
      } catch (_) {
        // Fall through to the throw below; the caller handles it.
      }
      throw StateError('emote cache full: $url');
    }
    try {
      return await super.getSingleFile(url, key: key, headers: headers);
    } finally {
      _pendingWrites--;
    }
  }

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    // Ensure User-Agent is present (some CDNs 403 without it).
    final mergedHeaders = <String, String>{
      'User-Agent': 'ermchat',
      ...?headers,
    };

    if (!await _acquireWriteSlot()) {
      yield* _serveFromMemory(url, mergedHeaders, withProgress);
      return;
    }
    try {
      await for (final response in super.getFileStream(
        url,
        key: key,
        headers: mergedHeaders,
        withProgress: withProgress,
      )) {
        yield response;
      }
    } finally {
      _pendingWrites--;
    }
  }

  Future<int> _objectCount() {
    final inFlight = _countRead;
    if (inFlight != null) return inFlight;
    final cached = _cachedCount;
    final cachedAt = _cachedCountAt;
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _countTtl) {
      return Future.value(cached);
    }
    final read = _readObjectCount()..whenComplete(() => _countRead = null);
    _countRead = read;
    read.then((count) {
      _cachedCount = count;
      _cachedCountAt = DateTime.now();
    });
    return read;
  }

  Future<int> _readObjectCount() async {
    try {
      return (await config.repo.getAllObjects()).length;
    } catch (_) {
      // Can't enumerate the repo; treat it as full so we never overfill.
      return _maxObjects;
    }
  }

  Future<File> _nextOverflowFile() async {
    final dir = await getTemporaryDirectory();
    final file = const LocalFileSystem().file(
      '${dir.path}/emote_overflow_${DateTime.now().microsecondsSinceEpoch}',
    );
    await file.create();
    final now = DateTime.now();
    _overflowFiles.add((file: file, createdAt: now));
    // Evict only files old enough that their consumer has certainly finished
    // reading them. Fresh files are never deleted, so a concurrent fetch can't
    // race a deletion mid-read.
    final evictBefore = now.subtract(_overflowGrace);
    for (final entry in _overflowFiles.toList()) {
      if (entry.createdAt.isAfter(evictBefore)) continue;
      _overflowFiles.remove(entry);
      try {
        await entry.file.delete();
      } catch (_) {
        // The file is gone already or not deletable; the OS temp dir cleans up.
      }
    }
    return file;
  }

  /// Downloads the emote to a temp file outside the cache repo and streams it
  /// back as a [FileInfo], so renders work without growing the disk cache.
  Stream<FileResponse> _serveFromMemory(
    String url,
    Map<String, String>? headers,
    bool withProgress,
  ) async* {
    File? file;
    try {
      // Write slots are busy (or the cache is full): if the repo still has
      // the file, serve it instead of downloading a duplicate.
      final cached = await getCachedFile(url);
      if (cached != null) {
        yield FileInfo(
          cached,
          FileSource.Cache,
          DateTime.now().add(const Duration(hours: 1)),
          url,
        );
        return;
      }
      final request = http.Request('GET', Uri.parse(url));
      if (headers != null) request.headers.addAll(headers);
      // Some CDNs 403 bare requests; match what the main fetch path sends.
      request.headers.putIfAbsent('User-Agent', () => 'ermchat');
      final response = await emoteFetchClient
          .send(request)
          .timeout(_downloadTimeout);
      if (response.statusCode != 200) {
        throw HttpExceptionWithStatus(
          response.statusCode,
          'Failed to download $url: ${response.statusCode}',
          uri: Uri.parse(url),
        );
      }
      file = await _nextOverflowFile();
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream.timeout(_downloadTimeout)) {
          received += chunk.length;
          if (withProgress) {
            yield DownloadProgress(url, response.contentLength, received);
          }
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      yield FileInfo(
        file,
        FileSource.Online,
        DateTime.now().add(const Duration(hours: 1)),
        url,
      );
    } catch (e) {
      if (file != null) {
        try {
          await file.delete();
        } catch (_) {
          // Best-effort cleanup; the OS temp dir handles leftovers.
        }
      }
      rethrow;
    }
  }

  /// Serializes evictions so concurrent full-cache writes never race a
  /// removal against another eviction's scan.
  Future<bool> _evictionTail = Future.value(true);

  /// Evicts the lowest-priority cached file, returning false when nothing is
  /// evictable (empty repo, or every candidate is within [_evictionGrace] of
  /// its last use/store and might be mid-read).
  Future<bool> _evictLowest() {
    final tail = _evictionTail.then((_) async {
      try {
        final objects = await config.repo.getAllObjects();
        if (objects.isEmpty) return false;
        final now = DateTime.now();
        CacheObject? victim;
        double? bestScore;
        for (final object in objects) {
          if (_withinGrace(object, now)) continue;
          final score = _score(object);
          if (victim == null || score < bestScore!) {
            victim = object;
            bestScore = score;
          }
        }
        if (victim == null) return false;
        await removeFile(victim.url);
        debugPrint(
          '[EmoteCacheManager] evicted url=${victim.url} '
          'score=${bestScore!.toStringAsFixed(3)}',
        );
        return true;
      } catch (_) {
        // Enumeration or removal failed; the caller falls back to temp files.
        return false;
      }
    });
    _evictionTail = tail;
    return tail;
  }

  bool _withinGrace(CacheObject object, DateTime now) {
    final used = lastUsedAt?.call(object.url);
    if (used != null && now.difference(used).compareTo(_evictionGrace) < 0) {
      return true;
    }
    final touched = object.touched;
    return touched != null &&
        now.difference(touched).compareTo(_evictionGrace) < 0;
  }

  Future<void> _enforceCap() async {
    try {
      final objects = await config.repo.getAllObjects();
      if (objects.length <= _maxObjects) return;
      final overflow = objects.length - _maxObjects;
      objects.sort((a, b) => _score(a).compareTo(_score(b)));
      for (final object in objects.take(overflow)) {
        try {
          await removeFile(object.url);
        } catch (_) {
          // A missing file or a racing removal is fine - it's already gone.
        }
      }
    } catch (_) {
      // Enumeration can fail (e.g. db closed); the next pass retries.
    }
  }

  /// Keep-priority score: the registry's score when it has usage data,
  /// otherwise a recency decay from the file's stored time (unviewed files
  /// age out like unused registry entries).
  double _score(CacheObject object) {
    final scored = priorityScore?.call(object.url);
    if (scored != null) return scored;
    final stored =
        object.touched ?? DateTime.fromMillisecondsSinceEpoch(object.id ?? 0);
    final hours = DateTime.now().difference(stored).inHours;
    return math.exp(-hours / (_fallbackHalfLife.inHours.toDouble()));
  }

  /// Counts the cached emote files still present on disk and their total size
  /// (the recorded length is used when available, otherwise the file's real
  /// length). Returns an empty snapshot if the cache can't be inspected.
  Future<EmoteCacheStats> stats() async {
    try {
      final objects = await config.repo.getAllObjects();
      var count = 0;
      var bytes = 0;
      for (final object in objects) {
        final file = await config.fileSystem.createFile(object.relativePath);
        if (await file.exists()) {
          count++;
          bytes += object.length ?? await file.length();
        }
      }
      return EmoteCacheStats(fileCount: count, totalBytes: bytes);
    } catch (e) {
      return const EmoteCacheStats(fileCount: 0, totalBytes: 0);
    }
  }
}
