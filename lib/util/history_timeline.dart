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
    this.vodId,
  });

  final String id;
  final DateTime start;

  /// When [live], the time the stream was read, not an end.
  final DateTime end;
  final bool live;
  final String title;
  final String game;

  /// The video on demand, once looked up.
  final String? vodId;
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

/// The device-local calendar [day] as UTC instants: its midnight and its last
/// millisecond.
({DateTime start, DateTime end}) dayBounds(int day) {
  final d = dayFromNumber(day);
  return (
    start: DateTime(d.year, d.month, d.day).toUtc(),
    end: DateTime(
      d.year,
      d.month,
      d.day + 1,
    ).toUtc().subtract(const Duration(milliseconds: 1)),
  );
}

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

  /// When the event happened (stream start/end, the day's first event or
  /// message).
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
  if (!time.isBefore(now.subtract(_dayMarkerAge))) return events;
  final d = dayNumber(local(time));
  final p = prev == null ? null : dayNumber(local(prev));
  if (p != null && d == p) return events;
  // Events keep their place in time around the day: the previous day's
  // first, then the empty stretch, then the day, stamped with its first
  // event or message, then its own events.
  int dayOf(HistoryMarker e) => dayNumber(local(e.time));
  final today = [
    for (final e in events)
      if (dayOf(e) >= d) e,
  ];
  if (p != null) {
    out.addAll([
      for (final e in events)
        if (dayOf(e) <= p) e,
    ]);
  }
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
  out.addAll([
    for (final e in events)
      if (dayOf(e) < d && (p == null || dayOf(e) > p)) e,
  ]);
  out.add(
    HistoryMarker(
      kind: HistoryMarkerKind.day,
      key: 'day-$d',
      time: today.isEmpty ? time : today.first.time,
      firstDay: d,
      lastDay: d,
    ),
  );
  out.addAll(today);
  return out;
}

/// A run of the rail, as positions from 0 (oldest) to 1 (newest).
class RailSpan {
  const RailSpan(this.start, this.end);

  final double start;
  final double end;
}

/// Maps a time range onto a 0..1 rail position, oldest at 0.
abstract interface class RailScale {
  DateTime get from;
  DateTime get to;

  /// Rail position of [t], clamped to 0..1.
  double positionOf(DateTime t);

  /// Time at rail position [p], clamped to the range.
  DateTime timeAt(double p);
}

/// Plain time from [from] to [to]: equal time, equal length.
class TimeWindow implements RailScale {
  TimeWindow(this.from, this.to)
    : _ms = math.max(1, to.difference(from).inMilliseconds);

  /// [length] of time around [t] (or all of [from]..[to] when shorter),
  /// kept inside [from]..[to].
  factory TimeWindow.around(
    DateTime t,
    Duration length,
    DateTime from,
    DateTime to,
  ) {
    if (to.difference(from) <= length) return TimeWindow(from, to);
    var start = t.subtract(length ~/ 2);
    if (start.isBefore(from)) start = from;
    if (start.add(length).isAfter(to)) start = to.subtract(length);
    return TimeWindow(start, start.add(length));
  }

  @override
  final DateTime from;
  @override
  final DateTime to;
  final int _ms;

  bool contains(DateTime t) => !t.isBefore(from) && !t.isAfter(to);

  @override
  double positionOf(DateTime t) =>
      (t.difference(from).inMilliseconds / _ms).clamp(0.0, 1.0);

  @override
  DateTime timeAt(double p) =>
      from.add(Duration(milliseconds: (p.clamp(0.0, 1.0) * _ms).round()));
}

/// A stretch of an [ActivityRail] weighted by activity; see
/// [ActivityRail.window].
class _ActivityWindow implements RailScale {
  _ActivityWindow(this.rail, this.from, this.to)
    : _a = rail._weightAt(from),
      _b = rail._weightAt(to);

  final ActivityRail rail;
  @override
  final DateTime from;
  @override
  final DateTime to;
  final double _a;
  final double _b;

  @override
  double positionOf(DateTime t) =>
      _b <= _a ? 0 : ((rail._weightAt(t) - _a) / (_b - _a)).clamp(0.0, 1.0);

  @override
  DateTime timeAt(double p) {
    final t = rail._timeAtWeight(_a + p.clamp(0.0, 1.0) * (_b - _a));
    return t.isBefore(from) ? from : (t.isAfter(to) ? to : t);
  }
}

/// One local day of a rail: when it starts (to the bucket; the first day
/// starts at the rail's start) and how many messages it holds.
typedef RailDay = ({DateTime start, int day, int count});

/// Message counts per bucket over the retained range, with the streams in
/// it. As a [RailScale] it gives each message equal length and empty time
/// none, like a plain scrollbar over a results list; a [calendar] rail is
/// shown over time instead (see [TimeWindow]) with a month of days beside
/// it. Built once per list; lookups are O(1) or O(log n).
class ActivityRail implements RailScale {
  ActivityRail({
    required this.from,
    required this.to,
    required this.bucket,
    required List<int> counts,
    this.streams = const [],
    this.local = _deviceLocal,
    this.calendar = true,
  }) : _bucketMs = bucket.inMilliseconds,
       _n = counts.length {
    final cum = Float64List(_n + 1);
    final sums = Int64List(_n + 1);
    final weights = Float64List(_n + 1);
    var sum = 0;
    var weight = 0.0;
    for (var i = 0; i < _n; i++) {
      final c = counts[i];
      sum += c;
      sums[i + 1] = sum;
      weight += c == 0 ? gapWeight : 1 + math.log(c);
      weights[i + 1] = weight;
    }
    _weights = weights;
    final total = sum == 0 ? 1 : sum;
    for (var i = 0; i <= _n; i++) {
      cum[i] = sums[i] / total;
    }
    cum[_n] = 1;
    _cum = cum;
    _sums = sums;
  }

  /// Bucket width sources build rails with.
  static const Duration defaultBucket = Duration(minutes: 5);

  /// Weight of an empty bucket in [window], against 1 for one message.
  static const double gapWeight = 0.05;

  @override
  final DateTime from;
  @override
  final DateTime to;
  final Duration bucket;
  final List<HistoryStream> streams;
  final LocalTime local;

  /// Shown as a calendar: a time window plus a month of days. Otherwise the
  /// rail is its own scale.
  final bool calendar;
  final int _bucketMs;
  final int _n;
  late final Float64List _cum;

  /// _sums[i] holds the messages before bucket i.
  late final Int64List _sums;

  /// _weights[i] holds the activity weight before bucket i (see [window]).
  late final Float64List _weights;

  int _indexOf(DateTime t) =>
      (t.difference(from).inMilliseconds / _bucketMs).floor();

  /// Messages from [a] to [b], to the bucket.
  int countBetween(DateTime a, DateTime b) {
    final i = _indexOf(a).clamp(0, _n);
    final j = _indexOf(b).clamp(0, _n);
    return j > i ? _sums[j] - _sums[i] : 0;
  }

  @override
  double positionOf(DateTime t) {
    final ms = t.difference(from).inMilliseconds;
    if (ms <= 0) return 0;
    final i = ms ~/ _bucketMs;
    if (i >= _n) return 1;
    final frac = (ms - i * _bucketMs) / _bucketMs;
    return _cum[i] + (_cum[i + 1] - _cum[i]) * frac;
  }

  @override
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

  /// [from]..[to] weighted by activity: each bucket as long as
  /// `1 + ln(messages)`, an empty one [gapWeight], so quiet stretches shrink
  /// to slivers and a release seldom lands in one.
  RailScale window(DateTime from, DateTime to) =>
      _ActivityWindow(this, from, to);

  double _weightAt(DateTime t) {
    final ms = t.difference(from).inMilliseconds;
    if (ms <= 0) return 0;
    final i = ms ~/ _bucketMs;
    if (i >= _n) return _weights[_n];
    final frac = (ms - i * _bucketMs) / _bucketMs;
    return _weights[i] + (_weights[i + 1] - _weights[i]) * frac;
  }

  DateTime _timeAtWeight(double w) {
    if (w <= 0) return from;
    if (w >= _weights[_n]) return to;
    var lo = 0;
    var hi = _n;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_weights[mid] <= w) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = _weights[lo + 1] - _weights[lo];
    final frac = span <= 0 ? 0.0 : (w - _weights[lo]) / span;
    return from.add(Duration(milliseconds: ((lo + frac) * _bucketMs).round()));
  }

  /// Every local day the rail touches, oldest first.
  late final List<RailDay> days = () {
    final out = <RailDay>[];
    var start = from;
    var day = dayNumber(local(from));
    for (var i = 1; i <= _n; i++) {
      final at = i == _n ? to : from.add(Duration(milliseconds: i * _bucketMs));
      final d = i == _n ? day + 1 : dayNumber(local(at));
      if (d == day) continue;
      out.add((start: start, day: day, count: countBetween(start, at)));
      start = at;
      day = d;
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

  /// Boundary crossed moving from [a] to [b]: 0 none, 1 a day boundary, 2 a
  /// stream start (which wins over a day).
  int crossed(DateTime a, DateTime b) {
    final lo = a.isBefore(b) ? a : b;
    final hi = a.isBefore(b) ? b : a;
    for (final s in streams) {
      if (s.start.isAfter(lo) && !s.start.isAfter(hi)) return 2;
    }
    return dayNumber(local(a)) == dayNumber(local(b)) ? 0 : 1;
  }
}
