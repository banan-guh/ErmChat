import 'dart:isolate';
import 'dart:typed_data';

import '../archive/archive_block.dart';
import '../archive/archive_io.dart';
import '../archive/archive_row.dart';
import '../models/twitch_message.dart';
import '../util/log.dart';
import 'archive_adapter.dart';
import 'archive_store.dart';

/// One decoded block of the windowed list.
class ArchiveWindowBlock {
  const ArchiveWindowBlock({
    required this.key,
    required this.start,
    required this.end,
    required this.rows,
  });

  final int key;
  final DateTime start;
  final DateTime end;

  /// Oldest first.
  final List<TwitchMessage> rows;
}

/// Rows per minute for the scrubber and waveforms.
class MinuteCount {
  const MinuteCount(this.minute, this.count);

  /// Start of the minute, UTC.
  final DateTime minute;
  final int count;
}

/// Decodes packed blocks; a damaged block yields null instead of throwing.
Future<List<List<ArchiveRow>?>> decodeOffIsolate(List<Uint8List> blocks) =>
    Isolate.run(() => decodeBlocks(blocks));

List<List<ArchiveRow>?> decodeBlocks(List<Uint8List> blocks) => [
  for (final b in blocks)
    () {
      try {
        return ArchiveBlock.decode(b);
      } on ArchiveFormatException {
        return null;
      }
    }(),
];

/// Reads blocks from the archive, decodes them off the UI isolate, and
/// returns [TwitchMessage]s. A block that fails to decode is skipped.
class ArchiveReader {
  ArchiveReader(this._store, {this.decode = decodeOffIsolate});

  final Future<ArchiveStore?> _store;

  /// Unpacks blocks; off the UI isolate by default.
  final Future<List<List<ArchiveRow>?>> Function(List<Uint8List> blocks) decode;

  /// The newest [limit] rows of [channel], oldest first, for cold start.
  Future<List<TwitchMessage>> newestRows(String channel, int limit) async {
    final store = await _store;
    if (store == null || limit <= 0) {
      return const [];
    }
    final blocks = await store.newestBlocks(channel, limit);
    final decoded = await _decodeAll(channel, blocks, asHistory: true);
    final rows = [for (final b in decoded) ...b.rows];
    _sortStable(rows);
    return rows.length > limit ? rows.sublist(rows.length - limit) : rows;
  }

  /// Blocks around [time]: [before] older, the anchor, [after] newer.
  Future<List<ArchiveWindowBlock>> blocksAround(
    String channel,
    DateTime time, {
    required int before,
    required int after,
  }) async {
    final store = await _store;
    if (store == null) {
      return const [];
    }
    final blocks = await store.blocksAround(
      channel,
      time.millisecondsSinceEpoch,
      before,
      after,
    );
    return _decodeAll(channel, blocks);
  }

  Future<ArchiveWindowBlock?> blockAt(String channel, int blockKey) async {
    final store = await _store;
    final block = await store?.blockAt(channel, blockKey);
    if (block == null) {
      return null;
    }
    final decoded = await _decodeAll(channel, [block]);
    return decoded.isEmpty ? null : decoded.first;
  }

  /// Minute buckets with rows between [from] and [to], oldest first.
  Future<List<MinuteCount>> minuteCounts(
    String channel,
    DateTime from,
    DateTime to,
  ) async {
    final store = await _store;
    if (store == null) {
      return const [];
    }
    final counts = await store.minuteCounts(
      channel,
      from.millisecondsSinceEpoch ~/ 60000,
      to.millisecondsSinceEpoch ~/ 60000,
    );
    return [
      for (final c in counts)
        MinuteCount(
          DateTime.fromMillisecondsSinceEpoch(c.minute * 60000, isUtc: true),
          c.count,
        ),
    ];
  }

  Future<List<ArchiveWindowBlock>> _decodeAll(
    String channel,
    List<StoredBlock> blocks, {
    bool asHistory = false,
  }) async {
    if (blocks.isEmpty) {
      return const [];
    }
    final store = (await _store)!;
    final tables = await store.tables(channel);
    final adapter = ArchiveAdapter(tables);
    final decoded = await decode([for (final b in blocks) b.data]);
    final out = <ArchiveWindowBlock>[];
    for (var i = 0; i < blocks.length; i++) {
      final rows = decoded[i];
      final b = blocks[i];
      if (rows == null) {
        logDebug('[ArchiveReader] skipped damaged block ${b.key}');
        continue;
      }
      final messages = [
        for (final r in rows) adapter.fromRow(r, channel, asHistory: asHistory),
      ];
      _sortStable(messages);
      out.add(
        ArchiveWindowBlock(
          key: b.key,
          start: DateTime.fromMillisecondsSinceEpoch(b.startTs, isUtc: true),
          end: DateTime.fromMillisecondsSinceEpoch(b.endTs, isUtc: true),
          rows: messages,
        ),
      );
    }
    return out;
  }

  /// Sort by time, keeping arrival order for equal timestamps (List.sort is
  /// not stable).
  static void _sortStable(List<TwitchMessage> rows) {
    final order = {for (var i = 0; i < rows.length; i++) rows[i]: i};
    rows.sort((a, b) {
      final c = a.timestamp.compareTo(b.timestamp);
      return c != 0 ? c : order[a]!.compareTo(order[b]!);
    });
  }
}
