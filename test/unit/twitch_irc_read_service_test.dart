import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_twitch_app/services/twitch_irc_read.dart';
import 'package:flutter_twitch_app/services/twitch_irc.dart';

void main() {
  late IrcReadService service;

  setUp(() {
    service = IrcReadService();
  });

  tearDown(() {
    service.dispose();
  });

  group('initial state', () {
    test('isConnected is false', () {
      expect(service.isConnected, false);
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
    test('onOwnMessage stream can be listened to', () {
      final events = <IrcMessage>[];
      service.onOwnMessage.listen(events.add);
      expect(events, isEmpty);
    });

    test('onUserColor stream can be listened to', () {
      final colors = <String>[];
      service.onUserColor.listen(colors.add);
      expect(colors, isEmpty);
    });
  });

  group('dispose', () {
    test('dispose does not crash', () {
      expect(() => service.dispose(), returnsNormally);
    });

    test('join after dispose does not crash', () {
      service.dispose();
      expect(() => service.join('testchannel'), returnsNormally);
    });

    test('part after dispose does not crash', () {
      service.dispose();
      expect(() => service.part('testchannel'), returnsNormally);
    });

    test('double dispose does not crash', () {
      service.dispose();
      expect(() => service.dispose(), returnsNormally);
    });
  });
}
