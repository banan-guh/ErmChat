import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ermchat/services/twitch_auth.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('TwitchAuth', () {
    test('isConfigured returns false when no token', () {
      final auth = TwitchAuth();
      expect(auth.isConfigured, isFalse);
    });

    test('isConfigured returns false when accessToken is null', () {
      final auth = TwitchAuth();
      auth.accessToken = null;
      expect(auth.isConfigured, isFalse);
    });

    test('setCredentials persists token', () async {
      final auth = TwitchAuth();
      auth.setCredentials(
        accessToken: 'test_token',
        refreshToken: 'test_refresh',
      );
      expect(auth.accessToken, 'test_token');
      expect(auth.refreshToken, 'test_refresh');
      expect(auth.isConfigured, isTrue);
      expect(auth.hasStoredTokens, isTrue);
    });

    test('clear removes tokens', () async {
      final auth = TwitchAuth();
      auth.setCredentials(
        accessToken: 'test_token',
        refreshToken: 'test_refresh',
      );
      await auth.clear();
      expect(auth.accessToken, isNull);
      expect(auth.refreshToken, isNull);
      expect(auth.isConfigured, isFalse);
      expect(auth.hasStoredTokens, isFalse);
    });

    test('load restores tokens from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'stored_token',
        'refresh_token': 'stored_refresh',
      });
      final auth = TwitchAuth();
      await auth.load();
      expect(auth.accessToken, 'stored_token');
      expect(auth.refreshToken, 'stored_refresh');
      expect(auth.isConfigured, isTrue);
      expect(auth.hasStoredTokens, isTrue);
    });

    test('load handles missing tokens', () async {
      final auth = TwitchAuth();
      await auth.load();
      expect(auth.accessToken, isNull);
      expect(auth.refreshToken, isNull);
    });
  });
}
