import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_irc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('TwitchAccount.expired', () {
    test('defaults to false', () {
      final account = TwitchAccount(login: 'test', accessToken: 'tok');
      expect(account.expired, isFalse);
    });

    test('persists through toJson/fromJson', () {
      final account = TwitchAccount(
        login: 'test',
        accessToken: 'tok',
        expired: true,
      );
      final json = account.toJson();
      final restored = TwitchAccount.fromJson(json);
      expect(restored.expired, isTrue);
    });

    test('toJson includes expired key only when true', () {
      final fresh = TwitchAccount(login: 'a', accessToken: 't');
      final expired = TwitchAccount(
        login: 'a',
        accessToken: 't',
        expired: true,
      );
      expect(fresh.toJson(), isNot(contains('expired')));
      expect(expired.toJson(), contains('expired'));
    });
  });

  group('TwitchAuth.markActiveExpired', () {
    test('sets isActiveExpired on named account', () async {
      final auth = TwitchAuth();
      await auth.load();
      auth.accessToken = 'tok';
      auth.login = 'testuser';
      auth.userId = '123';
      auth.accounts = [
        TwitchAccount(login: 'testuser', userId: '123', accessToken: 'tok'),
      ];

      auth.markActiveExpired();
      expect(auth.isActiveExpired, isTrue);
      expect(auth.accounts.first.expired, isTrue);
    });

    test('clears on setCredentials', () async {
      final auth = TwitchAuth();
      await auth.load();
      auth.accessToken = 'tok';
      auth.login = 'testuser';
      auth.accounts = [
        TwitchAccount(login: 'testuser', userId: '123', accessToken: 'tok'),
      ];

      auth.markActiveExpired();
      expect(auth.isActiveExpired, isTrue);

      auth.setCredentials(accessToken: 'new-tok');
      expect(auth.isActiveExpired, isFalse);
    });

    test('no-op when already expired', () async {
      final auth = TwitchAuth();
      await auth.load();
      auth.accessToken = 'tok';
      auth.markActiveExpired();
      // Second call should not throw.
      auth.markActiveExpired();
      expect(auth.isActiveExpired, isTrue);
    });

    test('works for pending token (login null)', () async {
      final auth = TwitchAuth();
      await auth.load();
      auth.accessToken = 'tok';
      auth.login = null;

      auth.markActiveExpired();
      expect(auth.isActiveExpired, isTrue);
    });
  });

  group('TwitchApi.validateToken', () {
    test('returns login/userId/expiresIn on 200', () async {
      final client = MockClient((request) async {
        return http.Response(
          '{"client_id":"cid","login":"testuser","scopes":[],"expires_in":50000,"user_id":"12345"}',
          200,
        );
      });

      final api = TwitchApi(client: client);
      final auth = TwitchAuth();
      auth.accessToken = 'valid-token';

      final result = await api.validateToken(auth);
      expect(result, isNotNull);
      expect(result!.login, 'testuser');
      expect(result.userId, '12345');
      expect(result.expiresIn, 50000);
    });

    test('returns null on 401', () async {
      final client = MockClient((request) async {
        return http.Response(
          '{"status":401,"message":"invalid access token"}',
          401,
        );
      });

      final api = TwitchApi(client: client);
      final auth = TwitchAuth();
      auth.accessToken = 'dead-token';

      final result = await api.validateToken(auth);
      expect(result, isNull);
      expect(api.lastErrorStatus, 401);
    });

    test(
      'returns null on network error without setting lastErrorStatus',
      () async {
        final client = MockClient((request) async {
          throw Exception('network');
        });

        final api = TwitchApi(client: client);
        final auth = TwitchAuth();
        auth.accessToken = 'tok';

        final result = await api.validateToken(auth);
        expect(result, isNull);
        expect(api.lastErrorStatus, isNull);
      },
    );
  });

  group('IrcService auth-failure NOTICE', () {
    test(
      'emits onAuthFailed and signals fatal auth on NOTICE * :Login authentication failed',
      () async {
        final service = IrcService();
        final authFailed = <void>[];
        service.onAuthFailed.listen((_) => authFailed.add(null));

        service.handleLine(
          ':tmi.twitch.tv NOTICE * :Login authentication failed',
        );
        await Future<void>.delayed(Duration.zero);

        expect(authFailed, hasLength(1));
        service.dispose();
      },
    );

    test('does not emit onAuthFailed for channel-scoped NOTICE', () async {
      final service = IrcService();
      final authFailed = <void>[];
      service.onAuthFailed.listen((_) => authFailed.add(null));

      service.handleLine(
        '@msg-id=slow_on :tmi.twitch.tv NOTICE #xqc :This room is now in slow mode.',
      );
      await Future<void>.delayed(Duration.zero);

      expect(authFailed, isEmpty);
      service.dispose();
    });

    test('does not emit onAuthFailed for other NOTICE * messages', () async {
      final service = IrcService();
      final authFailed = <void>[];
      service.onAuthFailed.listen((_) => authFailed.add(null));

      service.handleLine(
        ':tmi.twitch.tv NOTICE * :Some other connection notice',
      );
      await Future<void>.delayed(Duration.zero);

      expect(authFailed, isEmpty);
      service.dispose();
    });
  });
}
