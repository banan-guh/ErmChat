// IRC probe: connect to Twitch IRC like the app does, dump raw lines, and
// summarize which message types/notice ids flow. Used to audit what the app
// currently parses vs ignores.
//
// Usage:
//   dart run tool/irc_probe.dart <channel> [seconds] [oauth:token]
//
// Anonymous by default (justinfan12345); pass an oauth token for a real
// account (USERSTATE/GLOBALUSERSTATE/WHISPER behavior differs).

import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  final channel = (args.isNotEmpty ? args[0] : 'xqc')
      .replaceFirst('#', '')
      .toLowerCase();
  final seconds = args.length > 1 ? int.parse(args[1]) : 60;
  final oauth = args.length > 2 ? args[2] : null;

  final ws = await WebSocket.connect('wss://irc-ws.chat.twitch.tv:443');
  ws.add('CAP REQ :twitch.tv/tags twitch.tv/commands');
  if (oauth == null) {
    ws.add('PASS SCHMOOPIIE');
    ws.add('NICK justinfan12345');
  } else {
    ws.add('PASS $oauth');
    ws.add('NICK ${oauth.substring(oauth.indexOf(':') + 1)}');
  }
  ws.add('JOIN #$channel');

  final counts = <String, int>{};
  final msgIds = <String, int>{};
  final samples = <String, String>{};
  var total = 0;

  void processLine(String raw) {
    final line = raw.trim();
    if (line.isEmpty) return;
    total++;
    if (commandOf(line) == 'PING') {
      ws.add(line.replaceFirst('PING', 'PONG'));
    }
    final cmd = commandOf(line);
    counts[cmd] = (counts[cmd] ?? 0) + 1;
    final msgId = msgIdOf(line);
    if (msgId != null) msgIds[msgId] = (msgIds[msgId] ?? 0) + 1;
    final key = msgId == null ? cmd : '$cmd/$msgId';
    samples.putIfAbsent(key, () => line);
    stdout.writeln(line);
  }

  ws.listen(
    (data) => data.toString().split('\r\n').forEach(processLine),
    onError: (Object e) => stderr.writeln('ws error: $e'),
    onDone: () {
      stderr.writeln('socket closed early');
      exit(1);
    },
  );

  await Future<void>.delayed(Duration(seconds: seconds));
  await ws.close();

  stdout.writeln('\n=== SUMMARY ($seconds s, $total lines) ===');
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in sorted) {
    stdout.writeln('${e.value.toString().padLeft(6)} ${e.key}');
  }
  if (msgIds.isNotEmpty) {
    stdout.writeln('\n=== msg-id distribution ===');
    final idSorted = msgIds.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in idSorted) {
      stdout.writeln('${e.value.toString().padLeft(6)} ${
        e.key
      }${counts.containsKey('USERNOTICE') ? '' : ''}');
    }
  }
  stdout.writeln('\n=== one raw sample per (command, msg-id) ===');
  final keys = samples.keys.toList()..sort();
  for (final k in keys) {
    stdout.writeln('--- $k');
    stdout.writeln(samples[k]);
  }
}

/// Extracts the IRC command (after optional tags and prefix).
String commandOf(String line) {
  var s = line;
  if (s.startsWith('@')) {
    final i = s.indexOf(' ');
    s = s.substring(i + 1);
  }
  if (s.startsWith(':')) {
    final i = s.indexOf(' ');
    s = s.substring(i + 1);
  }
  final sp = s.indexOf(' ');
  return sp == -1 ? s : s.substring(0, sp);
}

/// Extracts `msg-id` from a line's tags, if present.
String? msgIdOf(String line) {
  final m = RegExp(r'(?:^|;)msg-id=([^;\s]+)').firstMatch(line);
  return m?.group(1);
}
