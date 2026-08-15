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

    test('setCredentials + setUser registers multiple accounts', () async {
      final auth = TwitchAuth();
      auth.setCredentials(accessToken: 'token_a');
      auth.setUser('alice', '111');
      auth.setCredentials(accessToken: 'token_b');
      auth.setUser('bob', '222');
      expect(auth.accounts.length, 2);
      expect(auth.accounts.map((a) => a.login), containsAll(['alice', 'bob']));
      expect(auth.login, 'bob');
    });

    test('switchTo changes the active account', () async {
      final auth = TwitchAuth();
      auth.setCredentials(accessToken: 'token_a');
      auth.setUser('alice', '111');
      auth.setCredentials(accessToken: 'token_b');
      auth.setUser('bob', '222');

      await auth.switchTo('alice');
      expect(auth.login, 'alice');
      expect(auth.accessToken, 'token_a');
      expect(auth.isConfigured, isTrue);

      await auth.switchTo('bob');
      expect(auth.login, 'bob');
      expect(auth.accessToken, 'token_b');
    });

    test('accounts persist across load with active login', () async {
      final auth = TwitchAuth();
      auth.setCredentials(accessToken: 'token_a');
      auth.setUser('alice', '111');
      auth.setCredentials(accessToken: 'token_b');
      auth.setUser('bob', '222');
      await auth.switchTo('alice');

      final reloaded = TwitchAuth();
      await reloaded.load();
      expect(reloaded.accounts.length, 2);
      expect(reloaded.login, 'alice');
      expect(reloaded.accessToken, 'token_a');
      expect(reloaded.userId, '111');
    });

    test('removeAccount falls back to the next account', () async {
      final auth = TwitchAuth();
      auth.setCredentials(accessToken: 'token_a');
      auth.setUser('alice', '111');
      auth.setCredentials(accessToken: 'token_b');
      auth.setUser('bob', '222');
      await auth.switchTo('alice');

      await auth.removeAccount('alice');
      expect(auth.accounts.length, 1);
      expect(auth.login, 'bob');
      expect(auth.accessToken, 'token_b');
    });

    test('removeAccount of the last account logs out', () async {
      final auth = TwitchAuth();
      auth.setCredentials(accessToken: 'token_a');
      auth.setUser('alice', '111');

      await auth.removeAccount('alice');
      expect(auth.accounts, isEmpty);
      expect(auth.accessToken, isNull);
      expect(auth.login, isNull);
      expect(auth.isConfigured, isFalse);
    });

    test('setUser persists profile image url', () async {
      final auth = TwitchAuth();
      auth.setCredentials(accessToken: 'token_a');
      auth.setUser(
        'alice',
        '111',
        profileImageUrl: 'https://example.com/a.png',
      );
      await auth.switchTo('alice');

      expect(auth.profileImageUrl, 'https://example.com/a.png');
      expect(auth.accounts.single.profileImageUrl, 'https://example.com/a.png');

      final reloaded = TwitchAuth();
      await reloaded.load();
      expect(reloaded.login, 'alice');
      expect(reloaded.profileImageUrl, 'https://example.com/a.png');
    });

    test('clear removes the active account and falls back', () async {
      final auth = TwitchAuth();
      auth.setCredentials(accessToken: 'token_a');
      auth.setUser('alice', '111');
      auth.setCredentials(accessToken: 'token_b');
      auth.setUser('bob', '222');
      await auth.switchTo('alice');

      await auth.clear();
      expect(auth.accounts.length, 1);
      expect(auth.login, 'bob');
      expect(auth.accessToken, 'token_b');
    });
  });
}
