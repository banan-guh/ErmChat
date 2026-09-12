import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:flutter_test/flutter_test.dart';

TwitchMessage _live(String id) => TwitchMessage(
  login: 'alice',
  text: 'hello $id',
  messageId: id,
  channel: 'test',
);

void main() {
  group('Channel.addSystemMessage', () {
    test('inserts the row and truncates to the cap', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      for (var i = 0; i < 4; i++) {
        channel.receive(
          _live('m$i'),
          maxMessages: 10,
          isSelected: true,
          ownLogin: null,
        );
      }
      expect(channel.messages.length, 4);

      expect(channel.addSystemMessage('Connected', maxMessages: 3), isTrue);

      expect(channel.messages.length, 3);
      expect(channel.messages.items.first.text, 'Connected');
      expect(channel.messages.items.first.isSystem, isTrue);
    });

    test('a duplicate id returns false and does not truncate', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      expect(
        channel.addSystemMessage('hello', messageId: 'dup', maxMessages: 10),
        isTrue,
      );
      for (var i = 0; i < 4; i++) {
        channel.receive(
          _live('m$i'),
          maxMessages: 10,
          isSelected: true,
          ownLogin: null,
        );
      }
      final before = channel.messages.length;

      expect(
        channel.addSystemMessage('hello', messageId: 'dup', maxMessages: 1),
        isFalse,
      );

      expect(channel.messages.length, before);
    });
  });
}
