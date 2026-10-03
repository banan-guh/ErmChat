import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

import '../models/emote_fetch_tier.dart';
import '../util/data_usage.dart';
import '../util/log.dart';
import 'emote_usage_registry.dart';

/// Shared HTTP client for every emote image download. Process lifetime by
/// design: one client serves the whole app.
final http.Client emoteFetchClient = http.Client();

/// Snapshot of the emote image disk cache.
class EmoteCacheStats {
  const EmoteCacheStats({required this.fileCount, required this.totalBytes});

  /// Number of cached emote image files currently on disk.
  final int fileCount;

  /// Combined size of those files in bytes.
  final int totalBytes;
}

/// Byte budget and keep-priority for the emote disk cache. [maxBytes] and
/// [policy] are live settings the manager updates in place.
class EmoteCacheBudget {
  EmoteCacheBudget({this.maxBytes = defaultEmoteCacheMb * bytesPerMb});

  int maxBytes;

  /// Keep-priority policy for cached URLs, or null when there is no usage
  /// data (a file then falls back to a recency decay from its touched time).
  EmoteImagePolicy? policy;

  /// Recency half-life for the no-registry fallback score.
  static const _fallbackHalfLife = Duration(days: 3);

  /// Files used within this window are never trimmed, so a render mid-read
  /// cannot lose its file.
  static const readGrace = Duration(minutes: 1);

  /// Whether [totalBytes] fits. A zero budget fits nothing, so it clears
  /// rows with no recorded length too.
  bool fits(int totalBytes) => maxBytes > 0 && totalBytes <= maxBytes;

  /// Rows to delete, lowest priority first, until [objects] fit the budget.
  /// Rows inside [readGrace] are skipped, so the result can leave the cache
  /// over budget until they age out.
  List<CacheObject> overBudget(List<CacheObject> objects, DateTime now) {
    var total = 0;
    for (final object in objects) {
      total += object.length ?? 0;
    }
    if (fits(total)) return const [];
    // Score once per row; the sort compares the cached values.
    final candidates = [
      for (final object in objects)
        if (!_withinGrace(object, now))
          (object: object, score: score(object, now)),
    ]..sort((a, b) => a.score.compareTo(b.score));
    final victims = <CacheObject>[];
    for (final candidate in candidates) {
      if (fits(total)) break;
      final object = candidate.object;
      victims.add(object);
      total -= object.length ?? 0;
    }
    return victims;
  }

  /// Keep-priority: the registry score when it has usage data, else a recency
  /// decay from the file's touched time.
  double score(CacheObject object, DateTime now) {
    final scored = policy?.score(object.url);
    if (scored != null) return scored;
    final stored =
        object.touched ?? DateTime.fromMillisecondsSinceEpoch(object.id ?? 0);
    final hours = now.difference(stored).inHours;
    return math.exp(-hours / _fallbackHalfLife.inHours.toDouble());
  }

  bool _withinGrace(CacheObject object, DateTime now) {
    final used = policy?.lastUsedAt(object.url);
    if (used != null && now.difference(used) < readGrace) return true;
    final touched = object.touched;
    return touched != null && now.difference(touched) < readGrace;
  }
}

/// Repository decorator that makes flutter_cache_manager's own cleanup
/// byte-aware. The store asks [getObjectsOverCapacity] after cache activity
/// (at most every 10s); this answers from [budget] instead of an entry count,
/// so every download lands on disk and the cache trims itself in the
/// background.
class EmoteCacheRepository implements CacheInfoRepository {
  EmoteCacheRepository(this._inner, this.budget);

  final CacheInfoRepository _inner;
  final EmoteCacheBudget budget;

  /// Sum of cached file sizes: one SQL aggregate on the default sqflite
  /// repository, a full row read on any other.
  Future<int> totalBytes() async {
    final inner = _inner;
    final db = inner is CacheObjectProvider ? inner.db : null;
    if (db != null) {
      try {
        // Table name mirrors the package's private constant.
        final rows = await db.rawQuery(
          'SELECT COALESCE(SUM(${CacheObject.columnLength}), 0) AS total '
          'FROM cacheObject',
        );
        return (rows.first['total'] as num).toInt();
      } catch (e) {
        // Schema drift in the package: fall back to summing rows.
        logDebug('[EmoteCacheManager] SUM query failed, summing rows: $e');
      }
    }
    var total = 0;
    for (final object in await _inner.getAllObjects()) {
      total += object.length ?? 0;
    }
    return total;
  }

  /// File count and summed length from one SQL aggregate, plus rows with no
  /// recorded length. Returns null when the inner repository is not SQLite,
  /// so the caller enumerates every row instead.
  Future<({int count, int bytes, List<CacheObject> unknownLength})?>
  aggregate() async {
    final inner = _inner;
    final db = inner is CacheObjectProvider ? inner.db : null;
    if (db == null) return null;
    try {
      // Table name mirrors the package's private constant.
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS count, '
        'COALESCE(SUM(${CacheObject.columnLength}), 0) AS bytes '
        'FROM cacheObject WHERE ${CacheObject.columnLength} IS NOT NULL',
      );
      final unknown = await db.query(
        'cacheObject',
        where: '${CacheObject.columnLength} IS NULL',
      );
      final row = rows.first;
      return (
        count: (row['count'] as num).toInt(),
        bytes: (row['bytes'] as num).toInt(),
        unknownLength: CacheObject.fromMapList(unknown),
      );
    } catch (e) {
      // Schema drift in the package: let the caller enumerate rows.
      logDebug('[EmoteCacheManager] aggregate query failed: $e');
      return null;
    }
  }

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) async {
    if (budget.fits(await totalBytes())) return const [];
    final victims = budget.overBudget(
      await _inner.getAllObjects(),
      DateTime.now(),
    );
    for (final _ in victims) {
      DataUsageStats.I.recordEviction();
    }
    return victims;
  }

  @override
  Future<bool> exists() => _inner.exists();

  @override
  Future<bool> open() => _inner.open();

  @override
  Future<dynamic> updateOrInsert(CacheObject cacheObject) =>
      _inner.updateOrInsert(cacheObject);

  @override
  Future<CacheObject> insert(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) => _inner.insert(cacheObject, setTouchedToNow: setTouchedToNow);

  @override
  Future<CacheObject?> get(String key) => _inner.get(key);

  @override
  Future<int> delete(int id) => _inner.delete(id);

  @override
  Future<int> deleteAll(Iterable<int> ids) => _inner.deleteAll(ids);

  @override
  Future<int> update(CacheObject cacheObject, {bool setTouchedToNow = true}) =>
      _inner.update(cacheObject, setTouchedToNow: setTouchedToNow);

  @override
  Future<List<CacheObject>> getAllObjects() => _inner.getAllObjects();

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) =>
      _inner.getOldObjects(maxAge);

  @override
  Future<bool> close() => _inner.close();

  @override
  Future<void> deleteDataFile() => _inner.deleteDataFile();
}

/// Emote downloads: adds the User-Agent some CDNs require and counts the
/// bytes toward data usage.
class _EmoteFileService extends FileService {
  _EmoteFileService(this._inner);

  final FileService _inner;

  @override
  int get concurrentFetches => _inner.concurrentFetches;

  @override
  set concurrentFetches(int value) => _inner.concurrentFetches = value;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final response = await _inner.get(
      url,
      headers: {'User-Agent': 'ermchat', ...?headers},
    );
    return _CountedResponse(response);
  }
}

class _CountedResponse implements FileServiceResponse {
  _CountedResponse(this._inner);

  final FileServiceResponse _inner;

  @override
  Stream<List<int>> get content => _inner.content.map((chunk) {
    DataUsageStats.I.recordEmoteDownload(chunk.length);
    return chunk;
  });

  @override
  int? get contentLength => _inner.contentLength;

  @override
  int get statusCode => _inner.statusCode;

  @override
  DateTime get validTill => _inner.validTill;

  @override
  String? get eTag => _inner.eTag;

  @override
  String get fileExtension => _inner.fileExtension;
}

/// Dedicated disk cache for emote images. Every emote render (chat, emote
/// menu, sheet, autocomplete, analytics) shares this store: the custom loop
/// through `EmoteImages.bytes`, stock cells via [CachedNetworkImageProvider]
/// with this manager. Chat Giphy GIFs are the exception (memory-only).
///
/// Every download is written to disk. The cap is enforced by the package's
/// own cleanup through [EmoteCacheRepository], which trims to [maxBytes] by
/// usage priority in the background, so the cap is soft for up to one
/// cleanup interval. [enforceNow] (settings Apply / startup) trims at once.
class EmoteCacheManager extends CacheManager {
  factory EmoteCacheManager([Config? config]) =>
      EmoteCacheManager._build(config ?? _defaultConfig());

  @visibleForTesting
  factory EmoteCacheManager.forTesting(Config config) =>
      EmoteCacheManager._build(config);

  factory EmoteCacheManager._build(Config config) {
    final repo = EmoteCacheRepository(config.repo, EmoteCacheBudget());
    return EmoteCacheManager._(
      repo,
      Config(
        config.cacheKey,
        stalePeriod: config.stalePeriod,
        maxNrOfCacheObjects: config.maxNrOfCacheObjects,
        repo: repo,
        fileSystem: config.fileSystem,
        fileService: _EmoteFileService(config.fileService),
      ),
    );
  }

  EmoteCacheManager._(this._repo, super.config);

  static Config _defaultConfig() => Config(
    'emoteImageCacheV3',
    // The byte budget binds first; this stays non-binding for large libraries.
    maxNrOfCacheObjects: 20000,
    stalePeriod: const Duration(days: 30),
    fileService: HttpFileService(httpClient: emoteFetchClient),
  );

  final EmoteCacheRepository _repo;

  EmoteCacheBudget get _budget => _repo.budget;

  /// Byte budget for cached emote files.
  int get maxBytes => _budget.maxBytes;

  set maxBytes(int value) {
    _budget.maxBytes = value.clamp(0, maxEmoteCacheMb * bytesPerMb).toInt();
  }

  /// Keep-priority policy for trimming. Set by the image owner from its usage
  /// registry.
  EmoteImagePolicy? get policy => _budget.policy;

  set policy(EmoteImagePolicy? value) => _budget.policy = value;

  /// Trims to [maxBytes] now instead of on the next cleanup (settings Apply
  /// and startup, after the cap may have dropped).
  Future<void> enforceNow() async {
    try {
      final victims = _budget.overBudget(
        await _repo.getAllObjects(),
        DateTime.now(),
      );
      for (final object in victims) {
        try {
          await removeFile(object.key);
        } catch (_) {
          // A missing file or a racing removal is fine; it's already gone.
        }
      }
      if (victims.isNotEmpty) {
        logDebug('[EmoteCacheManager] trimmed ${victims.length} files');
      }
    } catch (_) {
      // Enumeration can fail (e.g. db closed); the next cleanup retries.
    }
  }

  /// Counts the cached emote files still present on disk and their total size.
  /// Returns an empty snapshot if the cache can't be inspected.
  Future<EmoteCacheStats> stats() async {
    try {
      final aggregate = await _repo.aggregate();
      if (aggregate != null) {
        var count = aggregate.count;
        var bytes = aggregate.bytes;
        // Only rows without a recorded length need a file stat.
        for (final object in aggregate.unknownLength) {
          final file = await config.fileSystem.createFile(object.relativePath);
          if (await file.exists()) {
            count++;
            bytes += await file.length();
          }
        }
        return EmoteCacheStats(fileCount: count, totalBytes: bytes);
      }
      final objects = await _repo.getAllObjects();
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
    } catch (_) {
      return const EmoteCacheStats(fileCount: 0, totalBytes: 0);
    }
  }
}
