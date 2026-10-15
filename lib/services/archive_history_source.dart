import 'package:clock/clock.dart';

import '../models/twitch_message.dart';
import '../util/chat_search.dart';
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
  void Function() watchStreams(void Function() onChange) =>
      reader.streamsChanged.add(onChange);

  @override
  Future<List<HistoryStream>> streams() =>
      reader.streams(channel, _now().subtract(ArchiveStore.retention), _now());

  @override
  Future<ActivityRail?> rail(List<HistoryStream> streams) async {
    final to = _now().toUtc();
    const bucket = ActivityRail.defaultBucket;
    final counts = await reader.minuteCounts(
      channel,
      to.subtract(ArchiveStore.retention),
      to,
      per: bucket,
    );
    if (counts.isEmpty) return null;
    final from = counts.first.minute;
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

/// [HistorySource] over the matches of one search in one channel's archive,
/// so the history list pages through results like through chat. No streams
/// or rail: results are not a timeline of the channel.
class ArchiveSearchSource implements HistorySource {
  ArchiveSearchSource(
    this.channel,
    this.reader, {
    required this.query,
    required this.scope,
    DateTime Function()? now,
  }) : _now = now ?? clock.now;

  final String channel;
  final ArchiveReader reader;
  final String query;
  final ChatSearchScope scope;
  final DateTime Function() _now;

  static const int _page = 100;

  @override
  DateTime now() => _now();

  @override
  Future<List<TwitchMessage>> older(DateTime time) async =>
      (await reader.search(
        channel,
        query,
        scope: scope,
        limit: _page,
        before: time.add(const Duration(milliseconds: 1)),
      )).reversed.toList();

  @override
  Future<List<TwitchMessage>> newer(DateTime time) async =>
      (await reader.search(
        channel,
        query,
        scope: scope,
        limit: _page,
        after: time,
      )).reversed.toList();

  @override
  Future<List<TwitchMessage>> around(DateTime time) async {
    final before = await older(time);
    final after = await newer(time);
    final seen = {for (final m in before) m};
    return [...before, ...after.where((m) => !seen.contains(m))];
  }

  @override
  Future<List<TwitchMessage>> newest() async => (await reader.search(
    channel,
    query,
    scope: scope,
    limit: _page,
  )).reversed.toList();

  @override
  Future<List<HistoryStream>> streams() async => const [];

  @override
  Future<ActivityRail?> rail(List<HistoryStream> streams) async => null;

  @override
  void Function() watchClears(void Function(HistoryClear clear) onClear) =>
      reader.clears.add((e) {
        if (e.$1 == channel) onClear(e.$2);
      });

  @override
  void Function() watchStreams(void Function() onChange) => () {};
}
