import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/screens/home_screen.dart';

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
}
