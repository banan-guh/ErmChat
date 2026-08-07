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

  group('createEventSubSubscription', () {
    test(
      'sends POST /helix/eventsub/subscriptions with generic body',
      () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response('Accepted', 202),
        );

        expect(
          await api.createEventSubSubscription(
            auth: auth,
            sessionId: 's1',
            type: 'channel.moderate',
            version: '2',
            condition: {'broadcaster_user_id': 'b1', 'moderator_user_id': 'u1'},
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
        expect(body['type'], 'channel.moderate');
        expect(body['version'], '2');
        expect(body['condition'], {
          'broadcaster_user_id': 'b1',
          'moderator_user_id': 'u1',
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
        await api.createEventSubSubscription(
          auth: auth,
          sessionId: 's1',
          type: 'channel.moderate',
          version: '2',
          condition: {'broadcaster_user_id': 'b1'},
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
        await api.createEventSubSubscription(
          auth: auth,
          sessionId: 's1',
          type: 'channel.moderate',
          version: '2',
          condition: {'broadcaster_user_id': 'b1'},
        ),
        isFalse,
      );
      expect(api.lastError, contains('createEventSubSubscription'));
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

  group('getBlockedUsers', () {
    test('returns null set when no cached userId', () async {
      var called = false;
      final api = TwitchApi(
        client: MockClient((request) async {
          called = true;
          return http.Response('', 500);
        }),
      );

      expect(await api.getBlockedUsers(auth), isEmpty);
      expect(called, isFalse);
    });

    test('follows pagination and lowercases logins', () async {
      final requests = <String>[];
      final api = TwitchApi(
        client: MockClient((request) async {
          requests.add(request.url.toString());
          if (!request.url.queryParameters.containsKey('after')) {
            return http.Response(
              '{"data": [{"user_login": "BADUSER", "user_id": "1"}, '
              '{"user_login": "zuck", "user_id": "2"}], '
              '"pagination": {"cursor": "next-page"}}',
              200,
            );
          }
          return http.Response(
            '{"data": [{"user_login": "another", "user_id": "3"}], '
            '"pagination": {}}',
            200,
          );
        }),
      );
      auth.userId = 'me123';

      final blocked = await api.getBlockedUsers(auth);

      expect(blocked, {'baduser', 'zuck', 'another'});
      expect(requests, hasLength(2));
      expect(requests[0], contains('broadcaster_id=me123'));
      expect(requests[0], contains('first=100'));
      expect(requests[0], isNot(contains('after=')));
      expect(requests[1], contains('after=next-page'));
    });

    test('returns empty set on error', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Unauthorized', 401),
      );
      auth.userId = 'me123';

      expect(await api.getBlockedUsers(auth), isEmpty);
      expect(api.lastError, contains('getBlockedUsers'));
    });
  });

  group('unblockUser', () {
    test('sends DELETE /helix/users/blocks and returns true on 204', () async {
      late http.Request captured;
      final api = createApi((req) => captured = req);

      expect(await api.unblockUser(auth, 'target123'), isTrue);

      expect(captured.method, 'DELETE');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/users/blocks?target_user_id=target123',
      );
      expectAuthHeaders(captured);
    });

    test('returns false on non-204', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Forbidden', 403),
      );

      expect(await api.unblockUser(auth, 'target123'), isFalse);
      expect(api.lastError, contains('unblockUser'));
    });
  });

  group('moderators', () {
    test('getModerators follows pagination and returns logins', () async {
      final requests = <String>[];
      final api = TwitchApi(
        client: MockClient((request) async {
          requests.add(request.url.toString());
          if (!request.url.queryParameters.containsKey('after')) {
            return http.Response(
              '{"data": [{"user_login": "alice"}], '
              '"pagination": {"cursor": "next"}}',
              200,
            );
          }
          return http.Response('{"data": [{"user_login": "bob"}]}', 200);
        }),
      );

      final logins = await api.getModerators(auth, 'b1');

      expect(logins, ['alice', 'bob']);
      expect(requests, hasLength(2));
      expect(requests[0], contains('broadcaster_id=b1'));
    });

    test('addModerator POSTs to /helix/moderation/moderators', () async {
      late http.Request captured;
      final api = createApi((req) => captured = req);

      expect(
        await api.addModerator(auth, broadcasterId: 'b1', userId: 'u1'),
        isTrue,
      );

      expect(captured.method, 'POST');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/moderation/moderators?broadcaster_id=b1&user_id=u1',
      );
    });

    test('removeModerator DELETEs /helix/moderation/moderators', () async {
      late http.Request captured;
      final api = createApi((req) => captured = req);

      expect(
        await api.removeModerator(auth, broadcasterId: 'b1', userId: 'u1'),
        isTrue,
      );

      expect(captured.method, 'DELETE');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/moderation/moderators?broadcaster_id=b1&user_id=u1',
      );
    });
  });

  group('vips', () {
    test('getVips returns logins', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response(
          '{"data": [{"user_login": "alice"}, {"user_login": "bob"}]}',
          200,
        ),
      );

      final logins = await api.getVips(auth, 'b1');

      expect(logins, ['alice', 'bob']);
    });

    test('addVip POSTs to /helix/channels/vips', () async {
      late http.Request captured;
      final api = createApi((req) => captured = req);

      expect(await api.addVip(auth, broadcasterId: 'b1', userId: 'u1'), isTrue);

      expect(captured.method, 'POST');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/channels/vips?broadcaster_id=b1&user_id=u1',
      );
    });

    test('removeVip DELETEs /helix/channels/vips', () async {
      late http.Request captured;
      final api = createApi((req) => captured = req);

      expect(
        await api.removeVip(auth, broadcasterId: 'b1', userId: 'u1'),
        isTrue,
      );

      expect(captured.method, 'DELETE');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/channels/vips?broadcaster_id=b1&user_id=u1',
      );
    });
  });

  group('updateChatSettings', () {
    test('PATCHes /helix/chat/settings with the given body', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response('{"data": []}', 200),
      );

      final ok = await api.updateChatSettings(
        auth,
        broadcasterId: 'b1',
        moderatorId: 'm1',
        body: {'slow_mode': true, 'slow_mode_wait_time': 30},
      );

      expect(ok, isTrue);
      expect(captured.method, 'PATCH');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/chat/settings?broadcaster_id=b1&moderator_id=m1',
      );
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['slow_mode'], isTrue);
      expect(body['slow_mode_wait_time'], 30);
    });

    test('returns false on non-200', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Forbidden', 403),
      );

      final ok = await api.updateChatSettings(
        auth,
        broadcasterId: 'b1',
        moderatorId: 'm1',
        body: {'slow_mode': true},
      );

      expect(ok, isFalse);
      expect(api.lastError, contains('updateChatSettings'));
    });
  });

  group('commercial / raid / shield / marker / whisper', () {
    test(
      'startCommercial POSTs length to /helix/channels/commercial',
      () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response('{"data": []}', 200),
        );

        expect(
          await api.startCommercial(auth, broadcasterId: 'b1', length: 90),
          isTrue,
        );

        expect(captured.method, 'POST');
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/channels/commercial',
        );
        final body = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(body, {'broadcaster_id': 'b1', 'length': 90});
      },
    );

    test('startRaid POSTs to /helix/raids with both broadcaster ids', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response('{"data": []}', 200),
      );

      expect(
        await api.startRaid(
          auth,
          fromBroadcasterId: 'b1',
          toBroadcasterId: 'b2',
        ),
        isTrue,
      );

      expect(captured.method, 'POST');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/raids?from_broadcaster_id=b1&to_broadcaster_id=b2',
      );
    });

    test('cancelRaid DELETEs /helix/raids', () async {
      late http.Request captured;
      final api = createApi((req) => captured = req);

      expect(await api.cancelRaid(auth, broadcasterId: 'b1'), isTrue);

      expect(captured.method, 'DELETE');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/raids?broadcaster_id=b1',
      );
    });

    test(
      'updateShieldMode PUTs is_active to /helix/moderation/shield_mode',
      () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response('{"data": []}', 200),
        );

        expect(
          await api.updateShieldMode(
            auth,
            broadcasterId: 'b1',
            moderatorId: 'm1',
            active: true,
          ),
          isTrue,
        );

        expect(captured.method, 'PUT');
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/moderation/shield_mode?broadcaster_id=b1&moderator_id=m1',
        );
        expect(jsonDecode(captured.body), {'is_active': true});
      },
    );

    test('createMarker POSTs description to /helix/streams/markers', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response('{"data": []}', 200),
      );

      expect(
        await api.createMarker(auth, broadcasterId: 'b1', description: 'clip'),
        isTrue,
      );

      expect(captured.method, 'POST');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/streams/markers',
      );
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body, {'user_id': 'b1', 'description': 'clip'});
    });

    test(
      'sendWhisper POSTs to /helix/whispers with the message body',
      () async {
        late http.Request captured;
        final api = createApi((req) => captured = req);

        expect(
          await api.sendWhisper(
            auth,
            fromUserId: 'f1',
            toUserId: 't1',
            message: 'hello',
          ),
          isTrue,
        );

        expect(captured.method, 'POST');
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/whispers?from_user_id=f1&to_user_id=t1',
        );
        expect(jsonDecode(captured.body), {'message': 'hello'});
      },
    );
  });

  group('error capture', () {
    test('records status and Helix message for failed calls', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response(
          '{"error":"Bad Request","status":400,"message":"The user is not banned in this channel."}',
          400,
        ),
      );

      await api.unbanUser(
        auth,
        broadcasterId: 'b1',
        moderatorId: 'm1',
        userId: 'u1',
      );

      expect(api.lastErrorStatus, 400);
      expect(api.lastHelixMessage, 'The user is not banned in this channel.');
    });
  });
}
