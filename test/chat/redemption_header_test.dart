import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:flutter_test/flutter_test.dart';

TwitchMessage row(String id, {bool system = false}) => TwitchMessage(
  login: system ? '' : 'fan',
  text: system ? 'Fan redeemed Hydrate (500 pts)' : 'hello',
  messageId: id,
  channel: 'shroud',
  isSystem: system,
);

void main() {
  group('redemption header retro-insert', () {
    test('insertAfter lands directly above the target line', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      const max = 500;
      for (final id in ['m1', 'm2']) {
        chat.receive(
          'shroud',
          row(id),
          maxMessages: max,
          isSelected: true,
          ownLogin: null,
        );
      }
      // Newest-first: m2 on top.
      expect(
        chat.channelFor('shroud')!.messages.items.map((m) => m.messageId),
        ['m2', 'm1'],
      );

      final ok = chat
          .channelFor('shroud')!
          .insertHeaderAbove(
            'm2',
            row('redemp:r1', system: true),
            maxMessages: max,
          );

      expect(ok, isTrue);
      expect(
        chat.channelFor('shroud')!.messages.items.map((m) => m.messageId),
        ['m2', 'redemp:r1', 'm1'],
      );
    });

    test('misses on gone targets and duplicate header ids', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      const max = 500;
      chat.receive(
        'shroud',
        row('m1'),
        maxMessages: max,
        isSelected: true,
        ownLogin: null,
      );
      final channel = chat.channelFor('shroud')!;

      expect(
        channel.insertHeaderAbove(
          'missing',
          row('redemp:r1', system: true),
          maxMessages: max,
        ),
        isFalse,
      );
      expect(
        channel.insertHeaderAbove(
          'm1',
          row('redemp:r1', system: true),
          maxMessages: max,
        ),
        isTrue,
      );
      expect(
        channel.insertHeaderAbove(
          'm1',
          row('redemp:r1', system: true),
          maxMessages: max,
        ),
        isFalse,
        reason: 'header id already buffered',
      );
      expect(channel.messages.items, hasLength(2));
    });
  });
}
