// Size and speed benchmark for the archive block codec.
//
//   dart run tool/archive_bench.dart
//
// Generates seeded synthetic chat (no network, no fixtures) and prints bytes
// per message and encode/decode microseconds per 256-row block.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ermchat/archive/archive_block.dart';
import 'package:ermchat/archive/archive_row.dart';
import 'package:ermchat/archive/archive_users.dart';

const _words = [
  'lol',
  'true',
  'KEKW',
  'that',
  'was',
  'insane',
  'no',
  'way',
  'chat',
  'gg',
  'the',
  'play',
  'W',
  'L',
  'omg',
  'bro',
  'what',
  'is',
  'this',
  'actually',
  'clip',
  'it',
  'nice',
  'LETSGO',
  'hello',
  'from',
  'brazil',
  'again',
  'so',
  'good',
  'wait',
  'really',
  'monkaS',
  'pog',
  'sadge',
  'copium',
  'yes',
];
const _emotes = ['25', '1902', '305954156', 'emotesv2_a1b2c3d4e5f6', '86'];
const _msgIds = ['highlighted-message', 'user-intro', 'sub-gift'];

String _uuid(Random r) {
  String h(int n) =>
      List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
  return '${h(8)}-${h(4)}-4${h(3)}-a${h(3)}-${h(12)}';
}

List<ArchiveRow> _makeRows(Random r, int n, List<int> userStates, int t0) {
  final rows = <ArchiveRow>[];
  final ids = <String>[];
  var t = t0;
  for (var i = 0; i < n; i++) {
    t += r.nextInt(1500) + 1;
    final words = List.generate(
      1 + r.nextInt(r.nextInt(10) == 0 ? 25 : 8),
      (_) => _words[r.nextInt(_words.length)],
    );
    final emotes = <ArchiveEmote>[];
    var text = '';
    for (final w in words) {
      if (r.nextInt(6) == 0) {
        final code = 'Emote${r.nextInt(50)}';
        emotes.add(
          ArchiveEmote(
            _emotes[r.nextInt(_emotes.length)],
            text.length,
            text.length + code.length - 1,
          ),
        );
        text += '$code ';
      } else {
        text += '$w ';
      }
    }
    final id = _uuid(r);
    final reply = ids.isNotEmpty && r.nextInt(12) == 0;
    final parent = reply ? ids[r.nextInt(ids.length)] : null;
    ids.add(id);
    rows.add(
      ArchiveRow(
        timestampMs: t,
        text: text.trimRight(),
        // Skewed: a few chatters send most messages.
        user: userStates[(pow(r.nextDouble(), 3) * userStates.length).floor()],
        messageId: id,
        replyParentId: parent,
        threadRootId: parent,
        replyToUser: reply ? 'user${r.nextInt(30)}' : null,
        isFirstMessage: r.nextInt(80) == 0,
        isAction: r.nextInt(40) == 0,
        msgId: r.nextInt(30) == 0 ? _msgIds[r.nextInt(3)] : null,
        emotes: emotes,
      ),
    );
  }
  return rows;
}

void main() {
  final r = Random(7);
  final tables = UserTables();
  const colors = ['#FF0000', '#00FF7F', '#1E90FF', '#B22222', '#DAA520'];
  const badges = ['', 'subscriber/12', 'subscriber/3,vip/1', 'moderator/1'];
  final states = <int>[];
  for (var i = 0; i < 400; i++) {
    final who = tables.internWho(
      Who(
        userId: '${10000000 + r.nextInt(90000000)}',
        login: 'user$i',
        displayName: r.nextBool() ? 'User$i' : null,
      ),
    );
    final look = tables.internLook(
      Look(
        color: colors[r.nextInt(colors.length)],
        badges: badges[r.nextInt(badges.length)],
      ),
    );
    states.add(tables.internState(who, look));
  }

  const blocks = 200;
  const perBlock = 256;
  final all = [
    for (var b = 0; b < blocks; b++)
      _makeRows(r, perBlock, states, 1760000000000 + b * 600000),
  ];

  var textBytes = 0;
  var totalBytes = 0;
  final encoded = <Uint8List>[];
  final enc = Stopwatch()..start();
  for (final rows in all) {
    encoded.add(ArchiveBlock.encode(rows));
  }
  enc.stop();
  for (var b = 0; b < blocks; b++) {
    totalBytes += encoded[b].length;
    // Text-only block for the text share of the cost.
    textBytes += ArchiveBlock.encode([
      for (final row in all[b]) ArchiveRow(timestampMs: 0, text: row.text),
    ]).length;
  }
  final dec = Stopwatch()..start();
  for (final bytes in encoded) {
    ArchiveBlock.decode(bytes);
  }
  dec.stop();

  const messages = blocks * perBlock;
  stdout.writeln('blocks=$blocks rows/block=$perBlock (synthetic, seed 7)');
  stdout.writeln(
    'bytes/msg total      : ${(totalBytes / messages).toStringAsFixed(1)}',
  );
  stdout.writeln(
    'bytes/msg text only  : ${(textBytes / messages).toStringAsFixed(1)}'
    ' (timestamps zero, no other fields)',
  );
  stdout.writeln(
    'bytes/block avg      : ${(totalBytes / blocks).toStringAsFixed(0)}',
  );
  stdout.writeln(
    'encode us/block      : ${(enc.elapsedMicroseconds / blocks).toStringAsFixed(0)}',
  );
  stdout.writeln(
    'decode us/block      : ${(dec.elapsedMicroseconds / blocks).toStringAsFixed(0)}',
  );
  stdout.writeln(
    'user tables          : ${tables.whos.length} whos, '
    '${tables.looks.length} looks, ${tables.states.length} states',
  );
}
