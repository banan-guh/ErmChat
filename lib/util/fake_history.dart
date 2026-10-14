import 'package:flutter/foundation.dart' show kReleaseMode;

import '../models/twitch_message.dart';
import 'history_timeline.dart';

/// Procedural chat archive for the windowed list prototype, compiled in only
/// in debug and profile builds, never in release. Rows derive from
/// (channel, row index) alone, so millions of rows cost no memory. Row 0 is
/// the oldest; [FakeHistorySource] reads it like the archive.
class FakeHistory {
  FakeHistory._();

  static const bool enabled = !kReleaseMode;

  static const String testChannel = '_testchannel';
  static const String denseChannel = '_testdense';

  /// Rows per block, like an archive block.
  static const int blockSize = 256;

  /// Simulated decode time per block; zero skips the delay.
  static Duration loadDelay = const Duration(milliseconds: 1);

  static const Duration _span = Duration(days: 30);
  static const Duration _testStep = Duration(minutes: 10);
  static const Duration _denseStep = Duration(milliseconds: 500);
  static const int _seed = 7;

  /// Fixed at launch so row times stay stable for the whole run.
  static final DateTime _end = DateTime.fromMillisecondsSinceEpoch(
    DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000,
  );

  /// True for a prototype channel; always false when the flag is off.
  static bool isFake(String channel) =>
      enabled && (channel == testChannel || channel == denseChannel);

  static Duration _step(String channel) =>
      channel == denseChannel ? _denseStep : _testStep;

  /// `_testchannel` records nothing for [_gapLength] starting [_gapAt] after
  /// the archive start, long enough to span whole local days.
  static const Duration _gapAt = Duration(days: 18, hours: 12);
  static const Duration _gapLength = Duration(days: 4, hours: 7);

  static Duration _gap(String channel) =>
      channel == denseChannel ? Duration.zero : _gapLength;

  static int rowCount(String channel) =>
      (_span - _gap(channel)).inMilliseconds ~/ _step(channel).inMilliseconds;

  /// First row after the gap in `_testchannel`; the dense channel has no gap.
  static int get _gapRow => _gapAt.inMilliseconds ~/ _testStep.inMilliseconds;

  /// Fixed clock of the prototype: the end of the archive.
  static DateTime get now => _end;

  /// Oldest retained time for [channel].
  static DateTime startOf(String channel) => _start(channel);

  /// Message counts per bucket, derived from the generated rows.
  static const ActivityIndex activity = _FakeActivity();

  static DateTime _start(String channel) => _end.subtract(_span);

  /// Row time: a fixed step plus a deterministic jitter below the step, and
  /// the gap added to rows after it.
  static DateTime timeOf(String channel, int row) {
    final step = _step(channel);
    final jitter = channel == denseChannel
        ? _mix(_seed, row) % (step.inMilliseconds - 100)
        : 0;
    final skip = row >= _gapRow ? _gap(channel) : Duration.zero;
    return _start(
      channel,
    ).add(step * row).add(skip).add(Duration(milliseconds: jitter));
  }

  /// First row at or after [time], clamped to the archive; a time inside the
  /// gap maps to the first row after it.
  static int rowAtTime(String channel, DateTime time) {
    var ms = time.difference(_start(channel)).inMilliseconds;
    final gap = _gap(channel).inMilliseconds;
    if (gap > 0) {
      final at = _gapAt.inMilliseconds;
      if (ms >= at + gap) {
        ms -= gap;
      } else if (ms > at) {
        ms = at;
      }
    }
    final step = _step(channel).inMilliseconds;
    return ((ms + step - 1) ~/ step).clamp(0, rowCount(channel));
  }

  /// Fake broadcasts for [channel], oldest first; empty for the dense one.
  static List<HistoryStream> streams(String channel) {
    if (channel != testChannel) return const [];
    const plan = [
      (27.0, 4.0, 'Fake stream one', 'Just Chatting'),
      (21.5, 6.0, 'Late night fake stream', 'Minecraft'),
      (14.2, 3.5, 'Fake stream three', 'Elden Ring'),
      (6.8, 8.0, 'Marathon fake stream', 'Just Chatting'),
      (1.3, 2.5, 'Short fake stream', 'Chess'),
    ];
    return [
      for (final (i, (daysAgo, hours, title, game)) in plan.indexed)
        HistoryStream(
          id: 'fake-stream-${i + 1}',
          start: _end.subtract(Duration(minutes: (daysAgo * 1440).round())),
          end: _end.subtract(
            Duration(minutes: (daysAgo * 1440).round() - (hours * 60).round()),
          ),
          title: title,
          game: game,
        ),
    ];
  }

  /// Rows [from] up to [to] (clamped to the archive) after [loadDelay].
  static Future<List<TwitchMessage>> rows(
    String channel,
    int from,
    int to,
  ) async {
    if (loadDelay > Duration.zero) await Future<void>.delayed(loadDelay);
    final total = rowCount(channel);
    final a = from.clamp(0, total);
    final b = to.clamp(a, total);
    return [for (var i = a; i < b; i++) rowAt(channel, i)];
  }

  static TwitchMessage rowAt(String channel, int row) {
    final time = timeOf(channel, row);
    final id = '$channel-$row';
    if (channel != denseChannel) {
      return TwitchMessage(
        login: 'testuser',
        displayName: 'testuser',
        text: 'testing',
        color: '#1E90FF',
        timestamp: time,
        messageId: id,
        channel: channel,
        userId: '1',
      );
    }
    final h = _mix(_seed, row);
    final user = _mix(h, 1) % 1500;
    final text = _text(h);
    final reply = _mix(h, 2) % 100 < 8;
    final parent = reply ? (row - 1 - _mix(h, 3) % 50).clamp(0, row) : 0;
    final parentUser = (user * 7 + 3) % 1500;
    return TwitchMessage(
      login: 'viewer$user',
      displayName: user.isEven ? 'Viewer$user' : 'viewer$user',
      text: reply ? '@viewer$parentUser $text' : text,
      color: _colors[user % _colors.length],
      timestamp: time,
      messageId: id,
      channel: channel,
      userId: '${1000 + user}',
      replyToParentId: reply ? '$channel-$parent' : null,
      replyThreadRootId: reply ? '$channel-$parent' : null,
      replyToUser: reply ? 'viewer$parentUser' : null,
      replyToText: reply ? 'earlier message $parent' : null,
    );
  }

  static const _colors = [
    '#FF4500',
    '#1E90FF',
    '#9ACD32',
    '#DAA520',
    '#FF69B4',
    '#8A2BE2',
  ];

  static const _words = [
    'lol',
    'the',
    'is',
    'that',
    'what',
    'no',
    'yes',
    'chat',
    'clip',
    'it',
    'bro',
    'actually',
    'insane',
    'wait',
    'true',
    'real',
    'gg',
    'nice',
    'huh',
    'streamer',
    'again',
    'so',
    'good',
    'this',
    'why',
    'LMAO',
    'W',
    'L',
    'unbelievable',
    'honestly',
    'literally',
  ];

  /// One word to about 500 characters, mostly short like real chat.
  static String _text(int h) {
    final roll = _mix(h, 4) % 100;
    final out = StringBuffer();
    if (roll >= 99) {
      final target = 450 + _mix(h, 5) % 50;
      var n = 0;
      while (out.length < target) {
        if (out.isNotEmpty) out.write(' ');
        out.write(_words[_mix(h, 10 + n++) % _words.length]);
      }
      return out.toString().substring(0, target);
    }
    final words = roll < 45
        ? 1 + _mix(h, 6) % 3
        : roll < 80
        ? 4 + _mix(h, 6) % 7
        : roll < 95
        ? 11 + _mix(h, 6) % 15
        : 26 + _mix(h, 6) % 35;
    for (var n = 0; n < words; n++) {
      if (n > 0) out.write(' ');
      out.write(_words[_mix(h, 10 + n) % _words.length]);
    }
    return out.toString();
  }

  /// 32-bit integer hash of two ints, stable across runs and platforms.
  static int _mix(int a, int b) {
    var h = (a * 0x9E3779B1 + b * 0x85EBCA6B + 0x27D4EB2F) & 0xFFFFFFFF;
    h ^= h >>> 15;
    h = (h * 0x2C1B3C6D) & 0xFFFFFFFF;
    h ^= h >>> 12;
    h = (h * 0x297A2D39) & 0xFFFFFFFF;
    h ^= h >>> 15;
    return h;
  }
}

/// [HistorySource] over the generated rows of one prototype channel.
class FakeHistorySource implements HistorySource {
  FakeHistorySource(this.channel);

  final String channel;
  static const int _bs = FakeHistory.blockSize;

  @override
  DateTime now() => FakeHistory.now;

  @override
  Future<List<TwitchMessage>> older(DateTime time) {
    final end = FakeHistory.rowAtTime(
      channel,
      time.add(const Duration(milliseconds: 1)),
    );
    return FakeHistory.rows(channel, end - _bs, end);
  }

  @override
  Future<List<TwitchMessage>> newer(DateTime time) {
    final start = FakeHistory.rowAtTime(channel, time);
    return FakeHistory.rows(channel, start, start + _bs);
  }

  @override
  Future<List<TwitchMessage>> around(DateTime time) {
    final row = FakeHistory.rowAtTime(channel, time);
    return FakeHistory.rows(channel, row - _bs * 3 ~/ 2, row + _bs * 3 ~/ 2);
  }

  @override
  Future<List<TwitchMessage>> newest() {
    final total = FakeHistory.rowCount(channel);
    return FakeHistory.rows(channel, total - _bs * 2, total);
  }

  @override
  Future<List<HistoryStream>> streams() async => FakeHistory.streams(channel);

  @override
  Future<ActivityRail?> rail(List<HistoryStream> streams) async {
    final from = FakeHistory.startOf(channel);
    const bucket = ActivityRail.defaultBucket;
    return ActivityRail(
      from: from,
      to: FakeHistory.now,
      bucket: bucket,
      counts: FakeHistory.activity.counts(
        channel,
        from,
        FakeHistory.now,
        bucket,
      ),
      streams: streams,
    );
  }

  @override
  void Function() watchClears(void Function(HistoryClear clear) onClear) =>
      () {};
}

/// Counts rows per bucket from the generated timeline.
class _FakeActivity implements ActivityIndex {
  const _FakeActivity();

  @override
  List<int> counts(
    String channel,
    DateTime from,
    DateTime to,
    Duration bucket,
  ) {
    final n = ((to.difference(from).inMilliseconds) / bucket.inMilliseconds)
        .ceil();
    final out = List<int>.filled(n, 0);
    var prev = FakeHistory.rowAtTime(channel, from);
    for (var i = 0; i < n; i++) {
      final next = FakeHistory.rowAtTime(channel, from.add(bucket * (i + 1)));
      out[i] = next - prev;
      prev = next;
    }
    return out;
  }
}
