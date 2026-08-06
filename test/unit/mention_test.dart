import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/util/mention.dart';

TwitchMessage _msg(String text, {String login = 'otheruser', String? replyTo}) {
  return TwitchMessage(
    login: login,
    text: text,
    isSystem: false,
    replyToUser: replyTo,
  );
}

void main() {
  group('isMention', () {
    test('detects @username mention', () {
      expect(isMention('hello @forsen', 'forsen'), isTrue);
    });

    test('detects username without @', () {
      expect(isMention('hello forsen', 'forsen'), isTrue);
    });

    test('is case-insensitive', () {
      expect(isMention('hello @Forsen', 'forsen'), isTrue);
      expect(isMention('hello FORSEN', 'forsen'), isTrue);
    });

    test('returns false when username not in text', () {
      expect(isMention('hello world', 'forsen'), isFalse);
    });

    test('returns false for substring match', () {
      expect(isMention('forsenator', 'forsen'), isFalse);
    });

    test('handles punctuation around username', () {
      expect(isMention('hello @forsen!', 'forsen'), isTrue);
      expect(isMention('(@forsen)', 'forsen'), isTrue);
      expect(isMention('hello forsen.', 'forsen'), isTrue);
    });

    test('handles empty text', () {
      expect(isMention('', 'forsen'), isFalse);
    });

    test('handles empty login', () {
      expect(isMention('hello', ''), isFalse);
    });
  });

  group('isMentionOf', () {
    test('detects a direct ping', () {
      expect(isMentionOf(_msg('hey @forsen'), 'forsen'), isTrue);
    });

    test('detects a reply to the user', () {
      expect(
        isMentionOf(_msg('great point', replyTo: 'forsen'), 'forsen'),
        isTrue,
      );
    });

    test('is case-insensitive on login and reply target', () {
      expect(isMentionOf(_msg('hey @FORSEN'), 'forsen'), isTrue);
      expect(isMentionOf(_msg('hi', replyTo: 'Forsen'), 'forsen'), isTrue);
    });

    test('false for the user\'s own message', () {
      expect(
        isMentionOf(_msg('hey @forsen', login: 'forsen'), 'forsen'),
        isFalse,
      );
    });

    test('false for system messages', () {
      final msg = TwitchMessage(
        login: '',
        text: 'Chat was cleared.',
        isSystem: true,
      );
      expect(isMentionOf(msg, 'forsen'), isFalse);
    });

    test('false when not a mention', () {
      expect(isMentionOf(_msg('hello world'), 'forsen'), isFalse);
    });
  });
}
