import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../archive/archive_row.dart';
import '../util/log.dart';
import 'archive_reader.dart';
import 'archive_store.dart';
import 'archive_writer.dart';

/// The history archive: one SQLite store with its writer and reader. The
/// store opens lazily on first use; if it cannot open (for example after a
/// downgrade) the archive logs once and acts empty, and chat is unaffected.
class Archive {
  Archive(this.store) : writer = ArchiveWriter(store) {
    reader = ArchiveReader(store, unsealed: writer.unsealed);
  }

  /// The shared store; null once resolved when it could not open. Saved
  /// threads persist through it.
  final Future<ArchiveStore?> store;

  /// Opens `archive.db` in the app support directory.
  factory Archive.inAppSupport() => Archive(_openDefault());

  final ArchiveWriter writer;
  late final ArchiveReader reader;

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
  }) => _quiet((s) async {
    final changed = await s.putStream(
      channel: channel,
      id: id,
      startedTs: startedAt.millisecondsSinceEpoch,
      title: title,
      game: game,
    );
    if (changed) reader.streamsChanged.emit();
  });

  /// Records the end of broadcast [id]. Never throws.
  Future<void> endStream(String id, DateTime endedAt) => _quiet((s) async {
    await s.endStream(id, endedAt.millisecondsSinceEpoch);
    reader.streamsChanged.emit();
  });

  /// Keeps the day [start] to [end] of [channel] past retention, or releases
  /// it. Never throws.
  Future<void> setDayKept(
    String channel,
    DateTime start,
    DateTime end, {
    required bool keep,
  }) => _quiet((s) {
    final from = start.millisecondsSinceEpoch;
    final to = end.millisecondsSinceEpoch;
    const kind = ArchiveReader.dayPin;
    return keep
        ? s.addPin(channel, from, to, kind)
        : s.removePin(channel, from, to, kind);
  });

  /// Remembers the video on demand of broadcast [streamId]. Never throws.
  Future<void> setVod(String streamId, String vodId) =>
      _quiet((s) => s.setVod(streamId, vodId));

  /// Records rows by [login] (everyone when null) from [from] to [to] as
  /// deleted, for rows already sealed. Never throws.
  Future<void> recordModeration(
    String channel,
    String? login,
    DateTime from,
    DateTime to,
  ) {
    reader.clears.emit((channel, (login: login, from: from, to: to)));
    return _quiet(
      (s) => s.addModeration(
        channel,
        login,
        from.millisecondsSinceEpoch,
        to.millisecondsSinceEpoch,
      ),
    );
  }

  /// Records an edit of every id in [messageIds] in one store transaction: drop
  /// them or mark them deleted. A row still in the writer's tail changes there.
  /// Never throws.
  Future<void> recordEdits(
    String channel,
    Iterable<String> messageIds,
    ArchiveEdit edit,
  ) async {
    try {
      await writer.recordEdits(channel, messageIds, edit);
    } catch (e) {
      logDebug('[Archive] edits failed: $e');
    }
  }

  Future<void> _quiet(Future<void> Function(ArchiveStore s) write) async {
    try {
      final s = await store;
      if (s != null) await write(s);
    } catch (e) {
      logDebug('[Archive] write failed: $e');
    }
  }

  Future<void> dispose() => writer.dispose();
}
