import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:flutter_test/flutter_test.dart';

TwitchMessage _mention(String id, DateTime ts, {String channel = 'test'}) =>
    TwitchMessage(
      login: 'alice',
      text: 'hi',
      messageId: id,
      channel: channel,
      timestamp: ts,
    );

void main() {
  group('Mentions.add', () {
    test(
      'mirror ordering stays newest-first across midnight and caller iteration order',
      () {
        final cases = [
          (
            'sorts a mixed batch newest-first across midnight',
            [
              _mention('m1', DateTime(2026, 8, 22, 23, 59, 59)),
              _mention('m2', DateTime(2026, 8, 23, 0, 0, 1)),
            ],
            ['m2', 'm1'],
          ),
          (
            'caller iteration order never leaks into the buffer',
            [
              for (var i = 0; i < 5; i++)
                _mention('m$i', DateTime(2026, 8, 20, 12, 0, i)),
            ],
            ['m4', 'm3', 'm2', 'm1', 'm0'],
          ),
        ];
        for (final (label, input, expected) in cases) {
          final chat = Chat();
          addTearDown(chat.dispose);
          chat.mentions.add(input, maxMessages: 10);
          expect(
            chat.mentions.items.map((m) => m.messageId),
            expected,
            reason: label,
          );
          final other = Chat();
          addTearDown(other.dispose);
          other.mentions.add(input.reversed.toList(), maxMessages: 10);
          expect(
            other.mentions.items.map((m) => m.messageId),
            expected,
            reason: '$label reversed',
          );
        }
      },
    );

    test('dedupes against the buffer and within the batch', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final t = DateTime(2026, 8, 21, 10);
      chat.mentions.add([_mention('m1', t)], maxMessages: 10);
      chat.mentions.add([
        _mention('m2', t.add(const Duration(minutes: 1))),
        _mention('m1', t),
      ], maxMessages: 10);

      expect(chat.mentions.items.map((m) => m.messageId), ['m2', 'm1']);
    });

    test('caps the buffer keeping the newest messages', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final msgs = [
        for (var i = 0; i < 6; i++)
          _mention('m$i', DateTime(2026, 8, 20, 12, i)),
      ];

      chat.mentions.add(msgs, maxMessages: 4);

      expect(chat.mentions.items.map((m) => m.messageId), [
        'm5',
        'm4',
        'm3',
        'm2',
      ]);
    });
  });
}
