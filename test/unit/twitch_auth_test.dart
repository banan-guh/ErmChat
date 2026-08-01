import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ermchat/services/twitch_auth.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
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
    });

    test('load restores tokens from secure storage', () async {
      FlutterSecureStorage.setMockInitialValues({
        'access_token': 'stored_token',
        'refresh_token': 'stored_refresh',
      });
      final auth = TwitchAuth();
      await auth.load();
      expect(auth.accessToken, 'stored_token');
      expect(auth.refreshToken, 'stored_refresh');
      expect(auth.isConfigured, isTrue);
    });

    test('load handles missing tokens', () async {
      final auth = TwitchAuth();
      await auth.load();
      expect(auth.accessToken, isNull);
      expect(auth.refreshToken, isNull);
    });

    test('setUser persists login and user id', () async {
      final auth = TwitchAuth();
      auth.setUser('testuser', '12345');
      expect(auth.login, 'testuser');
      expect(auth.userId, '12345');
    });

    test('load restores cached login and user id', () async {
      FlutterSecureStorage.setMockInitialValues({
        'access_token': 'stored_token',
        'user_login': 'stored_login',
        'user_id': 'stored_id',
      });
      final auth = TwitchAuth();
      await auth.load();
      expect(auth.login, 'stored_login');
      expect(auth.userId, 'stored_id');
    });

    test('setCredentials clears cached login and user id', () async {
      final auth = TwitchAuth();
      auth.setUser('testuser', '12345');
      auth.setCredentials(accessToken: 'new_token');
      expect(auth.login, isNull);
      expect(auth.userId, isNull);
    });

    test('clear removes cached login and user id', () async {
      final auth = TwitchAuth();
      auth.setUser('testuser', '12345');
      await auth.clear();
      expect(auth.login, isNull);
      expect(auth.userId, isNull);
    });
  });
}
