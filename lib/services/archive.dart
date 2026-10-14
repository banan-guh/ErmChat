import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../util/log.dart';
import 'archive_reader.dart';
import 'archive_store.dart';
import 'archive_writer.dart';

/// The history archive: one SQLite store with its writer and reader. The
/// store opens lazily on first use; if it cannot open (for example after a
/// downgrade) the archive logs once and acts empty, and chat is unaffected.
class Archive {
  Archive(this.store)
    : writer = ArchiveWriter(store),
      reader = ArchiveReader(store);

  /// The shared store; null once resolved when it could not open. Saved
  /// threads persist through it.
  final Future<ArchiveStore?> store;

  /// Opens `archive.db` in the app support directory.
  factory Archive.inAppSupport() => Archive(_openDefault());

  final ArchiveWriter writer;
  final ArchiveReader reader;

  static Future<ArchiveStore?> _openDefault() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return await ArchiveStore.open(
        '${dir.path}${Platform.pathSeparator}archive.db',
      );
    } catch (e) {
      logDebug('[Archive] open failed: $e');
      return null;
    }
  }

  /// Records a broadcast seen live. Never throws.
  Future<void> recordStream({
    required String channel,
    required String id,
    required DateTime startedAt,
    String? title,
    String? game,
  }) => _quiet(
    (s) => s.putStream(
      channel: channel,
      id: id,
      startedTs: startedAt.millisecondsSinceEpoch,
      title: title,
      game: game,
    ),
  );

  /// Records the end of broadcast [id]. Never throws.
  Future<void> endStream(String id, DateTime endedAt) =>
      _quiet((s) => s.endStream(id, endedAt.millisecondsSinceEpoch));

  Future<void> _quiet(Future<void> Function(ArchiveStore s) write) async {
    try {
      final s = await store;
      if (s != null) await write(s);
    } catch (e) {
      logDebug('[Archive] stream write failed: $e');
    }
  }

  Future<void> dispose() => writer.dispose();
}
