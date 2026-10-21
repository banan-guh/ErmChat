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

  /// How far back the calendar reaches: the retention window, or the oldest
  /// kept day, which outlives it.
  Future<DateTime> _since() async {
    var from = _now().subtract(ArchiveStore.retention);
    for (final day in await reader.keptDays(channel)) {
      if (day.isBefore(from)) from = day;
    }
    return from;
  }

  @override
  Future<List<HistoryStream>> streams() async =>
      reader.streams(channel, await _since(), _now());

  @override
  Future<ActivityRail?> rail(List<HistoryStream> streams) async {
    final to = _now().toUtc();
    const bucket = ActivityRail.defaultBucket;
    final counts = await reader.minuteCounts(
      channel,
      (await _since()).toUtc(),
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

/// [HistorySource] over the archived rows passing [test] in [channels]
/// (every channel when null), so the history list pages through matches
/// like through chat. Streams and the rail are left out.
class ArchiveFindSource implements HistorySource {
  ArchiveFindSource(
    this.reader,
    this.terms,
    this.test, {
    this.channels,
    DateTime Function()? now,
  }) : _now = now ?? clock.now;

  /// [channel]'s matches of [query] in [scope] (see [ChatQuery]).
  factory ArchiveFindSource.search(
    String channel,
    ArchiveReader reader, {
    required String query,
    required ChatSearchScope scope,
    DateTime Function()? now,
  }) {
    final q = ChatQuery.parse(query, scope);
    return ArchiveFindSource(
      reader,
      ArchiveTerms.search(q),
      q.matches,
      channels: [channel],
      now: now,
    );
  }

  final ArchiveReader reader;
  final ArchiveTerms terms;
  final bool Function(TwitchMessage m) test;
  final List<String>? channels;
  final DateTime Function() _now;

  static const int _page = 100;

  @override
  DateTime now() => _now();

  Future<List<TwitchMessage>> _find({
    DateTime? before,
    DateTime? after,
  }) async => (await reader.find(
    terms,
    test,
    channels: channels,
    limit: _page,
    before: before,
    after: after,
  )).reversed.toList();

  @override
  Future<List<TwitchMessage>> older(DateTime time) =>
      _find(before: time.add(const Duration(milliseconds: 1)));

  @override
  Future<List<TwitchMessage>> newer(DateTime time) => _find(after: time);

  @override
  Future<List<TwitchMessage>> around(DateTime time) async {
    final before = await older(time);
    final after = await newer(time);
    final seen = {for (final m in before) m};
    return [...before, ...after.where((m) => !seen.contains(m))];
  }

  @override
  Future<List<TwitchMessage>> newest() => _find();

  @override
  Future<List<HistoryStream>> streams() async => const [];

  @override
  Future<ActivityRail?> rail(List<HistoryStream> streams) async => null;

  @override
  void Function() watchClears(void Function(HistoryClear clear) onClear) =>
      reader.clears.add((e) {
        if (channels?.contains(e.$1) ?? true) onClear(e.$2);
      });

  @override
  void Function() watchStreams(void Function() onChange) => () {};
}
