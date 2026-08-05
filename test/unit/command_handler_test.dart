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

  @override
  bool get isConnected => true;

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
  final blocked = <String>[];
  final unblocked = <String>[];

  setUp(() {
    auth = TwitchAuth();
    auth.accessToken = 'test-token';
    irc = _RecordingIrcService();
    systemMessages.clear();
    blocked.clear();
    unblocked.clear();
  });

  tearDown(() {
    irc.dispose();
  });

  CommandHandler createHandler(MockClient client, {bool trackBlocks = false}) {
    return CommandHandler(
      twitchApi: TwitchApi(client: client),
      irc: irc,
      getChannelUserIds: () => {'a': '111'},
      getCurrentUserId: () => '222',
      getCurrentUserLogin: () => 'me',
      addSystemMessage: (channel, message) {
        systemMessages.add(message);
      },
      onUserBlocked: trackBlocks ? blocked.add : null,
      onUserUnblocked: trackBlocks ? unblocked.add : null,
    );
  }

  http.Response userFound() =>
      http.Response('{"data":[{"id":"999","login":"foo"}]}', 200);

  http.Response userMissing() => http.Response('{"data":[]}', 200);

  group('ban / timeout / unban', () {
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

    test('/ban reports failure on 401 (missing scopes)', () async {
      final handler = createHandler(
        MockClient((req) async {
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('{"message":"Missing scope"}', 401);
        }),
      );

      await handler.handle('/ban foo', 'a', auth);

      expect(irc.sent, isEmpty);
      expect(
        systemMessages.single,
        'Failed to ban user - Missing required scope. Re-login with your account and try again.',
      );
    });

    test('/ban reports failure when Helix throws a network error', () async {
      final handler = createHandler(
        MockClient((req) async {
          if (req.url.path == '/helix/users') return userFound();
          throw http.ClientException('connection reset');
        }),
      );

      await handler.handle('/ban foo', 'a', auth);

      expect(irc.sent, isEmpty);
      expect(
        systemMessages.single,
        'Failed to ban user - An unknown error has occurred.',
      );
    });

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

      expect(systemMessages, ['No user matching that username.']);
      expect(irc.sent, isEmpty);
    });

    test('/ban cannot target yourself', () async {
      final handler = createHandler(
        MockClient(
          (req) async =>
              http.Response('{"data":[{"id":"222","login":"me"}]}', 200),
        ),
      );
      await handler.handle('/ban me', 'a', auth);
      expect(systemMessages, ['Failed to ban user - You cannot ban yourself.']);
    });

    test('/ban cannot target the broadcaster', () async {
      final handler = createHandler(
        MockClient(
          (req) async => http.Response(
            '{"data":[{"id":"111","login":"broadcaster"}]}',
            200,
          ),
        ),
      );
      await handler.handle('/ban broadcaster', 'a', auth);
      expect(systemMessages, [
        'Failed to ban user - You cannot ban the broadcaster.',
      ]);
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

    test('/timeout accepts DankChat-style unit durations', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('', 200);
        }),
      );

      await handler.handle('/timeout foo 2m30s', 'a', auth);

      final body =
          jsonDecode(
                requests
                    .firstWhere((r) => r.url.path == '/helix/moderation/bans')
                    .body,
              )
              as Map;
      expect((body['data'] as Map)['duration'], '150');
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

    test('/untimeout is an alias for /unban', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('', 204);
        }),
      );

      await handler.handle('/untimeout foo', 'a', auth);

      expect(systemMessages, ['foo has been unbanned.']);
      expect(
        requests.any((r) => r.url.path == '/helix/moderation/bans'),
        isTrue,
      );
    });

    test('/unban reports failure on 403', () async {
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
        "Failed to unban user - You don't have permission to perform that action.",
      );
    });
  });

  group('delete / clear', () {
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
        'Failed to delete chat messages - An unknown error has occurred.',
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

    test('/clear reports failure on 401', () async {
      final handler = createHandler(
        MockClient((req) async => http.Response('Unauthorized', 401)),
      );

      await handler.handle('/clear', 'a', auth);

      expect(irc.sent, isEmpty);
      expect(
        systemMessages.single,
        'Failed to delete chat messages - Missing required scope. Re-login with your account and try again.',
      );
    });
  });

  group('announce', () {
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
      expect(body['color'], 'primary');
    });

    test('/announce accepts a color argument', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          return http.Response('', 204);
        }),
      );

      await handler.handle('/announce blue hello world', 'a', auth);

      final body = jsonDecode(requests.single.body) as Map;
      expect(body['color'], 'blue');
      expect(body['message'], 'hello world');
    });

    test('/announce rejects a bare color argument', () async {
      final handler = createHandler(
        MockClient((req) async => http.Response('', 204)),
      );

      await handler.handle('/announce blue', 'a', auth);

      expect(systemMessages.single, 'Usage: /announce [color] <message>');
    });

    test('/announceblue posts with the blue color', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          return http.Response('', 204);
        }),
      );

      await handler.handle('/announceblue hello', 'a', auth);

      final body = jsonDecode(requests.single.body) as Map;
      expect(body['color'], 'blue');
      expect(body['message'], 'hello');
    });

    test('/announce shows error on failure', () async {
      final handler = createHandler(
        MockClient((req) async => http.Response('Forbidden', 403)),
      );

      await handler.handle('/announce hi', 'a', auth);

      expect(
        systemMessages.single,
        "Failed to send announcement - You don't have permission to perform that action.",
      );
    });
  });

  group('shoutout / color', () {
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

      expect(systemMessages, ['Sent shoutout to foo']);
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
  });

  group('mod / vip', () {
    test('/mod adds a moderator', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('', 204);
        }),
      );

      await handler.handle('/mod foo', 'a', auth);

      expect(systemMessages, [
        'You have added foo as a moderator of this channel.',
      ]);
      final req = requests.firstWhere(
        (r) => r.url.path == '/helix/moderation/moderators',
      );
      expect(req.method, 'POST');
      expect(req.url.queryParameters['broadcaster_id'], '111');
      expect(req.url.queryParameters['user_id'], '999');
    });

    test('/unmod removes a moderator', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('', 204);
        }),
      );

      await handler.handle('/unmod foo', 'a', auth);

      expect(systemMessages, [
        'You have removed foo as a moderator of this channel.',
      ]);
      final req = requests.firstWhere(
        (r) => r.url.path == '/helix/moderation/moderators',
      );
      expect(req.method, 'DELETE');
    });

    test('/mod lists the channel moderators', () async {
      final handler = createHandler(
        MockClient(
          (req) async => http.Response(
            '{"data":[{"user_login":"alice"},{"user_login":"bob"}]}',
            200,
          ),
        ),
      );

      await handler.handle('/mods', 'a', auth);

      expect(systemMessages, [
        'The moderators of this channel are alice, bob.',
      ]);
    });

    test('/mods reports when there are none', () async {
      final handler = createHandler(
        MockClient((req) async => http.Response('{"data":[]}', 200)),
      );

      await handler.handle('/mods', 'a', auth);

      expect(systemMessages, ['This channel does not have any moderators.']);
    });

    test('/vip adds a VIP', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('', 204);
        }),
      );

      await handler.handle('/vip foo', 'a', auth);

      expect(systemMessages, ['You have added foo as a VIP of this channel.']);
      final req = requests.firstWhere(
        (r) => r.url.path == '/helix/channels/vips',
      );
      expect(req.method, 'POST');
      expect(req.url.queryParameters['user_id'], '999');
    });

    test('/unvip removes a VIP', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('', 204);
        }),
      );

      await handler.handle('/unvip foo', 'a', auth);

      expect(systemMessages, [
        'You have removed foo as a VIP of this channel.',
      ]);
      final req = requests.firstWhere(
        (r) => r.url.path == '/helix/channels/vips',
      );
      expect(req.method, 'DELETE');
    });

    test('/vips lists the channel VIPs', () async {
      final handler = createHandler(
        MockClient(
          (req) async =>
              http.Response('{"data":[{"user_login":"alice"}]}', 200),
        ),
      );

      await handler.handle('/vips', 'a', auth);

      expect(systemMessages, ['The VIPs of this channel are alice.']);
    });
  });

  group('chat modes', () {
    test('/slow defaults to 30 seconds', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          return http.Response('', 200);
        }),
      );

      await handler.handle('/slow', 'a', auth);

      expect(systemMessages, ['Slow mode enabled (30s).']);
      final body = jsonDecode(requests.single.body) as Map;
      expect(body['slow_mode'], isTrue);
      expect(body['slow_mode_wait_time'], 30);
    });

    test('/slow accepts a custom duration', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          return http.Response('', 200);
        }),
      );

      await handler.handle('/slow 120', 'a', auth);

      final body = jsonDecode(requests.single.body) as Map;
      expect(body['slow_mode_wait_time'], 120);
    });

    test('/slow rejects out-of-range durations', () async {
      var calls = 0;
      final handler = createHandler(
        MockClient((req) async {
          calls++;
          return http.Response('', 200);
        }),
      );

      await handler.handle('/slow 999', 'a', auth);

      expect(calls, 0);
      expect(systemMessages.single, startsWith('Usage: /slow'));
    });

    test('/slowoff disables slow mode', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          return http.Response('', 200);
        }),
      );

      await handler.handle('/slowoff', 'a', auth);

      expect(systemMessages, ['Slow mode disabled.']);
      expect(jsonDecode(requests.single.body)['slow_mode'], isFalse);
    });

    test('/followers enables followers-only mode with unit duration', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          return http.Response('', 200);
        }),
      );

      await handler.handle('/followers 1h', 'a', auth);

      expect(systemMessages, ['Followers-only mode enabled.']);
      final body = jsonDecode(requests.single.body) as Map;
      expect(body['follower_mode'], isTrue);
      expect(body['follower_mode_duration'], 60);
    });

    test('/followersoff disables followers-only mode', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          return http.Response('', 200);
        }),
      );

      await handler.handle('/followersoff', 'a', auth);

      expect(systemMessages, ['Followers-only mode disabled.']);
      expect(jsonDecode(requests.single.body)['follower_mode'], isFalse);
    });

    test('/emoteonly and /emoteonlyoff toggle emote mode', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          return http.Response('', 200);
        }),
      );

      await handler.handle('/emoteonly', 'a', auth);
      expect(systemMessages, ['Emote-only mode enabled.']);
      expect(jsonDecode(requests.single.body)['emote_mode'], isTrue);

      systemMessages.clear();
      requests.clear();
      await handler.handle('/emoteonlyoff', 'a', auth);
      expect(systemMessages, ['Emote-only mode disabled.']);
      expect(jsonDecode(requests.single.body)['emote_mode'], isFalse);
    });

    test('/subscribers toggles subscriber mode', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          return http.Response('', 200);
        }),
      );

      await handler.handle('/subscribers', 'a', auth);
      expect(jsonDecode(requests.single.body)['subscriber_mode'], isTrue);
    });

    test('/r9kbeta and /uniquechat enable unique chat mode', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          return http.Response('', 200);
        }),
      );

      await handler.handle('/r9kbeta', 'a', auth);
      expect(systemMessages, ['Unique-chat mode enabled.']);
      expect(jsonDecode(requests.single.body)['unique_chat_mode'], isTrue);

      systemMessages.clear();
      requests.clear();
      await handler.handle('/uniquechatoff', 'a', auth);
      expect(systemMessages, ['Unique-chat mode disabled.']);
      expect(jsonDecode(requests.single.body)['unique_chat_mode'], isFalse);
    });

    test('chat mode failure shows a clean notice', () async {
      final handler = createHandler(
        MockClient((req) async => http.Response('Forbidden', 403)),
      );

      await handler.handle('/slowoff', 'a', auth);

      expect(
        systemMessages.single,
        "Failed to update chat settings - You don't have permission to perform that action.",
      );
    });
  });

  group('broadcaster actions', () {
    test('/commercial starts a commercial of the requested length', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          return http.Response('{"data":[{"length":90}]}', 200);
        }),
      );

      await handler.handle('/commercial 90', 'a', auth);

      expect(systemMessages, ['Starting 90 second long commercial break.']);
      final body = jsonDecode(requests.single.body) as Map;
      expect(body['broadcaster_id'], '111');
      expect(body['length'], 90);
    });

    test('/commercial rejects invalid lengths', () async {
      var calls = 0;
      final handler = createHandler(
        MockClient((req) async {
          calls++;
          return http.Response('', 200);
        }),
      );

      await handler.handle('/commercial 45', 'a', auth);

      expect(calls, 0);
      expect(systemMessages.single, startsWith('Usage: /commercial'));
    });

    test('/raid starts a raid to the resolved user', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('{"data":[]}', 200);
        }),
      );

      await handler.handle('/raid foo', 'a', auth);

      expect(systemMessages, ['You started to raid foo.']);
      final req = requests.firstWhere((r) => r.url.path == '/helix/raids');
      expect(req.method, 'POST');
      expect(req.url.queryParameters['from_broadcaster_id'], '111');
      expect(req.url.queryParameters['to_broadcaster_id'], '999');
    });

    test('/unraid cancels the raid', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          return http.Response('', 204);
        }),
      );

      await handler.handle('/unraid', 'a', auth);

      expect(systemMessages, ['You cancelled the raid.']);
      final req = requests.single;
      expect(req.method, 'DELETE');
      expect(req.url.path, '/helix/raids');
    });

    test('/shield activates and /shieldoff deactivates shield mode', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          return http.Response('{"data":[]}', 200);
        }),
      );

      await handler.handle('/shield', 'a', auth);
      expect(systemMessages, ['Shield mode was activated.']);
      var req = requests.single;
      expect(req.method, 'PUT');
      expect(req.url.path, '/helix/moderation/shield_mode');
      expect(jsonDecode(req.body)['is_active'], isTrue);

      systemMessages.clear();
      requests.clear();
      await handler.handle('/shieldoff', 'a', auth);
      expect(systemMessages, ['Shield mode was deactivated.']);
      expect(jsonDecode(requests.single.body)['is_active'], isFalse);
    });

    test('/marker creates a stream marker', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          return http.Response('{"data":[]}', 200);
        }),
      );

      await handler.handle('/marker clip this', 'a', auth);

      expect(systemMessages, ['Stream marker added.']);
      final body = jsonDecode(requests.single.body) as Map;
      expect(body['user_id'], '111');
      expect(body['description'], 'clip this');
    });
  });

  group('whisper / block', () {
    test('/w sends a whisper', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('', 204);
        }),
      );

      await handler.handle('/w foo hey there', 'a', auth);

      expect(systemMessages, ['Whisper sent.']);
      final req = requests.firstWhere((r) => r.url.path == '/helix/whispers');
      expect(req.method, 'POST');
      expect(req.url.queryParameters['from_user_id'], '222');
      expect(req.url.queryParameters['to_user_id'], '999');
      expect(jsonDecode(req.body)['message'], 'hey there');
    });

    test('/w with a missing message shows usage', () async {
      var calls = 0;
      final handler = createHandler(
        MockClient((req) async {
          calls++;
          return http.Response('', 200);
        }),
      );

      await handler.handle('/w foo', 'a', auth);

      expect(calls, 0);
      expect(systemMessages.single, 'Usage: /w <username> <message>');
    });

    test('/block blocks the user and reports the local list', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('', 204);
        }),
        trackBlocks: true,
      );

      await handler.handle('/block Foo', 'a', auth);

      expect(systemMessages, ['You successfully blocked user Foo']);
      expect(blocked, ['foo']);
      final req = requests.firstWhere(
        (r) => r.url.path == '/helix/users/blocks',
      );
      expect(req.method, 'PUT');
      expect(req.url.queryParameters['target_user_id'], '999');
    });

    test('/unblock unblocks the user and reports the local list', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('', 204);
        }),
        trackBlocks: true,
      );

      await handler.handle('/unblock foo', 'a', auth);

      expect(systemMessages, ['You successfully unblocked user foo']);
      expect(unblocked, ['foo']);
      final req = requests.firstWhere(
        (r) => r.url.path == '/helix/users/blocks',
      );
      expect(req.method, 'DELETE');
    });

    test('/block reports failure with a clean notice', () async {
      final handler = createHandler(
        MockClient((req) async {
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('Forbidden', 403);
        }),
      );

      await handler.handle('/block foo', 'a', auth);

      expect(
        systemMessages.single,
        "Failed to block user - You don't have permission to perform that action.",
      );
    });
  });

  group('error mapping', () {
    test('429 maps to the rate-limit notice', () async {
      final handler = createHandler(
        MockClient((req) async {
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('Too Many Requests', 429);
        }),
      );

      await handler.handle('/ban foo', 'a', auth);

      expect(
        systemMessages.single,
        'Failed to ban user - You are being rate-limited. Try again in a moment.',
      );
    });

    test('other 4xx errors pass through the Helix message', () async {
      final handler = createHandler(
        MockClient((req) async {
          if (req.url.path == '/helix/users') return userFound();
          return http.Response(
            '{"message":"The user is not banned in this channel."}',
            400,
          );
        }),
      );

      await handler.handle('/unban foo', 'a', auth);

      expect(
        systemMessages.single,
        'Failed to unban user - The user is not banned in this channel.',
      );
    });
  });

  test('unknown command shows error', () async {
    final handler = createHandler(
      MockClient((req) async => http.Response('', 200)),
    );
    await handler.handle('/foo bar', 'a', auth);
    expect(systemMessages, ['/foo is not a known command']);
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
    expect(systemMessages, ['You must be logged in to use the /ban command.']);
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
