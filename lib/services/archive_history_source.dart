import 'package:clock/clock.dart';

import '../models/twitch_message.dart';
import '../util/history_timeline.dart';
import 'archive_reader.dart';
import 'archive_store.dart';

/// [HistorySource] over one channel of the archive. A read decodes about one
/// block (256 rows) per side of the requested time.
class ArchiveHistorySource implements HistorySource {
  ArchiveHistorySource(this.channel, this.reader, {DateTime Function()? now})
    : _now = now ?? clock.now;

  final String channel;
  final ArchiveReader reader;
  final DateTime Function() _now;

  @override
  DateTime now() => _now();

  @override
  Future<List<TwitchMessage>> older(DateTime time) =>
      reader.rowsNear(channel, time, before: 1, after: 0);

  @override
  Future<List<TwitchMessage>> newer(DateTime time) =>
      reader.rowsNear(channel, time, before: 0, after: 1);

  @override
  Future<List<TwitchMessage>> around(DateTime time) =>
      reader.rowsNear(channel, time, before: 1, after: 1);

  /// Reads from a day ahead: row times come from Twitch's clock, which can
  /// run ahead of the phone's.
  @override
  Future<List<TwitchMessage>> newest() => reader.rowsNear(
    channel,
    _now().add(const Duration(days: 1)),
    before: 2,
    after: 0,
  );

  @override
  void Function() watchClears(void Function(HistoryClear clear) onClear) =>
      reader.clears.add((e) {
        if (e.$1 == channel) onClear(e.$2);
      });

  @override
  Future<List<HistoryStream>> streams() =>
      reader.streams(channel, _now().subtract(ArchiveStore.retention), _now());

  @override
  Future<ActivityRail?> rail(List<HistoryStream> streams) async {
    final to = _now().toUtc();
    final counts = await reader.minuteCounts(
      channel,
      to.subtract(ArchiveStore.retention),
      to,
    );
    if (counts.isEmpty) return null;
    final from = counts.first.minute;
    const bucket = ActivityRail.defaultBucket;
    final buckets = List<int>.filled(
      (to.difference(from).inMilliseconds / bucket.inMilliseconds).ceil() + 1,
      0,
    );
    for (final c in counts) {
      buckets[c.minute.difference(from).inMilliseconds ~/
              bucket.inMilliseconds] +=
          c.count;
    }
    return ActivityRail(
      from: from,
      to: to,
      bucket: bucket,
      counts: buckets,
      streams: streams,
    );
  }
}
