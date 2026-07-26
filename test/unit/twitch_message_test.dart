import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/twitch_message.dart';

void main() {
  group('TwitchMessage', () {
    test('creates with default timestamp', () {
      final now = DateTime.now();
      final msg = TwitchMessage(login: 'testuser', text: 'hello');
      expect(msg.login, 'testuser');
      expect(msg.text, 'hello');
      expect(msg.timestamp.difference(now).inSeconds, lessThan(2));
      expect(msg.isSystem, false);
      expect(msg.isHistory, false);
      expect(msg.deleted, false);
      expect(msg.isHighlighted, false);
      expect(msg.messageId, isNull);
      expect(msg.channel, isNull);
      expect(msg.color, isNull);
      expect(msg.replyToParentId, isNull);
      expect(msg.replyToUser, isNull);
      expect(msg.replyToText, isNull);
    });

    test('creates with all fields', () {
      final ts = DateTime(2025, 1, 1, 12, 30);
      final msg = TwitchMessage(
        login: 'forsen',
        text: 'Hello chat',
        color: '#FF0000',
        timestamp: ts,
        isSystem: false,
        messageId: 'abc-123',
        channel: 'xqc',
        deleted: false,
        isHistory: true,
        replyToParentId: 'parent-id',
        replyToUser: 'previous-user',
        replyToText: 'previous message',
        isHighlighted: true,
      );
      expect(msg.login, 'forsen');
      expect(msg.text, 'Hello chat');
      expect(msg.color, '#FF0000');
      expect(msg.timestamp, ts);
      expect(msg.isSystem, false);
      expect(msg.messageId, 'abc-123');
      expect(msg.channel, 'xqc');
      expect(msg.isHistory, true);
      expect(msg.replyToParentId, 'parent-id');
      expect(msg.replyToUser, 'previous-user');
      expect(msg.replyToText, 'previous message');
      expect(msg.isHighlighted, true);
    });

    test('creates system message', () {
      final msg = TwitchMessage(
        login: '',
        text: 'Connected',
        isSystem: true,
        channel: 'xqc',
      );
      expect(msg.isSystem, true);
      expect(msg.login, '');
      expect(msg.text, 'Connected');
    });
  });
}
