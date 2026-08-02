import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/services/twitch_irc.dart';

void main() {
  late IrcService service;

  setUp(() {
    service = IrcService();
  });

  tearDown(() {
    service.dispose();
  });

  group('initial state', () {
    test('isConnected is false', () {
      expect(service.isConnected, false);
    });
  });

  group('sendMessage when not connected', () {
    test('sendMessage does not crash', () {
      expect(
        () => service.sendMessage('testchannel', 'hello'),
        returnsNormally,
      );
    });
  });

  group('channel tracking', () {
    test('join does not crash when not connected', () {
      expect(() => service.join('testchannel'), returnsNormally);
    });

    test('part does not crash when not connected', () {
      expect(() => service.part('testchannel'), returnsNormally);
    });
  });

  group('stream controllers', () {
    test('onNotice stream can be listened to', () {
      final events = <IrcNoticeEvent>[];
      service.onNotice.listen(events.add);
      expect(events, isEmpty);
    });

    test('onJtvMessage stream can be listened to', () {
      final events = <IrcNoticeEvent>[];
      service.onJtvMessage.listen(events.add);
      expect(events, isEmpty);
    });
  });

  group('CLEARMSG', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test('emits delete event with messageId, user, and deleted text', () async {
      final events = <IrcMessageDeletedEvent>[];
      service.onMessageDeleted.listen(events.add);

      service.handleLine(
        '@login=forsen;target-msg-id=abc-123 :tmi.twitch.tv CLEARMSG #xqc :bad message',
      );
      await flush();

      expect(events, hasLength(1));
      expect(events[0].channel, 'xqc');
      expect(events[0].messageId, 'abc-123');
      expect(events[0].user, 'forsen');
      expect(events[0].deletedMessageText, 'bad message');
    });

    test('ignores CLEARMSG without target-msg-id', () async {
      final events = <IrcMessageDeletedEvent>[];
      service.onMessageDeleted.listen(events.add);

      service.handleLine(
        '@login=forsen :tmi.twitch.tv CLEARMSG #xqc :bad message',
      );
      await flush();

      expect(events, isEmpty);
    });

    test('defaults user to unknown when login tag missing', () async {
      final events = <IrcMessageDeletedEvent>[];
      service.onMessageDeleted.listen(events.add);

      service.handleLine(
        '@target-msg-id=xyz :tmi.twitch.tv CLEARMSG #xqc :deleted',
      );
      await flush();

      expect(events, hasLength(1));
      expect(events[0].user, 'unknown');
    });
  });

  group('CLEARCHAT', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test('emits ban event for permanent ban', () async {
      final events = <IrcBanEvent>[];
      service.onBan.listen(events.add);

      service.handleLine(':tmi.twitch.tv CLEARCHAT #xqc :forsen');
      await flush();

      expect(events, hasLength(1));
      expect(events[0].channel, 'xqc');
      expect(events[0].user, 'forsen');
      expect(events[0].isTimeout, isFalse);
      expect(events[0].duration, isNull);
    });

    test('emits timeout event with duration', () async {
      final events = <IrcBanEvent>[];
      service.onBan.listen(events.add);

      service.handleLine(
        '@ban-duration=300;target-user-id=12345 :tmi.twitch.tv CLEARCHAT #xqc :forsen',
      );
      await flush();

      expect(events, hasLength(1));
      expect(events[0].user, 'forsen');
      expect(events[0].isTimeout, isTrue);
      expect(events[0].duration, 300);
      expect(events[0].userId, '12345');
    });

    test('ignores CLEARCHAT for full room clear (no target user)', () async {
      final events = <IrcBanEvent>[];
      service.onBan.listen(events.add);

      service.handleLine(':tmi.twitch.tv CLEARCHAT #xqc');
      await flush();

      expect(events, isEmpty);
    });
  });

  group('dispose', () {
    test('dispose does not crash', () {
      expect(() => service.dispose(), returnsNormally);
    });

    test('double dispose does not crash', () {
      service.dispose();
      expect(() => service.dispose(), returnsNormally);
    });
  });
}
