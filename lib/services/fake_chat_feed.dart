import 'dart:async';
import 'dart:math';

import '../emotes/emote.dart';
import '../irc/decode/decoder.dart';
import '../irc/message.dart';
import '../models/twitch_message.dart';

/// Seeded synthetic PRIVMSG load for battery tuning, fed through the real
/// read decoder. Starts at `--dart-define=ERMCHAT_FAKE_CHAT=<msgs/sec>`; dev
/// settings change the rate at runtime. The same seed and
/// emote pool produce the same stream every run.
class FakeChatFeed {
  FakeChatFeed({
    required this.decoder,
    required this.channel,
    required this.emotes,
    this.seed = 1,
  });

  /// Starting messages per second; 0 leaves the feed off.
  static const int defaultRate = int.fromEnvironment('ERMCHAT_FAKE_CHAT');

  final IrcChatDecoder decoder;
  final String? Function() channel;

  /// Emote pool for [channel], read each tick so it fills in once loaded.
  final List<Emote> Function(String channel) emotes;
  final int seed;

  late final Random _rng = Random(seed);
  Timer? _timer;
  int _n = 0;

  /// Current messages per second; 0 is off.
  int get rate => _rate;
  int _rate = defaultRate;

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
  ];
  static const _colors = ['#FF4500', '#1E90FF', '#9ACD32', '#DAA520', ''];

  /// Whether a feed has run this session. Only then can a row be fake, so a
  /// real chatter named like a fake one is never mistaken for one.
  static bool _ran = false;

  /// Whether [msg] came from a feed: its id or sender, or for a system line
  /// (a timeout notice), a fake chatter it names. The archive skips these.
  static bool owns(TwitchMessage msg) =>
      _ran &&
      ((msg.messageId?.startsWith(_idPrefix) ?? false) ||
          ownsLogin(msg.login) ||
          msg.isSystem && msg.text.contains(_userPrefix));

  /// Whether [login] is a feed's chatter.
  static bool ownsLogin(String? login) =>
      _ran && (login?.startsWith(_userPrefix) ?? false);

  /// Whether [id] is a feed's message id.
  static bool ownsId(String id) => _ran && id.startsWith(_idPrefix);

  static const _idPrefix = 'fake-';
  static const _userPrefix = 'fake_user';

  void start() {
    if (_rate <= 0 || _timer != null) return;
    _ran = true;
    _timer = Timer.periodic(Duration(microseconds: 1000000 ~/ _rate), (_) {
      final ch = _channel();
      if (ch != null) _feed(_next(ch));
    });
  }

  /// Restarts the live feed at [perSecond]; 0 stops it.
  void setRate(int perSecond) {
    _rate = max(0, perSecond);
    _timer?.cancel();
    _timer = null;
    start();
  }

  String? _channel() {
    final ch = channel();
    return ch == null || ch.startsWith('@') ? null : ch;
  }

  void _feed(String line) {
    final msg = parseIrcMessage(line);
    // Dev load tool: rides the decoder's test seam on purpose.
    // ignore: invalid_use_of_visible_for_testing_member
    if (msg != null) decoder.feed(msg);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  /// Recent (user, message id) pairs, targets for moderation lines.
  final List<(String, String)> _recent = [];

  /// Mostly chat, with a timeout or single delete every ~40 lines so
  /// moderation edits land on rows already on screen.
  String _next(String ch) {
    final roll = _rng.nextInt(40);
    if (roll < 2 && _recent.length > 10) {
      final (user, id) = _recent[_recent.length - 1 - _rng.nextInt(10)];
      final ts = DateTime.now().millisecondsSinceEpoch;
      if (roll == 0) {
        return '@ban-duration=10;room-id=1;target-user-id=0;tmi-sent-ts=$ts '
            ':tmi.twitch.tv CLEARCHAT #$ch :$user';
      }
      return '@login=$user;room-id=1;target-msg-id=$id;tmi-sent-ts=$ts '
          ':tmi.twitch.tv CLEARMSG #$ch :deleted';
    }
    return _line(ch);
  }

  String _line(String ch) {
    final n = _n++;
    final user = '$_userPrefix${_rng.nextInt(400)}';
    _recent.add((user, '$_idPrefix$seed-$n'));
    if (_recent.length > 50) _recent.removeAt(0);
    final pool = emotes(ch);
    final parts = <String>[];
    final len = 1 + _rng.nextInt(8);
    for (var i = 0; i < len; i++) {
      // About a third of the words are emotes, like a busy channel. Cubing
      // the draw skews toward the pool's head so a few emotes dominate.
      if (pool.isNotEmpty && _rng.nextInt(3) == 0) {
        final r = _rng.nextDouble();
        parts.add(pool[(r * r * r * pool.length).floor()].code);
      } else {
        parts.add(_words[_rng.nextInt(_words.length)]);
      }
    }
    final ts = DateTime.now().millisecondsSinceEpoch;
    final color = _colors[_rng.nextInt(_colors.length)];
    return '@badge-info=;badges=;color=$color;display-name=$user;emotes=;'
        'first-msg=0;flags=;id=$_idPrefix$seed-$n;mod=0;room-id=1;subscriber=0;'
        'tmi-sent-ts=$ts;turbo=0;user-id=${900000 + n};user-type= '
        ':$user!$user@$user.tmi.twitch.tv PRIVMSG #$ch :${parts.join(' ')}';
  }
}
