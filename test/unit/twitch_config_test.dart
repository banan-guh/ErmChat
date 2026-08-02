import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/twitch_config.dart';

void main() {
  group('TwitchConfig', () {
    test('isConfigured returns true with a real client ID', () {
      expect(TwitchConfig.isConfigured, isTrue);
    });
  });
}
