import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_twitch_app/services/twitch_irc.dart';

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

    test('sendMessage with reply parent does not crash', () {
      expect(
        () => service.sendMessage('testchannel', 'hello',
            replyParentMessageId: 'parent-id'),
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
    test('onBan stream can be listened to', () {
      final events = <IrcBanEvent>[];
      service.onBan.listen(events.add);
      expect(events, isEmpty);
    });

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

  group('dispose', () {
    test('dispose does not crash', () {
      expect(() => service.dispose(), returnsNormally);
    });

    test('sendMessage after dispose does not crash', () {
      service.dispose();
      expect(
        () => service.sendMessage('testchannel', 'hello'),
        returnsNormally,
      );
    });

    test('join after dispose does not crash', () {
      service.dispose();
      expect(() => service.join('testchannel'), returnsNormally);
    });

    test('double dispose does not crash', () {
      service.dispose();
      expect(() => service.dispose(), returnsNormally);
    });
  });
}
