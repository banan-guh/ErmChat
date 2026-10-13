import '../models/twitch_message.dart';

/// A fake broadcast, used later to drive stream system rows.
class FakeStream {
  const FakeStream(this.start, this.end, this.title);

  final DateTime start;
  final DateTime end;
  final String title;
}

/// Procedural chat archive for the windowed list prototype, compiled in only
/// with `--dart-define=ERMCHAT_FAKE_HISTORY=true`. Rows derive from
/// (channel, row index) alone, so millions of rows cost no memory. Row 0 is
/// the oldest; [loadBlock] mimics the future archive's block reads.
class FakeHistory {
  FakeHistory._();

  static const bool enabled = bool.fromEnvironment('ERMCHAT_FAKE_HISTORY');

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

  static int rowCount(String channel) =>
      _span.inMilliseconds ~/ _step(channel).inMilliseconds;

  static int blockCount(String channel) =>
      (rowCount(channel) + blockSize - 1) ~/ blockSize;

  static DateTime _start(String channel) =>
      _end.subtract(_step(channel) * rowCount(channel));

  /// Row time: a fixed step plus a deterministic jitter below the step.
  static DateTime timeOf(String channel, int row) {
    final step = _step(channel);
    final jitter = channel == denseChannel
        ? _mix(_seed, row) % (step.inMilliseconds - 100)
        : 0;
    return _start(channel).add(step * row).add(Duration(milliseconds: jitter));
  }

  /// First row at or after [time], clamped to the archive.
  static int rowAtTime(String channel, DateTime time) {
    final ms = time.difference(_start(channel)).inMilliseconds;
    return (ms ~/ _step(channel).inMilliseconds).clamp(0, rowCount(channel));
  }

  /// Fake broadcasts for [channel], oldest first; empty for the dense one.
  static List<FakeStream> streams(String channel) {
    if (channel != testChannel) return const [];
    const plan = [
      (27.0, 4.0, 'Fake stream one'),
      (21.5, 6.0, 'Late night fake stream'),
      (14.2, 3.5, 'Fake stream three'),
      (6.8, 8.0, 'Marathon fake stream'),
      (1.3, 2.5, 'Short fake stream'),
    ];
    return [
      for (final (daysAgo, hours, title) in plan)
        FakeStream(
          _end.subtract(Duration(minutes: (daysAgo * 1440).round())),
          _end.subtract(
            Duration(minutes: (daysAgo * 1440).round() - (hours * 60).round()),
          ),
          title,
        ),
    ];
  }

  /// Decodes block [blockIndex] after [loadDelay]; empty past the archive.
  static Future<List<TwitchMessage>> loadBlock(
    String channel,
    int blockIndex,
  ) async {
    if (loadDelay > Duration.zero) await Future<void>.delayed(loadDelay);
    final total = rowCount(channel);
    final first = blockIndex * blockSize;
    if (blockIndex < 0 || first >= total) return const [];
    final last = first + blockSize < total ? first + blockSize : total;
    return [for (var i = first; i < last; i++) rowAt(channel, i)];
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
