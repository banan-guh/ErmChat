import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ermchat/services/command_handler.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/services/twitch_irc.dart';

class _RecordingIrcService extends IrcService {
  final sent = <String>[];
  bool connected = true;

  @override
  bool get isConnected => connected;

  @override
  void sendMessage(
    String channelName,
    String text, {
    String? replyParentMessageId,
  }) {
    sent.add(text);
  }
}

void main() {
  late TwitchAuth auth;
  late _RecordingIrcService irc;
  final systemMessages = <String>[];

  setUp(() {
    auth = TwitchAuth();
    auth.accessToken = 'test-token';
    irc = _RecordingIrcService();
    systemMessages.clear();
  });

  tearDown(() {
    irc.dispose();
  });

  CommandHandler createHandler(MockClient client) {
    return CommandHandler(
      twitchApi: TwitchApi(client: client),
      irc: irc,
      getChannelUserIds: () => {'a': '111'},
      getCurrentUserId: () => '222',
      getCurrentUserLogin: () => 'me',
      addSystemMessage: (channel, message) {
        systemMessages.add(message);
      },
    );
  }

  http.Response userFound() =>
      http.Response('{"data":[{"id":"999","login":"foo"}]}', 200);

  http.Response userMissing() => http.Response('{"data":[]}', 200);

  test(
    '/ban success via Helix shows confirmation and does not touch IRC',
    () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('', 200);
        }),
      );

      await handler.handle('/ban foo spamming', 'a', auth);

      expect(systemMessages, ['foo has been banned.']);
      expect(irc.sent, isEmpty);
      final banReq = requests.firstWhere(
        (r) => r.url.path == '/helix/moderation/bans',
      );
      expect(banReq.method, 'POST');
      expect(banReq.url.queryParameters['broadcaster_id'], '111');
      expect(banReq.url.queryParameters['moderator_id'], '222');
      final body = jsonDecode(banReq.body) as Map;
      expect((body['data'] as Map)['user_id'], '999');
      expect((body['data'] as Map)['reason'], 'spamming');
      expect(body['data'].containsKey('duration'), isFalse);
    },
  );

  test(
    '/ban reports failure without IRC fallback on 401 (missing scopes)',
    () async {
      final handler = createHandler(
        MockClient((req) async {
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('Missing scope', 401);
        }),
      );

      await handler.handle('/ban foo', 'a', auth);

      expect(irc.sent, isEmpty);
      expect(
        systemMessages.single,
        startsWith('Command failed: banUser failed (401)'),
      );
    },
  );

  test('/ban reports failure when Helix throws a network error', () async {
    final handler = createHandler(
      MockClient((req) async {
        if (req.url.path == '/helix/users') return userFound();
        throw http.ClientException('connection reset');
      }),
    );

    await handler.handle('/ban foo', 'a', auth);

    expect(irc.sent, isEmpty);
    expect(systemMessages.single, startsWith('Command failed:'));
  });

  test(
    '/ban reports failure when Helix fails and IRC is disconnected',
    () async {
      irc.connected = false;
      final handler = createHandler(
        MockClient((req) async {
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('Missing scope', 401);
        }),
      );

      await handler.handle('/ban foo', 'a', auth);

      expect(irc.sent, isEmpty);
      expect(
        systemMessages.single,
        startsWith('Command failed: banUser failed (401)'),
      );
    },
  );

  test('/ban with no args shows usage', () async {
    final handler = createHandler(
      MockClient((req) async => http.Response('', 200)),
    );
    await handler.handle('/ban', 'a', auth);
    expect(systemMessages, ['Usage: /ban <username> [reason]']);
  });

  test('/ban unknown user shows not found and does not fall back', () async {
    final handler = createHandler(
      MockClient((req) async {
        if (req.url.path == '/helix/users') return userMissing();
        return http.Response('', 200);
      }),
    );

    await handler.handle('/ban ghost', 'a', auth);

    expect(systemMessages, ['User "ghost" not found.']);
    expect(irc.sent, isEmpty);
  });

  test('/timeout with explicit duration and reason', () async {
    final requests = <http.Request>[];
    final handler = createHandler(
      MockClient((req) async {
        requests.add(req);
        if (req.url.path == '/helix/users') return userFound();
        return http.Response('', 200);
      }),
    );

    await handler.handle('/timeout foo 30 being rude', 'a', auth);

    expect(systemMessages, ['foo timed out for 30s.']);
    final body =
        jsonDecode(
              requests
                  .firstWhere((r) => r.url.path == '/helix/moderation/bans')
                  .body,
            )
            as Map;
    expect((body['data'] as Map)['duration'], '30');
    expect((body['data'] as Map)['reason'], 'being rude');
  });

  test('/timeout defaults to 600s when duration omitted', () async {
    final requests = <http.Request>[];
    final handler = createHandler(
      MockClient((req) async {
        requests.add(req);
        if (req.url.path == '/helix/users') return userFound();
        return http.Response('', 200);
      }),
    );

    await handler.handle('/timeout foo', 'a', auth);

    expect(systemMessages, ['foo timed out for 600s.']);
    final body =
        jsonDecode(
              requests
                  .firstWhere((r) => r.url.path == '/helix/moderation/bans')
                  .body,
            )
            as Map;
    expect((body['data'] as Map)['duration'], '600');
  });

  test('/timeout treats non-numeric second arg as reason', () async {
    final requests = <http.Request>[];
    final handler = createHandler(
      MockClient((req) async {
        requests.add(req);
        if (req.url.path == '/helix/users') return userFound();
        return http.Response('', 200);
      }),
    );

    await handler.handle('/timeout foo stop it', 'a', auth);

    final body =
        jsonDecode(
              requests
                  .firstWhere((r) => r.url.path == '/helix/moderation/bans')
                  .body,
            )
            as Map;
    expect((body['data'] as Map)['duration'], '600');
    expect((body['data'] as Map)['reason'], 'stop it');
  });

  test('/unban success deletes the ban', () async {
    final requests = <http.Request>[];
    final handler = createHandler(
      MockClient((req) async {
        requests.add(req);
        if (req.url.path == '/helix/users') return userFound();
        return http.Response('', 204);
      }),
    );

    await handler.handle('/unban foo', 'a', auth);

    expect(systemMessages, ['foo has been unbanned.']);
    final req = requests.firstWhere(
      (r) => r.url.path == '/helix/moderation/bans',
    );
    expect(req.method, 'DELETE');
    expect(req.url.queryParameters['user_id'], '999');
  });

  test('/unban reports failure without IRC fallback', () async {
    final handler = createHandler(
      MockClient((req) async {
        if (req.url.path == '/helix/users') return userFound();
        return http.Response('Forbidden', 403);
      }),
    );

    await handler.handle('/unban foo', 'a', auth);

    expect(irc.sent, isEmpty);
    expect(
      systemMessages.single,
      startsWith('Command failed: unbanUser failed (403)'),
    );
  });

  test('/delete success targets the message id', () async {
    final requests = <http.Request>[];
    final handler = createHandler(
      MockClient((req) async {
        requests.add(req);
        return http.Response('', 204);
      }),
    );

    await handler.handle('/delete abc123', 'a', auth);

    expect(systemMessages, ['Message deleted.']);
    final req = requests.single;
    expect(req.method, 'DELETE');
    expect(req.url.path, '/helix/moderation/chat');
    expect(req.url.queryParameters['message_id'], 'abc123');
  });

  test('/delete reports failure without IRC fallback', () async {
    final handler = createHandler(
      MockClient((req) async => http.Response('Bad Request', 400)),
    );

    await handler.handle('/delete abc123', 'a', auth);

    expect(irc.sent, isEmpty);
    expect(
      systemMessages.single,
      startsWith('Command failed: deleteChatMessage failed (400)'),
    );
  });

  test('/clear success omits message_id', () async {
    final requests = <http.Request>[];
    final handler = createHandler(
      MockClient((req) async {
        requests.add(req);
        return http.Response('', 204);
      }),
    );

    await handler.handle('/clear', 'a', auth);

    expect(systemMessages, ['Chat cleared.']);
    final req = requests.single;
    expect(req.method, 'DELETE');
    expect(req.url.queryParameters.containsKey('message_id'), isFalse);
  });

  test('/clear reports failure without IRC fallback', () async {
    final handler = createHandler(
      MockClient((req) async => http.Response('Unauthorized', 401)),
    );

    await handler.handle('/clear', 'a', auth);

    expect(irc.sent, isEmpty);
    expect(
      systemMessages.single,
      startsWith('Command failed: deleteChatMessage failed (401)'),
    );
  });

  test('/announce posts the message', () async {
    final requests = <http.Request>[];
    final handler = createHandler(
      MockClient((req) async {
        requests.add(req);
        return http.Response('', 204);
      }),
    );

    await handler.handle('/announce hello world', 'a', auth);

    expect(systemMessages, isEmpty);
    final req = requests.single;
    expect(req.url.path, '/helix/chat/announcements');
    final body = jsonDecode(req.body) as Map;
    expect(body['message'], 'hello world');
  });

  test('/announce shows error on failure', () async {
    final handler = createHandler(
      MockClient((req) async => http.Response('Forbidden', 403)),
    );

    await handler.handle('/announce hi', 'a', auth);

    expect(
      systemMessages.single,
      startsWith('Failed to announce: sendChatAnnouncement failed (403)'),
    );
  });

  test('/shoutout targets the resolved user', () async {
    final requests = <http.Request>[];
    final handler = createHandler(
      MockClient((req) async {
        requests.add(req);
        if (req.url.path == '/helix/users') return userFound();
        return http.Response('', 200);
      }),
    );

    await handler.handle('/shoutout foo', 'a', auth);

    expect(systemMessages, isEmpty);
    final req = requests.firstWhere(
      (r) => r.url.path == '/helix/chat/shoutouts',
    );
    final body = jsonDecode(req.body) as Map;
    expect(body['from_broadcaster_id'], '111');
    expect(body['to_broadcaster_id'], '999');
    expect(body['moderator_id'], '222');
  });

  test('/color success confirms the change', () async {
    final requests = <http.Request>[];
    final handler = createHandler(
      MockClient((req) async {
        requests.add(req);
        return http.Response('', 204);
      }),
    );

    await handler.handle('/color red', 'a', auth);

    expect(systemMessages, ['Your color has been changed to red']);
    final req = requests.single;
    expect(req.method, 'PUT');
    expect(req.url.path, '/helix/chat/color');
    expect(req.url.queryParameters['color'], 'red');
  });

  test('/color with no args shows usage', () async {
    final handler = createHandler(
      MockClient((req) async => http.Response('', 204)),
    );
    await handler.handle('/color', 'a', auth);
    expect(systemMessages.single, startsWith('Usage: /color'));
  });

  test('unknown command shows error', () async {
    final handler = createHandler(
      MockClient((req) async => http.Response('', 200)),
    );
    await handler.handle('/foo bar', 'a', auth);
    expect(systemMessages, ['Unknown command: /foo']);
  });

  test('unauthenticated user is blocked before any HTTP call', () async {
    auth.accessToken = null;
    var calls = 0;
    final handler = createHandler(
      MockClient((req) async {
        calls++;
        return http.Response('', 200);
      }),
    );

    await handler.handle('/ban foo', 'a', auth);

    expect(calls, 0);
    expect(systemMessages, ['Not authenticated or channel not joined.']);
    expect(irc.sent, isEmpty);
  });

  test('/me sends raw text over IRC without HTTP', () async {
    var calls = 0;
    final handler = createHandler(
      MockClient((req) async {
        calls++;
        return http.Response('', 200);
      }),
    );

    await handler.handle('/me dances', 'a', auth);

    expect(irc.sent, ['/me dances']);
    expect(calls, 0);
  });
}
