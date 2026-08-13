import 'package:flutter_cache_manager/flutter_cache_manager.dart';

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
/// [CachedNetworkImageProvider.defaultCacheManager]. The 2000-file manager cap
/// is a safety net; [EmoteManager]'s GC is the real enforcer.
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
