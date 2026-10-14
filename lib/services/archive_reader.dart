import 'dart:isolate';
import 'dart:typed_data';

import '../archive/archive_block.dart';
import '../archive/archive_io.dart';
import '../archive/archive_row.dart';
import '../models/twitch_message.dart';
import '../util/history_timeline.dart';
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

  /// Rows of every block at [time] plus [before] blocks older and [after]
  /// newer, oldest first, cut to the range those blocks cover completely
  /// (see [ArchiveStore.blocksNear]).
  Future<List<TwitchMessage>> rowsNear(
    String channel,
    DateTime time, {
    required int before,
    required int after,
  }) async {
    final store = await _store;
    if (store == null) {
      return const [];
    }
    final near = await store.blocksNear(
      channel,
      time.millisecondsSinceEpoch,
      before,
      after,
    );
    final floor = near.floorTs;
    final ceil = near.ceilTs;
    final rows = [
      for (final b in await _decodeAll(channel, near.blocks))
        for (final m in b.rows)
          if ((floor == null || m.timestamp.millisecondsSinceEpoch > floor) &&
              (ceil == null || m.timestamp.millisecondsSinceEpoch < ceil))
            m,
    ];
    _sortStable(rows);
    return rows;
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

  /// Broadcasts still live or ended at or after [from], oldest first. A live
  /// one ends at [now].
  Future<List<HistoryStream>> streams(
    String channel,
    DateTime from,
    DateTime now,
  ) async {
    final store = await _store;
    if (store == null) {
      return const [];
    }
    final rows = await store.streams(channel, from.millisecondsSinceEpoch);
    DateTime at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    return [
      for (final r in rows)
        HistoryStream(
          id: r.id,
          start: at(r.startedTs),
          end: r.endedTs == null ? now : at(r.endedTs!),
          title: r.title ?? '',
          game: r.game ?? '',
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
    var lo = blocks.first.startTs;
    var hi = blocks.first.endTs;
    for (final b in blocks) {
      if (b.startTs < lo) lo = b.startTs;
      if (b.endTs > hi) hi = b.endTs;
    }
    final cleared = await store.moderation(channel, lo, hi);
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
      for (final c in cleared) {
        for (final m in messages) {
          final ts = m.timestamp.millisecondsSinceEpoch;
          if (!m.isSystem &&
              ts >= c.fromTs &&
              ts <= c.toTs &&
              (c.login == null || c.login == m.login)) {
            m.deleted = true;
          }
        }
      }
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
