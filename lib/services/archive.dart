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

  Future<void> dispose() => writer.dispose();
}
