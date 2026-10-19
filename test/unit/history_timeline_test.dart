import 'package:ermchat/util/history_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wall clock at a fixed UTC offset.
LocalTime fixedOffset(int hours) =>
    (t) => t.toUtc().add(Duration(hours: hours));

/// New York in 2026: EST (-5) until the March 8 02:00 jump, EDT (-4) after.
DateTime newYork(DateTime t) {
  final utc = t.toUtc();
  final springForward = DateTime.utc(2026, 3, 8, 7);
  return utc.add(Duration(hours: utc.isBefore(springForward) ? -5 : -4));
}

List<String> keys(List<HistoryMarker> m) => [for (final x in m) x.key];

void main() {
  final now = DateTime.utc(2026, 10, 13, 12);

  group('day markers', () {
    test('attach to the first message of a new local day, not midnight', () {
      final local = fixedOffset(-5);
      // 23:30 Sep 30 and 00:30 Oct 1 local.
      final a = DateTime.utc(2026, 10, 1, 4, 30);
      final b = DateTime.utc(2026, 10, 1, 5, 30);
      expect(keys(markersBefore(prev: a, time: b, now: now, local: local)), [
        'day-${dayNumber(DateTime.utc(2026, 10, 1))}',
      ], reason: 'a new local day needs a marker on its first message');
      final c = DateTime.utc(2026, 10, 1, 6);
      expect(
        markersBefore(prev: b, time: c, now: now, local: local),
        isEmpty,
        reason: 'same local day, no marker',
      );
    });

    test('none within 24 hours of now', () {
      final prev = now.subtract(const Duration(hours: 30));
      final time = now.subtract(const Duration(hours: 23));
      expect(markersBefore(prev: prev, time: time, now: now), isEmpty);
    });

    test('DST: a 23 hour day is one day, no marker mid-day', () {
      // 01:30 EST and 03:30 EDT on Mar 8 are the same local day.
      final a = DateTime.utc(2026, 3, 8, 6, 30);
      final b = DateTime.utc(2026, 3, 8, 7, 30);
      expect(
        markersBefore(prev: a, time: b, now: now, local: newYork),
        isEmpty,
      );
      // 23:59 EDT Mar 8, then 00:01 EDT Mar 9.
      final c = DateTime.utc(2026, 3, 9, 3, 59);
      final d = DateTime.utc(2026, 3, 9, 4, 1);
      expect(keys(markersBefore(prev: c, time: d, now: now, local: newYork)), [
        'day-${dayNumber(DateTime.utc(2026, 3, 9))}',
      ]);
    });

    test('DST: messages 24h apart across spring forward skip a whole day', () {
      // 23:30 EST Mar 7, then 00:30 EDT Mar 9: exactly 24h apart in time but
      // Mar 8 is a calendar day in between.
      final a = DateTime.utc(2026, 3, 8, 4, 30);
      final b = DateTime.utc(2026, 3, 9, 4, 30);
      final m = markersBefore(prev: a, time: b, now: now, local: newYork);
      final mar8 = dayNumber(DateTime.utc(2026, 3, 8));
      expect(keys(m), ['empty-$mar8-$mar8', 'day-${mar8 + 1}']);
    });

    test('a stream starting the new day sits below its day marker', () {
      // 22:11 Oct 13, a stream at 08:05 Oct 14, the first message at 12:16;
      // the day marker went below the stream and carried 12:16.
      final local = fixedOffset(0);
      final prev = DateTime.utc(2026, 10, 13, 22, 11);
      final ended = HistoryStream(
        id: 'a',
        start: DateTime.utc(2026, 10, 13, 20),
        end: DateTime.utc(2026, 10, 13, 23),
        title: 't',
        game: 'g',
      );
      final started = HistoryStream(
        id: 'b',
        start: DateTime.utc(2026, 10, 14, 8, 5),
        end: DateTime.utc(2026, 10, 14, 18),
        title: 't',
        game: 'g',
      );
      final m = markersBefore(
        prev: prev,
        time: DateTime.utc(2026, 10, 14, 12, 16),
        now: DateTime.utc(2026, 10, 15, 18),
        streams: [started, ended],
        local: local,
      );
      expect(keys(m), [
        'se-a',
        'day-${dayNumber(DateTime.utc(2026, 10, 14))}',
        'ss-b',
      ]);
      expect(m[1].time, started.start, reason: 'stamped with its first event');
    });

    test('device timezone default needs no injection', () {
      final prev = DateTime(2026, 9, 1, 23, 50);
      final time = DateTime(2026, 9, 2, 0, 10);
      expect(markersBefore(prev: prev, time: time, now: now), hasLength(1));
    });
  });

  group('empty stretches', () {
    test('consecutive empty days collapse into one row before the day', () {
      final local = fixedOffset(0);
      final a = DateTime.utc(2026, 9, 2, 20);
      final b = DateTime.utc(2026, 9, 8, 1);
      final m = markersBefore(prev: a, time: b, now: now, local: local);
      final sep2 = dayNumber(DateTime.utc(2026, 9, 2));
      expect(keys(m), ['empty-${sep2 + 1}-${sep2 + 5}', 'day-${sep2 + 6}']);
      expect(m.first.kind, HistoryMarkerKind.emptyStretch);
    });

    test('adjacent days leave no empty row', () {
      final a = DateTime.utc(2026, 9, 2, 20);
      final b = DateTime.utc(2026, 9, 3, 1);
      final m = markersBefore(
        prev: a,
        time: b,
        now: now,
        local: fixedOffset(0),
      );
      expect(m.single.kind, HistoryMarkerKind.day);
    });
  });

  group('stream rows', () {
    final stream = HistoryStream(
      id: 's1',
      start: DateTime.utc(2026, 10, 5, 10),
      end: DateTime.utc(2026, 10, 5, 13, 12),
      title: 't',
      game: 'g',
    );

    test('start and end each land in exactly one gap', () {
      final times = [
        for (var h = 8; h <= 16; h++) DateTime.utc(2026, 10, 5, h, 30),
      ];
      List<String> found(HistoryStream s) => [
        for (var i = 0; i < times.length; i++)
          ...keys(
            markersBefore(
              prev: i == 0 ? null : times[i - 1],
              time: times[i],
              now: now,
              streams: [s],
              local: fixedOffset(0),
            ).where((x) => x.stream != null).toList(),
          ),
      ];
      expect(found(stream), ['ss-s1', 'se-s1'], reason: 'one row per stream');
      final live = HistoryStream(
        id: 's1',
        start: stream.start,
        end: stream.end,
        title: 't',
        game: 'g',
        live: true,
      );
      expect(found(live), [
        'ss-s1',
      ], reason: 'a live stream ended mid-chat at the time it was read');
    });

    test('length formats as hours and minutes', () {
      expect(formatStreamLength(stream.end.difference(stream.start)), '3h12m');
      expect(formatStreamLength(const Duration(minutes: 45)), '45m');
    });
  });

  group('activity rail', () {
    const day = Duration(days: 1);
    final from = DateTime.utc(2026, 9, 13);
    const bucket = Duration(minutes: 5);
    // 4 days: day 1 busy, days 2-3 empty, day 4 quiet.
    final counts = [
      for (var i = 0; i < 4 * 288; i++)
        i < 288
            ? 20
            : i < 3 * 288
            ? 0
            : 2,
    ];
    final to = from.add(bucket * counts.length);
    final stream = HistoryStream(
      id: 's',
      start: from.add(const Duration(hours: 2)),
      end: from.add(const Duration(hours: 6)),
      title: 't',
      game: 'g',
    );
    final rail = ActivityRail(
      from: from,
      to: to,
      bucket: bucket,
      counts: counts,
      streams: [stream],
      local: fixedOffset(0),
    );

    test('days split at local midnight with their counts', () {
      expect([for (final d in rail.days) d.count], [5760, 0, 0, 576]);
      expect(rail.days[1].start, from.add(day));
      expect(rail.days.first.start, from);
      expect(rail.countBetween(from, to), 6336);
    });

    test('a weighted window shrinks empty days to a sliver', () {
      final w = rail.window(from, to);
      final empty =
          w.positionOf(from.add(day * 3)) - w.positionOf(from.add(day));
      expect(empty, lessThan(0.05), reason: 'two empty days');
      final quiet = w.positionOf(to) - w.positionOf(from.add(day * 3));
      expect(quiet, greaterThan(empty * 5), reason: 'a quiet day still counts');
      for (final min in [0, 7, 1000, 4400, 5759]) {
        final t = from.add(Duration(minutes: min));
        expect(
          w.timeAt(w.positionOf(t)).difference(t).inSeconds.abs(),
          lessThanOrEqualTo(1),
          reason: 'round trip drifted at minute $min',
        );
      }
    });
  });
}
