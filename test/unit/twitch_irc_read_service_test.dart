import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/services/twitch_irc_read.dart';

void main() {
  late IrcReadService service;

  setUp(() {
    service = IrcReadService();
  });

  tearDown(() {
    service.dispose();
  });

  group('channel tracking', () {
    test('join does not crash when not connected', () {
      expect(() => service.join('testchannel'), returnsNormally);
    });

    test('part does not crash when not connected', () {
      expect(() => service.part('testchannel'), returnsNormally);
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
