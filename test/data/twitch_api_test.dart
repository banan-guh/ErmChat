import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';

void main() {
  late TwitchAuth auth;

  setUp(() {
    auth = TwitchAuth();
    auth.accessToken = 'test-token';
  });

  tearDown(() {
    TwitchApi.client = http.Client();
  });

  group('getUserId', () {
    test('returns user id on 200 with data', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response(
          '{"data": [{"id": "12345", "login": "testuser"}]}',
          200,
        ),
      );

      expect(await TwitchApi.getUserId(auth, 'testuser'), '12345');
    });

    test('returns null on non-200', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response('Not Found', 404),
      );

      expect(await TwitchApi.getUserId(auth, 'testuser'), isNull);
      expect(TwitchApi.lastError, contains('getUserId'));
    });

    test('returns null when data list is empty', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response('{"data": []}', 200),
      );

      expect(await TwitchApi.getUserId(auth, 'nonexistent'), isNull);
      expect(TwitchApi.lastError, contains('not found'));
    });
  });

  group('getCurrentUser', () {
    test('returns id and login on 200 with data', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response(
          '{"data": [{"id": "1", "login": "currentuser"}]}',
          200,
        ),
      );

      final result = await TwitchApi.getCurrentUser(auth);
      expect(result, isNotNull);
      expect(result!['id'], '1');
      expect(result['login'], 'currentuser');
    });

    test('returns null on non-200', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response('Unauthorized', 401),
      );

      expect(await TwitchApi.getCurrentUser(auth), isNull);
      expect(TwitchApi.lastError, contains('getCurrentUser'));
    });

    test('returns null when data list is empty', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response('{"data": []}', 200),
      );

      expect(await TwitchApi.getCurrentUser(auth), isNull);
      expect(TwitchApi.lastError, contains('No user associated'));
    });
  });

  group('createSubscription', () {
    test('returns true on 202', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response('Accepted', 202),
      );

      expect(
        await TwitchApi.createSubscription(
          auth: auth,
          sessionId: 's1',
          broadcasterUserId: 'b1',
          userId: 'u1',
        ),
        isTrue,
      );
    });

    test('returns true on 409 (already exists)', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response('Conflict', 409),
      );

      expect(
        await TwitchApi.createSubscription(
          auth: auth,
          sessionId: 's1',
          broadcasterUserId: 'b1',
          userId: 'u1',
        ),
        isTrue,
      );
    });

    test('returns false on other HTTP error', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response('Forbidden', 403),
      );

      expect(
        await TwitchApi.createSubscription(
          auth: auth,
          sessionId: 's1',
          broadcasterUserId: 'b1',
          userId: 'u1',
        ),
        isFalse,
      );
      expect(TwitchApi.lastError, contains('createSubscription'));
    });
  });

  group('createDeleteSubscription', () {
    test('returns true on 202', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response('Accepted', 202),
      );

      expect(
        await TwitchApi.createDeleteSubscription(
          auth: auth,
          sessionId: 's1',
          broadcasterUserId: 'b1',
          userId: 'u1',
        ),
        isTrue,
      );
    });

    test('returns true on 409 (already exists)', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response('Conflict', 409),
      );

      expect(
        await TwitchApi.createDeleteSubscription(
          auth: auth,
          sessionId: 's1',
          broadcasterUserId: 'b1',
          userId: 'u1',
        ),
        isTrue,
      );
    });

    test('returns false on other HTTP error', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response('Forbidden', 403),
      );

      expect(
        await TwitchApi.createDeleteSubscription(
          auth: auth,
          sessionId: 's1',
          broadcasterUserId: 'b1',
          userId: 'u1',
        ),
        isFalse,
      );
      expect(TwitchApi.lastError, contains('createDeleteSubscription'));
    });
  });

  group('getUserProfile', () {
    test('returns profile map on 200 with data', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response(
          '{"data": [{"id": "123", "login": "testuser", "display_name": "TestUser", "created_at": "2020-01-01T00:00:00Z", "profile_image_url": "https://example.com/img.png"}]}',
          200,
        ),
      );

      final result = await TwitchApi.getUserProfile(auth, 'testuser');
      expect(result, isNotNull);
      expect(result!['id'], '123');
      expect(result['display_name'], 'TestUser');
      expect(result['profile_image_url'], 'https://example.com/img.png');
    });

    test('returns null when data list is empty', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response('{"data": []}', 200),
      );

      expect(await TwitchApi.getUserProfile(auth, 'nonexistent'), isNull);
      expect(TwitchApi.lastError, contains('not found'));
    });

    test('returns null on non-200', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response('Not Found', 404),
      );

      expect(await TwitchApi.getUserProfile(auth, 'testuser'), isNull);
      expect(TwitchApi.lastError, contains('getUserProfile'));
    });
  });

  group('blockUser', () {
    test('returns true on 204', () async {
      TwitchApi.client = MockClient((_) async => http.Response('', 204));

      expect(await TwitchApi.blockUser(auth, 'target123'), isTrue);
    });

    test('returns false on non-204', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response('Forbidden', 403),
      );

      expect(await TwitchApi.blockUser(auth, 'target123'), isFalse);
      expect(TwitchApi.lastError, contains('blockUser'));
    });
  });

  group('reportUser', () {
    test('returns true on 204', () async {
      TwitchApi.client = MockClient((_) async => http.Response('', 204));

      expect(
        await TwitchApi.reportUser(
          auth,
          userId: 'u1',
          broadcasterId: 'b1',
          reason: 'spam',
        ),
        isTrue,
      );
    });

    test('returns false on non-204', () async {
      TwitchApi.client = MockClient(
        (_) async => http.Response('Bad Request', 400),
      );

      expect(
        await TwitchApi.reportUser(auth, userId: 'u1', broadcasterId: 'b1'),
        isFalse,
      );
      expect(TwitchApi.lastError, contains('reportUser'));
    });
  });
}
