import 'dart:async';

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/emote_fetch_tier.dart';

/// Shared HTTP client for the cache-full fallback path, reused across calls so
/// a burst of overflow downloads doesn't spin up a connection per emote.
final http.Client _emoteFetchClient = http.Client();

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
/// emotes can't overshoot it. When the cache is full, new emotes are fetched
/// into an OS temp file and served as a [FileInfo] without ever entering the
/// repo, so renders keep working but the disk cache stays put. [isFull] backs
/// the precacher's skip decision, and [enforceNow] (settings Apply / startup)
/// evicts down to a newly reduced cap by priority ([lastUsedAt] registry
/// lookup, falling back to the file's touched time). The 2000-file manager
/// cap is a safety net only.
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
  static const _maxOverflowFiles = 8;

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

  /// Temp files served while the cache was full, kept small (FIFO) so the
  /// renderer has already read a file long before it gets deleted.
  final List<File> _overflowFiles = [];

  /// Last-used timestamp for a cached URL, or null to fall back to the file's
  /// own touched time. Set by [EmoteManager] from its usage registry.
  DateTime? Function(String url)? lastUsedAt;

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

  /// Runs an enforcement pass immediately (used by the settings Apply path and
  /// at startup). Normally a no-op since writes are already capped; it only
  /// does work after the cap was reduced.
  Future<void> enforceNow() => _enforceCap();

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
    if (!await _tryReserve()) {
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

    if (!await _tryReserve()) {
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
    _overflowFiles.add(file);
    if (_overflowFiles.length > _maxOverflowFiles) {
      final oldest = _overflowFiles.removeAt(0);
      try {
        await oldest.delete();
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
      final request = http.Request('GET', Uri.parse(url));
      if (headers != null) request.headers.addAll(headers);
      // Some CDNs 403 bare requests; match what the main fetch path sends.
      request.headers.putIfAbsent('User-Agent', () => 'ermchat');
      final response = await _emoteFetchClient
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

  Future<void> _enforceCap() async {
    try {
      final objects = await config.repo.getAllObjects();
      if (objects.length <= _maxObjects) return;
      final overflow = objects.length - _maxObjects;
      objects.sort((a, b) => _priority(a).compareTo(_priority(b)));
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

  DateTime _priority(CacheObject object) {
    final fromRegistry = lastUsedAt?.call(object.url);
    if (fromRegistry != null) return fromRegistry;
    return object.touched ??
        DateTime.fromMillisecondsSinceEpoch(object.id ?? 0);
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
