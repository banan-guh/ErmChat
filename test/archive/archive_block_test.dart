import 'dart:typed_data';

import 'package:ermchat/archive/archive_block.dart';
import 'package:ermchat/archive/archive_io.dart';
import 'package:ermchat/archive/archive_row.dart';
import 'package:ermchat/archive/archive_users.dart';
import 'package:flutter_test/flutter_test.dart';

const _id1 = '3f1c2a9e-0b7d-4c55-9a10-6d2e8f4b7a01';
const _id2 = '0a9d7c11-5e2b-48f0-b3c4-1122334455ff';
const _outsideId = 'c0ffee00-1111-4222-8333-444455556666';

List<ArchiveRow> _mixedBlock() {
  return [
    const ArchiveRow(
      timestampMs: 1760000000000,
      text: 'hello chat',
      user: 0,
      messageId: _id1,
      isFirstMessage: true,
      msgId: 'highlighted-message',
    ),
    ArchiveRow(
      timestampMs: 1760000000450,
      text: '@alice thanks Kappa Kappa',
      user: 1,
      messageId: _id2,
      replyParentId: _id1,
      threadRootId: _id1,
      replyToUser: 'alice',
      emotes: const [ArchiveEmote('25', 14, 18), ArchiveEmote('25', 20, 24)],
    ),
    const ArchiveRow(
      timestampMs: 1760000000400,
      text: 'out of order, reply to an old parent',
      user: 1,
      messageId: 'legacy-id-not-a-uuid',
      replyParentId: _outsideId,
      threadRootId: 'root-outside-block',
      replyToUser: 'bob',
    ),
    const ArchiveRow(
      timestampMs: 1760000005000,
      text: 'Stream started',
      isSystem: true,
      isHistory: true,
    ),
    const ArchiveRow(timestampMs: 1760000006000, text: '', user: 2),
    ArchiveRow(
      timestampMs: 1760000007000,
      text: 'waves \u{1F44B}\u{1F3FD} こんにちは',
      user: 2,
      isAction: true,
      deleted: true,
      isBackfill: true,
      isBanNotice: true,
      bitsAmount: 100,
      pinnedPaidAmount: '5.00',
      customRewardId: _id2,
      sourceBroadcasterId: '12345',
      sourceMessageId: _id1,
      extraTags: const [('flags', '0-4:A.3'), ('vip', '1'), ('empty', '')],
    ),
    ArchiveRow(
      timestampMs: 1760000008000,
      text: List.filled(500, 'x').join(),
      user: 0,
      messageId: _id1,
    ),
  ];
}

void main() {
  test('mixed block round-trips every carried field', () {
    final rows = _mixedBlock();
    final decoded = ArchiveBlock.decode(ArchiveBlock.encode(rows));
    expect(decoded.length, rows.length);
    for (var i = 0; i < rows.length; i++) {
      expect(decoded[i], rows[i], reason: 'row $i');
    }
  });

  test('empty block round-trips', () {
    expect(ArchiveBlock.decode(ArchiveBlock.encode(const [])), isEmpty);
  });

  test('first byte is the format version', () {
    final bytes = ArchiveBlock.encode(_mixedBlock());
    expect(bytes.first, ArchiveBlock.version);
    final future = Uint8List.fromList(bytes)..[0] = 99;
    expect(
      () => ArchiveBlock.decode(future),
      throwsA(isA<ArchiveFormatException>()),
      reason: 'an unknown version must not be parsed as the current one',
    );
  });

  test('truncated or corrupt block throws a typed error', () {
    final bytes = ArchiveBlock.encode(_mixedBlock());
    for (final cut in [0, 1, 2, 5, bytes.length ~/ 2, bytes.length - 1]) {
      expect(
        () => ArchiveBlock.decode(Uint8List.sublistView(bytes, 0, cut)),
        throwsA(isA<ArchiveFormatException>()),
        reason: 'truncated at $cut',
      );
    }
    final flipped = Uint8List.fromList(bytes)
      ..[bytes.length ~/ 2] ^= 0xff
      ..[bytes.length - 3] ^= 0x55;
    expect(
      () => ArchiveBlock.decode(flipped),
      throwsA(isA<ArchiveFormatException>()),
      reason: 'the checksum catches flipped bytes',
    );
    expect(
      () => ArchiveBlock.decode(Uint8List.fromList([1, 4, 1, 2, 3, 4])),
      throwsA(isA<ArchiveFormatException>()),
      reason: 'garbage after a valid version byte',
    );
  });

  test('valid deflate with a hostile payload throws a typed error', () {
    final payload = ByteWriter()
      ..varint(1 << 20)
      ..bytes(List.filled(8, 0));
    final raw = payload.takeBytes();
    final bytes = packPayload(ArchiveBlock.version, raw);
    expect(
      () => ArchiveBlock.decode(bytes),
      throwsA(isA<ArchiveFormatException>()),
      reason: 'a huge row count must not allocate or loop',
    );
  });

  test('user tables intern by value and round-trip', () {
    final t = UserTables();
    final alice = t.internWho(
      const Who(userId: '1', login: 'alice', displayName: 'Alice'),
    );
    final bob = t.internWho(const Who(userId: '2', login: 'bob'));
    final red = t.internLook(
      const Look(color: '#FF0000', badges: 'subscriber/12,vip/1'),
    );
    final redAgain = t.internLook(
      const Look(color: '#FF0000', badges: 'subscriber/12,vip/1'),
    );
    final plain = t.internLook(
      const Look(extra: [('paint', 'abc'), ('badge7tv', 'x')]),
    );
    expect(redAgain, red, reason: 'identical looks share one id');
    final a = t.internState(alice, red);
    expect(t.internState(alice, red), a);
    t.internState(bob, plain);
    t.internState(bob, red);

    final back = UserTables.decode(t.encode());
    expect(back.whos, t.whos);
    expect(back.looks, t.looks);
    expect(back.states, t.states);
    expect(back.whos[bob].displayName, isNull);
    expect(
      () => UserTables.decode(t.encode().sublist(0, 6)),
      throwsA(isA<ArchiveFormatException>()),
    );
  });
}
