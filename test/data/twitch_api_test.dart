import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/twitch_config.dart';

void main() {
  late TwitchAuth auth;

  setUp(() {
    auth = TwitchAuth();
    auth.accessToken = 'test-token';
  });

  TwitchApi createApi(
    void Function(http.Request request) onRequest, {
    http.Response Function()? respond,
  }) {
    return TwitchApi(
      client: MockClient((request) async {
        onRequest(request);
        return respond?.call() ?? http.Response('', 204);
      }),
    );
  }

  void expectAuthHeaders(http.Request request) {
    expect(request.headers['Client-ID'], TwitchConfig.clientId);
    expect(request.headers['Authorization'], 'Bearer test-token');
    expect(request.headers['Content-Type'], 'application/json');
  }

  group('getUserId', () {
    test('sends GET /helix/users?login= and returns id on 200', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response(
          '{"data": [{"id": "12345", "login": "testuser"}]}',
          200,
        ),
      );

      expect(await api.getUserId(auth, 'testuser'), '12345');

      expect(captured.method, 'GET');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/users?login=testuser',
      );
      expectAuthHeaders(captured);
    });

    test('returns null on non-200', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Not Found', 404),
      );

      expect(await api.getUserId(auth, 'testuser'), isNull);
      expect(api.lastError, contains('getUserId'));
    });

    test('returns null when data list is empty', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('{"data": []}', 200),
      );

      expect(await api.getUserId(auth, 'nonexistent'), isNull);
      expect(api.lastError, contains('not found'));
    });
  });

  group('getCurrentUser', () {
    test('sends GET /helix/users and returns id and login on 200', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response(
          '{"data": [{"id": "1", "login": "currentuser"}]}',
          200,
        ),
      );

      final result = await api.getCurrentUser(auth);
      expect(result, isNotNull);
      expect(result!['id'], '1');
      expect(result['login'], 'currentuser');

      expect(captured.method, 'GET');
      expect(captured.url.toString(), 'https://api.twitch.tv/helix/users');
      expectAuthHeaders(captured);
    });

    test('returns null on non-200', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Unauthorized', 401),
      );

      expect(await api.getCurrentUser(auth), isNull);
      expect(api.lastError, contains('getCurrentUser'));
    });

    test('returns null when data list is empty', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('{"data": []}', 200),
      );

      expect(await api.getCurrentUser(auth), isNull);
      expect(api.lastError, contains('No user associated'));
    });
  });

  group('createSubscription', () {
    test(
      'sends POST /helix/eventsub/subscriptions with chat message body',
      () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response('Accepted', 202),
        );

        expect(
          await api.createSubscription(
            auth: auth,
            sessionId: 's1',
            broadcasterUserId: 'b1',
            userId: 'u1',
          ),
          isTrue,
        );

        expect(captured.method, 'POST');
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/eventsub/subscriptions',
        );
        expectAuthHeaders(captured);
        final body = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(body['type'], 'channel.chat.message');
        expect(body['version'], '1');
        expect(body['condition'], {
          'broadcaster_user_id': 'b1',
          'user_id': 'u1',
        });
        expect(body['transport'], {'method': 'websocket', 'session_id': 's1'});
      },
    );

    test('returns true on 409 (already exists)', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Conflict', 409),
      );

      expect(
        await api.createSubscription(
          auth: auth,
          sessionId: 's1',
          broadcasterUserId: 'b1',
          userId: 'u1',
        ),
        isTrue,
      );
    });

    test('returns false on other HTTP error', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Forbidden', 403),
      );

      expect(
        await api.createSubscription(
          auth: auth,
          sessionId: 's1',
          broadcasterUserId: 'b1',
          userId: 'u1',
        ),
        isFalse,
      );
      expect(api.lastError, contains('createSubscription'));
    });
  });

  group('getUserProfile', () {
    test(
      'sends GET /helix/users?login= and returns profile map on 200',
      () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response(
            '{"data": [{"id": "123", "login": "testuser", "display_name": "TestUser", "created_at": "2020-01-01T00:00:00Z", "profile_image_url": "https://example.com/img.png"}]}',
            200,
          ),
        );

        final result = await api.getUserProfile(auth, 'testuser');
        expect(result, isNotNull);
        expect(result!['id'], '123');
        expect(result['display_name'], 'TestUser');
        expect(result['profile_image_url'], 'https://example.com/img.png');

        expect(captured.method, 'GET');
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/users?login=testuser',
        );
        expectAuthHeaders(captured);
      },
    );

    test('returns null when data list is empty', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('{"data": []}', 200),
      );

      expect(await api.getUserProfile(auth, 'nonexistent'), isNull);
      expect(api.lastError, contains('not found'));
    });

    test('returns null on non-200', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Not Found', 404),
      );

      expect(await api.getUserProfile(auth, 'testuser'), isNull);
      expect(api.lastError, contains('getUserProfile'));
    });
  });

  group('blockUser', () {
    test(
      'sends PUT /helix/users/blocks?target_user_id= and returns true on 204',
      () async {
        late http.Request captured;
        final api = createApi((req) => captured = req);

        expect(await api.blockUser(auth, 'target123'), isTrue);

        expect(captured.method, 'PUT');
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/users/blocks?target_user_id=target123',
        );
        expectAuthHeaders(captured);
      },
    );

    test('returns false on non-204', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Forbidden', 403),
      );

      expect(await api.blockUser(auth, 'target123'), isFalse);
      expect(api.lastError, contains('blockUser'));
    });
  });

  group('sendChatMessage', () {
    test(
      'sends POST /helix/chat/messages with message body and returns id',
      () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response(
            '{"data": [{"message_id": "abc123", "is_sent": true}]}',
            200,
          ),
        );

        final id = await api.sendChatMessage(
          auth,
          broadcasterId: 'b1',
          senderId: 's1',
          message: 'hello chat',
        );
        expect(id, 'abc123');

        expect(captured.method, 'POST');
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/chat/messages',
        );
        expectAuthHeaders(captured);
        final body = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(body, {
          'broadcaster_id': 'b1',
          'sender_id': 's1',
          'message': 'hello chat',
        });
      },
    );

    test('includes reply_parent_message_id when replying', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response(
          '{"data": [{"message_id": "abc123", "is_sent": true}]}',
          200,
        ),
      );

      await api.sendChatMessage(
        auth,
        broadcasterId: 'b1',
        senderId: 's1',
        message: 'reply',
        replyParentMessageId: 'parent1',
      );

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['reply_parent_message_id'], 'parent1');
    });

    test('returns null when message was dropped', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response(
          '{"data": [{"message_id": "abc123", "is_sent": false, "drop_reason": {"code": "BANNED", "message": "banned"}}]}',
          200,
        ),
      );

      expect(
        await api.sendChatMessage(
          auth,
          broadcasterId: 'b1',
          senderId: 's1',
          message: 'hello',
        ),
        isNull,
      );
      expect(api.lastError, contains('dropped'));
    });
  });
}
