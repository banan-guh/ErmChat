import 'dart:math' as math;
import 'dart:typed_data';

import '../models/twitch_message.dart';

/// Wall-clock time for an instant. The default is the device timezone; tests
/// pass a fixed or DST-switching offset. Only the date and time fields of the
/// result are read.
typedef LocalTime = DateTime Function(DateTime instant);

DateTime _deviceLocal(DateTime instant) => instant.toLocal();

/// One broadcast. [id] is the Helix stream id and dedups its system rows.
class HistoryStream {
  const HistoryStream({
    required this.id,
    required this.start,
    required this.end,
    required this.title,
    required this.game,
    this.live = false,
  });

  final String id;
  final DateTime start;

  /// When [live], the time the stream was read, not an end.
  final DateTime end;
  final bool live;
  final String title;
  final String game;
}

/// Message counts over time for a channel. The archive implements this with
/// its `minute_counts` table; the prototype derives it from generated rows.
abstract interface class ActivityIndex {
  /// Messages per [bucket] over [from] to [to] (the last bucket may be
  /// partial). A zero is a bucket with nothing recorded.
  List<int> counts(String channel, DateTime from, DateTime to, Duration bucket);
}

/// Where the windowed history list reads rows: the archive, or generated rows
/// for the prototype channels. Reads return rows oldest first and may repeat
/// rows the list already holds; the list drops those by key.
abstract interface class HistorySource {
  /// The source's clock; day markers and the rail end read it.
  DateTime now();

  /// About a block of rows at or before [time]. Empty past the oldest.
  Future<List<TwitchMessage>> older(DateTime time);

  /// About a block of rows at or after [time]. Empty past the newest.
  Future<List<TwitchMessage>> newer(DateTime time);

  /// Rows on both sides of [time].
  Future<List<TwitchMessage>> around(DateTime time);

  /// The newest rows.
  Future<List<TwitchMessage>> newest();

  /// Broadcasts over the retained range, oldest first.
  Future<List<HistoryStream>> streams();

  /// The rail over the retained range, or null when nothing is retained.
  Future<ActivityRail?> rail(List<HistoryStream> streams);

  /// Calls [onClear] for each delete that lands after rows were read: rows
  /// by `login` (everyone when null) from `from` to `to`. Returns the
  /// unsubscribe.
  void Function() watchClears(void Function(HistoryClear clear) onClear);

  /// Calls [onChange] when [streams] may read differently. Returns the
  /// unsubscribe.
  void Function() watchStreams(void Function() onChange);
}

typedef HistoryClear = ({String? login, DateTime from, DateTime to});

/// Calendar day number (days since 1970-01-01) of a wall-clock time. Plain
/// date arithmetic, so a 23 or 25 hour day counts as one day.
int dayNumber(DateTime wall) =>
    DateTime.utc(wall.year, wall.month, wall.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

/// The date fields of [day] as a UTC [DateTime], for date formatting.
DateTime dayFromNumber(int day) => DateTime.utc(1970, 1, 1 + day);

/// "3h12m", or "45m" under an hour.
String formatStreamLength(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  return h == 0 ? '${m}m' : '${h}h${m.toString().padLeft(2, '0')}m';
}

enum HistoryMarkerKind { streamStart, streamEnd, emptyStretch, day }

/// A derived system row shown before a message. Never stored: it is computed
/// from message times and streams, so reloading a block gives the same keys.
class HistoryMarker {
  const HistoryMarker({
    required this.kind,
    required this.key,
    required this.time,
    this.stream,
    this.firstDay = 0,
    this.lastDay = 0,
  });

  final HistoryMarkerKind kind;

  /// Stable identity: the stream id for stream rows, the day numbers for days.
  final String key;

  /// When the event happened (stream start/end, first message of the day).
  final DateTime time;
  final HistoryStream? stream;

  /// Day numbers covered; equal for a single day or one empty day.
  final int firstDay;
  final int lastDay;
}

const Duration _dayMarkerAge = Duration(hours: 24);

bool _between(DateTime? prev, DateTime e, DateTime time) =>
    (prev == null || e.isAfter(prev)) && !e.isAfter(time);

/// Markers that sit between the message at [prev] and the one at [time], in
/// display order (oldest first). [prev] is null for the first archived row.
///
/// - Stream start and end appear before the first message at or after them.
/// - A day marker appears only for messages older than 24 hours, before the
///   first message of a new local calendar day, so empty days produce none.
/// - Whole days with no messages between [prev] and [time] collapse into one
///   empty-stretch marker placed before the day marker.
List<HistoryMarker> markersBefore({
  required DateTime? prev,
  required DateTime time,
  required DateTime now,
  List<HistoryStream> streams = const [],
  LocalTime local = _deviceLocal,
  bool emptyStretches = true,
}) {
  final out = <HistoryMarker>[];
  final events = <HistoryMarker>[];
  for (final s in streams) {
    if (_between(prev, s.start, time)) {
      events.add(
        HistoryMarker(
          kind: HistoryMarkerKind.streamStart,
          key: 'ss-${s.id}',
          time: s.start,
          stream: s,
        ),
      );
    }
    if (!s.live && _between(prev, s.end, time)) {
      events.add(
        HistoryMarker(
          kind: HistoryMarkerKind.streamEnd,
          key: 'se-${s.id}',
          time: s.end,
          stream: s,
        ),
      );
    }
  }
  events.sort((a, b) => a.time.compareTo(b.time));
  HistoryMarker? day;
  if (time.isBefore(now.subtract(_dayMarkerAge))) {
    final d = dayNumber(local(time));
    final p = prev == null ? null : dayNumber(local(prev));
    if (p == null || d != p) {
      if (emptyStretches && p != null && d - p > 1) {
        out.add(
          HistoryMarker(
            kind: HistoryMarkerKind.emptyStretch,
            key: 'empty-${p + 1}-${d - 1}',
            time: prev!,
            firstDay: p + 1,
            lastDay: d - 1,
          ),
        );
      }
      day = HistoryMarker(
        kind: HistoryMarkerKind.day,
        key: 'day-$d',
        time: time,
        firstDay: d,
        lastDay: d,
      );
    }
  }
  out.addAll(events);
  if (day != null) out.add(day);
  return out;
}

/// A run of the rail, as positions from 0 (oldest) to 1 (newest).
class RailSpan {
  const RailSpan(this.start, this.end);

  final double start;
  final double end;
}

/// Maps time over the retained range to a 0..1 rail position, weighted by
/// activity: empty buckets shrink to a sliver, busy buckets and stream buckets
/// get length. With `byCount`, each message gets equal length and empty
/// time none, like a plain scrollbar over a results list. Built once per
/// list; lookups are O(1) or O(log n) and allocate nothing.
class ActivityRail {
  ActivityRail({
    required this.from,
    required this.to,
    required this.bucket,
    required List<int> counts,
    this.streams = const [],
    this.local = _deviceLocal,
    bool byCount = false,
  }) : _bucketMs = bucket.inMilliseconds,
       _n = counts.length {
    final cum = Float64List(_n + 1);
    final inStream = Uint8List(_n);
    for (final s in streams) {
      final a = _indexOf(s.start).clamp(0, _n);
      final b = _indexOf(s.end).clamp(0, _n);
      for (var i = a; i < b; i++) {
        inStream[i] = 1;
      }
    }
    var sum = 0.0;
    for (var i = 0; i < _n; i++) {
      final c = counts[i];
      sum += byCount
          ? c
          : c == 0
          ? gapWeight
          : (1 + math.log(c)) * (inStream[i] == 1 ? 3 : 1);
      cum[i] = sum;
    }
    // cum[i] holds the end of bucket i; shift so cum[i] is its start.
    final total = sum == 0 ? 1 : sum;
    for (var i = _n; i > 0; i--) {
      cum[i] = cum[i - 1] / total;
    }
    cum[0] = 0;
    cum[_n] = 1;
    _cum = cum;
    final gapSpans = <RailSpan>[];
    var runStart = -1;
    for (var i = 0; i <= _n; i++) {
      final empty = i < _n && counts[i] == 0;
      if (empty && runStart < 0) runStart = i;
      if (!empty && runStart >= 0) {
        if (i - runStart >= minGapBuckets) {
          gapSpans.add(RailSpan(cum[runStart], cum[i]));
        }
        runStart = -1;
      }
    }
    gaps = gapSpans;
    streamSpans = [
      for (final s in streams) RailSpan(positionOf(s.start), positionOf(s.end)),
    ];
  }

  /// Bucket width sources build rails with.
  static const Duration defaultBucket = Duration(minutes: 5);

  /// Rail weight of a bucket with no messages, against 1 for a single message.
  static const double gapWeight = 0.05;

  /// Empty runs at least this many buckets long render as hollow gaps.
  static const int minGapBuckets = 12;

  final DateTime from;
  final DateTime to;
  final Duration bucket;
  final List<HistoryStream> streams;
  final LocalTime local;
  final int _bucketMs;
  final int _n;
  late final Float64List _cum;

  /// Hollow rail sections: long stretches with nothing recorded.
  late final List<RailSpan> gaps;

  /// Where each stream sits on the rail, in [streams] order.
  late final List<RailSpan> streamSpans;

  int _indexOf(DateTime t) =>
      (t.difference(from).inMilliseconds / _bucketMs).floor();

  /// Rail position of [t], clamped to 0..1.
  double positionOf(DateTime t) {
    final ms = t.difference(from).inMilliseconds;
    if (ms <= 0) return 0;
    final i = ms ~/ _bucketMs;
    if (i >= _n) return 1;
    final frac = (ms - i * _bucketMs) / _bucketMs;
    return _cum[i] + (_cum[i + 1] - _cum[i]) * frac;
  }

  /// Time at rail position [p], clamped to the retained range.
  DateTime timeAt(double p) {
    if (p <= 0) return from;
    if (p >= 1) return to;
    var lo = 0;
    var hi = _n;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_cum[mid] <= p) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = _cum[lo + 1] - _cum[lo];
    final frac = span <= 0 ? 0.0 : (p - _cum[lo]) / span;
    return from.add(Duration(milliseconds: ((lo + frac) * _bucketMs).round()));
  }

  /// Where each local day after the first starts on the rail, to the bucket,
  /// with its day number (see [dayNumber]).
  late final List<({double pos, int day})> days = () {
    final out = <({double pos, int day})>[];
    var prev = dayNumber(local(from));
    for (var i = 1; i < _n; i++) {
      final at = from.add(Duration(milliseconds: i * _bucketMs));
      final day = dayNumber(local(at));
      if (day != prev) out.add((pos: _cum[i], day: day));
      prev = day;
    }
    return out;
  }();

  /// The stream running at [t], or null.
  HistoryStream? streamAt(DateTime t) {
    for (final s in streams) {
      if (!t.isBefore(s.start) && t.isBefore(s.end)) return s;
    }
    return null;
  }

  /// Boundary crossed moving the thumb from [a] to [b]: 0 none, 1 a day
  /// boundary, 2 a stream start (which wins over a day).
  int crossed(double a, double b) {
    final lo = math.min(a, b);
    final hi = math.max(a, b);
    for (final s in streamSpans) {
      if (s.start > lo && s.start <= hi) return 2;
    }
    final dayA = dayNumber(local(timeAt(a)));
    final dayB = dayNumber(local(timeAt(b)));
    return dayA == dayB ? 0 : 1;
  }
}
