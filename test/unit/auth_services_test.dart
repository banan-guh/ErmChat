import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/services/twitch_oauth.dart';
import 'package:ermchat/services/user_store.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/analytics_service.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ermchat/services/command_handler.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_irc.dart';

TwitchMessage msg(
  String login,
  String text, {
  List<EmotePosition>? positions,
  bool isSystem = false,
  bool isHistory = false,
  bool isBackfill = false,
}) {
  return TwitchMessage(
    login: login,
    text: text,
    channel: 'chan',
    emotePositions: positions,
    isSystem: isSystem,
    isHistory: isHistory,
    isBackfill: isBackfill,
  );
}

ChannelEmotes emoteMap(Map<String, GenericEmote> byCode) {
  return ChannelEmotes(byCode: byCode, suggestions: byCode.values.toList());
}

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
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('TwitchAuth', () {
    for (final (name, run) in <(String, Future<void> Function())>[
      (
        'setCredentials persists token',
        () async {
          final auth = TwitchAuth();
          auth.setCredentials(
            accessToken: 'test_token',
            refreshToken: 'test_refresh',
          );
          expect(auth.accessToken, 'test_token');
          expect(auth.refreshToken, 'test_refresh');
          expect(auth.isConfigured, isTrue);
        },
      ),
      (
        'load restores tokens from secure storage',
        () async {
          FlutterSecureStorage.setMockInitialValues({
            'access_token': 'stored_token',
            'refresh_token': 'stored_refresh',
          });
          final auth = TwitchAuth();
          await auth.load();
          expect(auth.accessToken, 'stored_token');
          expect(auth.refreshToken, 'stored_refresh');
          expect(auth.isConfigured, isTrue);
        },
      ),
    ]) {
      test(name, () async {
        await run();
      });
    }

    for (final (name, run) in <(String, Future<void> Function())>[
      (
        'setUser persists login and user id',
        () async {
          final auth = TwitchAuth();
          auth.setUser('testuser', '12345');
          expect(auth.login, 'testuser');
          expect(auth.userId, '12345');
        },
      ),
      (
        'load restores cached login and user id',
        () async {
          FlutterSecureStorage.setMockInitialValues({
            'access_token': 'stored_token',
            'user_login': 'stored_login',
            'user_id': 'stored_id',
          });
          final auth = TwitchAuth();
          await auth.load();
          expect(auth.login, 'stored_login');
          expect(auth.userId, 'stored_id');
        },
      ),
      (
        'setUser persists profile image url',
        () async {
          final auth = TwitchAuth();
          auth.setCredentials(accessToken: 'token_a');
          auth.setUser(
            'alice',
            '111',
            profileImageUrl: 'https://example.com/a.png',
          );
          await auth.switchTo('alice');
          expect(auth.profileImageUrl, 'https://example.com/a.png');
          expect(
            auth.accounts.single.profileImageUrl,
            'https://example.com/a.png',
          );
          final reloaded = TwitchAuth();
          await reloaded.load();
          expect(reloaded.login, 'alice');
          expect(reloaded.profileImageUrl, 'https://example.com/a.png');
        },
      ),
    ]) {
      test(name, () async {
        await run();
      });
    }

    for (final (name, run) in <(String, Future<void> Function())>[
      (
        'setCredentials plus setUser registers multiple accounts',
        () async {
          final auth = TwitchAuth();
          auth.setCredentials(accessToken: 'token_a');
          auth.setUser('alice', '111');
          auth.setCredentials(accessToken: 'token_b');
          auth.setUser('bob', '222');
          expect(auth.accounts.length, 2);
          expect(
            auth.accounts.map((a) => a.login),
            containsAll(['alice', 'bob']),
          );
          expect(auth.login, 'bob');
        },
      ),
      (
        'switchTo changes the active account',
        () async {
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
        },
      ),
      (
        'accounts persist across load with active login',
        () async {
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
        },
      ),
      (
        'removeAccount falls back to the next account',
        () async {
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
        },
      ),
      (
        'removeAccount of the last account logs out',
        () async {
          final auth = TwitchAuth();
          auth.setCredentials(accessToken: 'token_a');
          auth.setUser('alice', '111');
          await auth.removeAccount('alice');
          expect(auth.accounts, isEmpty);
          expect(auth.accessToken, isNull);
          expect(auth.login, isNull);
          expect(auth.isConfigured, isFalse);
        },
      ),
      (
        'clear removes the active account and falls back',
        () async {
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
        },
      ),
    ]) {
      test(name, () async {
        await run();
      });
    }

    for (final (name, superseded) in [
      ('setUser ignores a result attributed to a superseded token', true),
      ('setUser applies a result attributed to the still-active token', false),
    ]) {
      test(name, () async {
        final auth = TwitchAuth();
        auth.setCredentials(accessToken: 'token_a');
        auth.setUser('alice', '111');
        if (superseded) {
          final tokenAtStart = auth.accessToken;
          auth.setCredentials(accessToken: 'token_b');
          auth.setUser('bob', '222');
          await auth.switchTo('bob');
          auth.setUser('alice', '111', resolvedWithToken: tokenAtStart);
          expect(auth.login, 'bob', reason: name);
          expect(auth.userId, '222', reason: name);
          expect(auth.accessToken, 'token_b', reason: name);
          expect(
            auth.accounts.firstWhere((a) => a.login == 'alice').accessToken,
            'token_a',
            reason: name,
          );
        } else {
          auth.setUser('alice', '111', resolvedWithToken: 'token_a');
          expect(auth.login, 'alice', reason: name);
          expect(auth.userId, '111', reason: name);
          expect(auth.accounts.single.accessToken, 'token_a', reason: name);
        }
      });
    }
  });

  group('TwitchOAuth.parseFragment', () {
    test('extracts access_token and state from fragment (implicit grant)', () {
      final url =
          'https://example.com/twitch-callback'
          '#access_token=testtoken123'
          '&state=abc123';
      final params = TwitchOAuth.parseFragment(url);
      expect(params['access_token'], 'testtoken123');
      expect(params['state'], 'abc123');
    });

    test('extracts error from fragment', () {
      final url =
          'https://example.com/twitch-callback'
          '#error=access_denied&error_description=User+denied+access';
      final params = TwitchOAuth.parseFragment(url);
      expect(params['error'], 'access_denied');
      expect(params['error_description'], 'User denied access');
    });

    for (final (name, url, check) in [
      (
        'returns empty map for URL without fragment',
        'https://example.com/twitch-callback',
        'empty',
      ),
      (
        'returns empty map when no auth-related params present',
        'https://example.com/twitch-callback#foo=bar',
        'foo',
      ),
    ]) {
      test(name, () {
        final params = TwitchOAuth.parseFragment(url);
        if (check == 'empty') {
          expect(params, isEmpty, reason: name);
        } else {
          expect(params['access_token'], isNull, reason: name);
          expect(params['foo'], 'bar', reason: name);
        }
      });
    }

    test('extracts token from complex redirect URL', () {
      final url =
          'https://example.com/twitch-callback'
          '#access_token=abc123def456'
          '&scope=chat%3Aread+chat%3Aedit'
          '&state=csrf_token_here'
          '&token_type=bearer';
      final params = TwitchOAuth.parseFragment(url);
      expect(params['access_token'], 'abc123def456');
      expect(params['scope'], 'chat:read chat:edit');
      expect(params['state'], 'csrf_token_here');
      expect(params['token_type'], 'bearer');
    });
  });

  group('TwitchOAuth.generateAuthUrl', () {
    for (final (name, required, forbidden) in [
      (
        'requests blocked_users scopes for the block feature',
        ['user:manage:blocked_users', 'user:read:blocked_users'],
        <String>[],
      ),
      (
        'requests core chat scopes',
        [
          'chat:read',
          'chat:edit',
          'user:write:chat',
          'user:manage:chat_color',
          'moderator:manage:banned_users',
          'moderator:manage:chat_messages',
          'moderator:manage:announcements',
          'moderator:manage:shoutouts',
        ],
        <String>[],
      ),
      (
        'requests scopes for the extended command set',
        [
          'moderator:manage:chat_settings',
          'channel:manage:moderators',
          'channel:manage:vips',
          'channel:edit:commercial',
          'channel:manage:raids',
          'moderator:manage:shield_mode',
          'channel:manage:broadcast',
          'user:manage:whispers',
        ],
        <String>[],
      ),
      (
        'requests EventSub moderation scopes',
        ['moderator:read:blocked_terms', 'moderator:read:unban_requests'],
        <String>[],
      ),
      (
        'does not request EventSub-only scopes',
        <String>[],
        ['user:read:chat', 'channel:moderate'],
      ),
    ]) {
      test(name, () {
        final urlInfo = TwitchOAuth.generateAuthUrl();
        expect(urlInfo, isNotNull, reason: name);
        final scopes = Uri.parse(
          urlInfo!.url,
        ).queryParameters['scope']!.split(' ');
        expect(scopes, containsAll(required), reason: name);
        for (final s in forbidden) {
          expect(scopes, isNot(contains(s)), reason: name);
        }
      });
    }
  });

  group('UserStore', () {
    for (final (name, run) in <(String, void Function())>[
      (
        'touches user moves to end of LRU',
        () {
          final store = UserStore();
          store.addUser('chan', 'User1');
          store.addUser('chan', 'User2');
          store.addUser('chan', 'User1');
          final list = store.usersForChannel('chan').toList();
          expect(list.first, 'User2');
          expect(list.last, 'User1');
        },
      ),
      (
        'isolates channels',
        () {
          final store = UserStore();
          store.addUser('chan1', 'User1');
          store.addUser('chan2', 'User2');
          expect(store.usersForChannel('chan1'), {'User1'});
          expect(store.usersForChannel('chan2'), {'User2'});
        },
      ),
      (
        'removeChannel clears channel',
        () {
          final store = UserStore();
          store.addUser('chan', 'User1');
          store.removeChannel('chan');
          expect(store.usersForChannel('chan'), isEmpty);
        },
      ),
    ]) {
      test(name, () {
        run();
      });
    }

    test('evicts oldest when exceeding max', () {
      final store = UserStore();
      for (var i = 0; i < 5001; i++) {
        store.addUser('chan', 'User$i');
      }
      final users = store.usersForChannel('chan');
      expect(users.length, 5000);
      expect(users, isNot(contains('User0')));
      expect(users, contains('User5000'));
    });
  });

  group('AnalyticsService', () {
    for (final (name, run) in <(String, void Function())>[
      (
        'records totals, unique chatters and top chatters',
        () {
          final service = AnalyticsService();
          service.recordMessage('chan', msg('alice', 'hi'));
          service.recordMessage('chan', msg('bob', 'hello'));
          service.recordMessage('chan', msg('alice', 'again'));
          expect(service.totalMessages('chan'), 3);
          expect(service.uniqueChatters('chan'), 2);
          expect(service.trackingStartedAt('chan'), isNotNull);
          final top = service.topChatters('chan', 10);
          expect(top, hasLength(2));
          expect(top.first.name, 'alice');
          expect(top.first.count, 2);
        },
      ),
      (
        'excludes system, history and backfill messages',
        () {
          final service = AnalyticsService();
          service.recordMessage('chan', msg('alice', 'real'));
          service.recordMessage('chan', msg('bot', 'sys', isSystem: true));
          service.recordMessage('chan', msg('bot', 'hist', isHistory: true));
          service.recordMessage('chan', msg('bot', 'back', isBackfill: true));
          expect(service.totalMessages('chan'), 1);
          expect(service.uniqueChatters('chan'), 1);
        },
      ),
      (
        'ignores blank logins',
        () {
          final service = AnalyticsService();
          service.recordMessage('chan', msg('', 'anon'));
          expect(service.totalMessages('chan'), 1);
          expect(service.uniqueChatters('chan'), 0);
          expect(service.topChatters('chan', 10), isEmpty);
        },
      ),
    ]) {
      test(name, () {
        run();
      });
    }

    for (final (name, run) in <(String, void Function())>[
      (
        'counts twitch emotes from positions and remaining text as words',
        () {
          final service = AnalyticsService();
          final positions = [
            EmotePosition(
              emoteId: '123',
              startIndex: 0,
              endIndex: 8,
              emoteCode: 'PogChamp',
            ),
          ];
          service.recordMessage(
            'chan',
            msg('alice', 'PogChamp hello', positions: positions),
          );
          final emotes = service.topEmotes('chan', 10);
          expect(emotes, hasLength(1));
          expect(emotes.first.emote.code, 'PogChamp');
          expect(emotes.first.count, 1);
          expect(service.topWords('chan', 10).single.word, 'hello');
        },
      ),
      (
        'counts third-party emotes by token match',
        () {
          final service = AnalyticsService(
            emoteLookup: (_, _) => emoteMap({
              'monkaS': GenericEmote(
                id: 'b1',
                code: 'monkaS',
                type: EmoteType.bttv,
                url: 'https://x',
              ),
            }),
          );
          service.recordMessage('chan', msg('alice', 'monkaS monkaS hi'));
          final emotes = service.topEmotes('chan', 10);
          expect(emotes, hasLength(1));
          expect(emotes.first.emote.code, 'monkaS');
          expect(emotes.first.count, 2);
          expect(service.topWords('chan', 10).single.word, 'hi');
        },
      ),
      (
        'twitch positions take precedence over token match',
        () {
          final service = AnalyticsService(
            emoteLookup: (_, _) => emoteMap({
              'PogChamp': GenericEmote(
                id: 'b1',
                code: 'PogChamp',
                type: EmoteType.bttv,
                url: 'https://x',
              ),
            }),
          );
          final positions = [
            EmotePosition(
              emoteId: '123',
              startIndex: 0,
              endIndex: 8,
              emoteCode: 'PogChamp',
            ),
            EmotePosition(
              emoteId: '123',
              startIndex: 9,
              endIndex: 17,
              emoteCode: 'PogChamp',
            ),
          ];
          service.recordMessage(
            'chan',
            msg('alice', 'PogChamp PogChamp', positions: positions),
          );
          final emotes = service.topEmotes('chan', 10);
          expect(emotes, hasLength(1));
          expect(emotes.first.emote.id, 'b1');
          expect(emotes.first.count, 2);
          expect(service.topWords('chan', 10), isEmpty);
        },
      ),
    ]) {
      test(name, () {
        run();
      });
    }

    for (final (name, text, check) in [
      ('normalizes words and strips punctuation', 'Hello, world!!', 'hello'),
      ('stopword filter excludes common words', 'the cat and dog', 'cat'),
    ]) {
      test(name, () {
        final service = AnalyticsService();
        service.recordMessage('chan', msg('alice', text));
        final words = service.topWords('chan', 10).map((w) => w.word).toList();
        expect(words, contains(check), reason: name);
        if (name.startsWith('stopword')) {
          final filtered = service
              .topWords('chan', 10, useStopwords: true)
              .map((w) => w.word)
              .toList();
          expect(filtered, contains('cat'), reason: name);
          expect(filtered, isNot(contains('the')), reason: name);
        } else {
          expect(words, contains('world'), reason: name);
        }
      });
    }

    test('messages per minute rolls off after 60 minutes', () {
      var now = DateTime(2024, 1, 1, 12, 0, 0);
      final service = AnalyticsService(now: () => now);

      for (var i = 0; i < 5; i++) {
        service.recordMessage('chan', msg('alice', 'hello'));
      }
      expect(service.messagesPerMinute('chan'), 5.0);

      now = now.add(const Duration(minutes: 61));
      service.recordMessage('chan', msg('alice', 'new hour'));

      final rate = service.messagesPerMinute('chan');
      expect(rate, closeTo(1 / 60, 0.0001));
      expect(service.totalMessages('chan'), 6);
    });

    test('records moderation bans and timeouts', () {
      final service = AnalyticsService();
      service.recordModeration('chan', false);
      service.recordModeration('chan', true);
      service.recordModeration('chan', true);

      expect(service.banCount('chan'), 1);
      expect(service.timeoutCount('chan'), 2);
    });

    for (final (name, all) in [
      ('resets single channel', false),
      ('resets all channels', true),
    ]) {
      test(name, () {
        final service = AnalyticsService();
        service.recordMessage('chan', msg('alice', 'hi'));
        service.recordMessage('other', msg('bob', 'yo'));
        if (all) {
          service.resetAll();
          expect(service.trackedChannels(), isEmpty, reason: name);
        } else {
          service.resetChannel('chan');
          expect(service.isTracking('chan'), isFalse, reason: name);
          expect(service.totalMessages('chan'), 0, reason: name);
          expect(service.isTracking('other'), isTrue, reason: name);
        }
      });
    }
  });

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

  CommandHandler createHandler(
    MockClient client, {
    bool trackBlocks = false,
    List<String>? whisperMessages,
    List<({String target, String message})>? whisperSent,
  }) {
    return CommandHandler(
      twitchApi: TwitchApi(client: client),
      irc: irc,
      getChannelUserIds: () => {'a': '111'},
      getCurrentUserId: () => '222',
      getCurrentUserLogin: () => 'me',
      addSystemMessage: (channel, message) {
        systemMessages.add(message);
      },
      whisperAddSystemMessage: whisperMessages == null
          ? null
          : (channel, message) => whisperMessages.add(message),
      onWhisperSent: whisperSent == null
          ? null
          : (target, message) =>
                whisperSent.add((target: target, message: message)),
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

    for (final (name, command, status, snippet) in [
      (
        'ban reports failure on 401 (missing scopes)',
        '/ban foo',
        401,
        'Missing required scope',
      ),
      (
        'warn reports failure on 401 (missing scopes)',
        '/warn foo',
        401,
        'Missing required scope',
      ),
      ('unban reports failure on 403', '/unban foo', 403, 'permission'),
      ('announce shows error on failure', '/announce hi', 403, 'permission'),
    ]) {
      test('/$name', () async {
        final handler = createHandler(
          MockClient((req) async {
            if (req.url.path == '/helix/users') return userFound();
            return http.Response('{"message":"$snippet"}', status);
          }),
        );
        await handler.handle(command, 'a', auth);
        expect(irc.sent, isEmpty, reason: name);
        expect(systemMessages.single, contains(snippet), reason: name);
      });
    }

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

    for (final (name, command, usage) in [
      (
        'ban with no args shows usage',
        '/ban',
        'Usage: /ban <username> [reason]',
      ),
      (
        'warn with no args shows usage',
        '/warn',
        'Usage: /warn <username> [reason]',
      ),
      ('color with no args shows usage', '/color', 'Usage: /color'),
      (
        'w with a missing message shows usage',
        '/w foo',
        'Usage: /w <username> <message>',
      ),
    ]) {
      test('/$name', () async {
        var calls = 0;
        final handler = createHandler(
          MockClient((req) async {
            calls++;
            return http.Response('', 200);
          }),
        );
        await handler.handle(command, 'a', auth);
        expect(
          systemMessages.single,
          startsWith(usage.split(' ').first),
          reason: name,
        );
        if (name.startsWith('w') || name.startsWith('color')) {
          expect(calls, 0, reason: name);
        }
      });
    }

    for (final (name, userBody, command, expected) in [
      (
        'ban unknown user shows not found and does not fall back',
        userMissing().body,
        '/ban ghost',
        'No user matching that username.',
      ),
      (
        'ban cannot target yourself',
        '{"data":[{"id":"222","login":"me"}]}',
        '/ban me',
        'Failed to ban user - You cannot ban yourself.',
      ),
      (
        'ban cannot target the broadcaster',
        '{"data":[{"id":"111","login":"broadcaster"}]}',
        '/ban broadcaster',
        'Failed to ban user - You cannot ban the broadcaster.',
      ),
    ]) {
      test('/$name', () async {
        final handler = createHandler(
          MockClient((req) async {
            if (req.url.path == '/helix/users') {
              return http.Response(userBody, 200);
            }
            return http.Response('', 200);
          }),
        );
        await handler.handle(command, 'a', auth);
        expect(systemMessages.single, expected, reason: name);
        expect(irc.sent, isEmpty, reason: name);
      });
    }

    for (final (name, command, duration, reason) in [
      (
        'timeout with explicit duration and reason',
        '/timeout foo 30 being rude',
        '30',
        'being rude',
      ),
      (
        'timeout defaults to 600s when duration omitted',
        '/timeout foo',
        '600',
        null,
      ),
      (
        'timeout accepts DankChat-style unit durations',
        '/timeout foo 2m30s',
        '150',
        null,
      ),
      (
        'timeout treats non-numeric second arg as reason',
        '/timeout foo stop it',
        '600',
        'stop it',
      ),
    ]) {
      test('/$name', () async {
        final requests = <http.Request>[];
        final handler = createHandler(
          MockClient((req) async {
            requests.add(req);
            if (req.url.path == '/helix/users') return userFound();
            return http.Response('', 200);
          }),
        );
        await handler.handle(command, 'a', auth);
        final body =
            jsonDecode(
                  requests
                      .firstWhere((r) => r.url.path == '/helix/moderation/bans')
                      .body,
                )
                as Map;
        expect((body['data'] as Map)['duration'], duration, reason: name);
        if (reason != null) {
          expect((body['data'] as Map)['reason'], reason, reason: name);
        }
      });
    }

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
  });

  group('warn', () {
    for (final (name, command, expectReason) in [
      (
        'warn success via Helix posts user_id and reason',
        '/warn foo spamming',
        true,
      ),
      ('warn without reason omits it from the body', '/warn foo', false),
    ]) {
      test('/$name', () async {
        http.Request? captured;
        final requests = <http.Request>[];
        final handler = createHandler(
          MockClient((req) async {
            requests.add(req);
            if (req.url.path == '/helix/users') return userFound();
            captured = req;
            return http.Response('{"data":[{"id":"w1"}]}', 200);
          }),
        );
        await handler.handle(command, 'a', auth);
        expect(systemMessages, ['foo has been warned.'], reason: name);
        expect(irc.sent, isEmpty, reason: name);
        final body = jsonDecode(captured!.body) as Map;
        expect((body['data'] as Map)['user_id'], '999', reason: name);
        expect(body['data'].containsKey('reason'), expectReason, reason: name);
      });
    }
  });

  group('polls and predictions', () {
    test('/poll posts title, choices and duration', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          return http.Response('{"data":[{"id":"p1"}]}', 200);
        }),
      );

      await handler.handle('/poll best emote | Kappa | PogChamp', 'a', auth);

      expect(systemMessages, ['Poll started (60s).']);
      final req = requests.single;
      expect(req.method, 'POST');
      expect(req.url.path, '/helix/polls');
      final body = jsonDecode(req.body) as Map;
      expect(body['broadcaster_id'], '111');
      expect(body['title'], 'best emote');
      expect((body['choices'] as List).map((c) => c['title']), [
        'Kappa',
        'PogChamp',
      ]);
      expect(body['duration'], 60);
    });

    test('/poll leading duration token is consumed', () async {
      http.Request? captured;
      final handler = createHandler(
        MockClient((req) async {
          captured = req;
          return http.Response('{"data":[]}', 200);
        }),
      );

      await handler.handle('/poll 2m pick one | x | y | z', 'a', auth);

      expect(systemMessages, ['Poll started (120s).']);
      final body = jsonDecode(captured!.body) as Map;
      expect(body['duration'], 120);
      expect(body['title'], 'pick one');
      expect(body['choices'], hasLength(3));
    });

    for (final (name, command, snippet) in [
      (
        'poll rejects out-of-range duration and single choice',
        '/poll 5s too fast | a | b',
        'Duration',
      ),
      ('poll rejects a single choice', '/poll only one | a', '2-5 choices'),
      (
        'endpoll without an active poll says so',
        '/endpoll',
        'No poll is currently running.',
      ),
      (
        'resolveprediction unknown outcome reports it',
        '/resolveprediction purple',
        'No outcome matching',
      ),
    ]) {
      test('/$name', () async {
        final handler = createHandler(
          MockClient((req) async {
            if (req.url.path == '/helix/predictions' && req.method == 'GET') {
              return http.Response(
                '{"data":[{"id":"pr1","status":"OPEN","outcomes":[{"id":"o1","title":"Blue"}]}]}',
                200,
              );
            }
            if (req.url.path == '/helix/polls' && req.method == 'GET') {
              return http.Response(
                '{"data":[{"id":"done","status":"COMPLETED"}]}',
                200,
              );
            }
            return http.Response('{"data":[]}', 200);
          }),
        );
        await handler.handle(command, 'a', auth);
        expect(systemMessages.single, contains(snippet), reason: name);
      });
    }

    test('/endpoll terminates the active poll', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/polls' && req.method == 'GET') {
            return http.Response(
              '{"data":[{"id":"old","status":"TERMINATED"},{"id":"live","status":"ACTIVE"}]}',
              200,
            );
          }
          return http.Response('{"data":[]}', 200);
        }),
      );

      await handler.handle('/endpoll', 'a', auth);

      expect(systemMessages, ['The poll has ended.']);
      final patch = requests.where((r) => r.method == 'PATCH').single;
      final body = jsonDecode(patch.body) as Map;
      expect(body['id'], 'live');
      expect(body['status'], 'TERMINATED');
    });

    test('/cancelpoll archives and reports cancellation', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/polls' && req.method == 'GET') {
            return http.Response(
              '{"data":[{"id":"live","status":"ACTIVE"}]}',
              200,
            );
          }
          return http.Response('{"data":[]}', 200);
        }),
      );

      await handler.handle('/cancelpoll', 'a', auth);

      expect(systemMessages, ['The poll was cancelled.']);
      final patch = requests.where((r) => r.method == 'PATCH').single;
      expect(jsonDecode(patch.body)['status'], 'ARCHIVED');
    });

    test('/prediction posts outcomes and window', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          return http.Response('{"data":[{"id":"pr1"}]}', 200);
        }),
      );

      await handler.handle('/prediction wins the game? | yes | no', 'a', auth);

      expect(systemMessages, ['Prediction started (60s).']);
      final req = requests.single;
      expect(req.url.path, '/helix/predictions');
      final body = jsonDecode(req.body) as Map;
      expect(body['title'], 'wins the game?');
      expect((body['outcomes'] as List).map((o) => o['title']), ['yes', 'no']);
      expect(body['prediction_window'], 60);
    });

    test('/resolveprediction by index sends winning_outcome_id', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/predictions' && req.method == 'GET') {
            return http.Response(
              '{"data":[{"id":"pr1","status":"OPEN","outcomes":['
              '{"id":"o1","title":"Blue"},{"id":"o2","title":"Red"}]}]}',
              200,
            );
          }
          return http.Response('{"data":[]}', 200);
        }),
      );

      await handler.handle('/resolveprediction 2', 'a', auth);

      expect(systemMessages, ['The prediction was resolved: Red.']);
      final patch = requests.where((r) => r.method == 'PATCH').single;
      final body = jsonDecode(patch.body) as Map;
      expect(body['status'], 'RESOLVED');
      expect(body['winning_outcome_id'], 'o2');
    });

    test('/resolveprediction by exact title', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/predictions' && req.method == 'GET') {
            return http.Response(
              '{"data":[{"id":"pr1","status":"OPEN","outcomes":['
              '{"id":"o1","title":"Blue"},{"id":"o2","title":"Red"}]}]}',
              200,
            );
          }
          return http.Response('{"data":[]}', 200);
        }),
      );

      await handler.handle('/resolveprediction blue', 'a', auth);

      expect(systemMessages, ['The prediction was resolved: Blue.']);
      final patch = requests.where((r) => r.method == 'PATCH').single;
      expect(jsonDecode(patch.body)['winning_outcome_id'], 'o1');
    });

    test('/lockprediction locks the open prediction', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/predictions' && req.method == 'GET') {
            return http.Response(
              '{"data":[{"id":"pr1","status":"OPEN","outcomes":[]}]}',
              200,
            );
          }
          return http.Response('{"data":[]}', 200);
        }),
      );

      await handler.handle('/lockprediction', 'a', auth);

      expect(systemMessages, ['Predictions are now locked.']);
      final patch = requests.where((r) => r.method == 'PATCH').single;
      final body = jsonDecode(patch.body) as Map;
      expect(body['status'], 'LOCKED');
      expect(body.containsKey('winning_outcome_id'), isFalse);
    });

    test('/cancelprediction cancels the open prediction', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/predictions' && req.method == 'GET') {
            return http.Response(
              '{"data":[{"id":"pr1","status":"OPEN","outcomes":[]}]}',
              200,
            );
          }
          return http.Response('{"data":[]}', 200);
        }),
      );

      await handler.handle('/cancelprediction', 'a', auth);

      expect(systemMessages.single, contains('refunded'));
      final patch = requests.where((r) => r.method == 'PATCH').single;
      expect(jsonDecode(patch.body)['status'], 'CANCELED');
    });
  });

  group('delete / clear', () {
    for (final (name, command, message, hasId) in [
      (
        'delete success targets the message id',
        '/delete abc123',
        'Message deleted.',
        true,
      ),
      ('clear success omits message_id', '/clear', 'Chat cleared.', false),
    ]) {
      test('/$name', () async {
        final requests = <http.Request>[];
        final handler = createHandler(
          MockClient((req) async {
            requests.add(req);
            return http.Response('', 204);
          }),
        );
        await handler.handle(command, 'a', auth);
        expect(systemMessages, [message], reason: name);
        final req = requests.single;
        expect(req.method, 'DELETE', reason: name);
        expect(req.url.path, '/helix/moderation/chat', reason: name);
        expect(
          req.url.queryParameters.containsKey('message_id'),
          hasId,
          reason: name,
        );
      });
    }
  });

  group('announce', () {
    for (final (name, command, color, message) in [
      (
        'announce posts the message',
        '/announce hello world',
        'primary',
        'hello world',
      ),
      (
        'announce accepts a color argument',
        '/announce blue hello world',
        'blue',
        'hello world',
      ),
      (
        'announceblue posts with the blue color',
        '/announceblue hello',
        'blue',
        'hello',
      ),
    ]) {
      test('/$name', () async {
        final requests = <http.Request>[];
        final handler = createHandler(
          MockClient((req) async {
            requests.add(req);
            return http.Response('', 204);
          }),
        );
        await handler.handle(command, 'a', auth);
        final body = jsonDecode(requests.single.body) as Map;
        expect(body['color'], color, reason: name);
        expect(body['message'], message, reason: name);
      });
    }

    test('/announce rejects a bare color argument', () async {
      final handler = createHandler(
        MockClient((req) async => http.Response('', 204)),
      );

      await handler.handle('/announce blue', 'a', auth);

      expect(systemMessages.single, 'Usage: /announce [color] <message>');
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

    for (final (name, body, expected) in [
      (
        'mod lists the channel moderators',
        '{"data":[{"user_login":"alice"},{"user_login":"bob"}]}',
        'The moderators of this channel are alice, bob.',
      ),
      (
        'mods reports when there are none',
        '{"data":[]}',
        'This channel does not have any moderators.',
      ),
    ]) {
      test('/$name', () async {
        final handler = createHandler(
          MockClient((req) async => http.Response(body, 200)),
        );
        await handler.handle('/mods', 'a', auth);
        expect(systemMessages, [expected], reason: name);
      });
    }

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
    for (final (name, command, key, value) in [
      ('slow defaults to 30 seconds', '/slow', 'slow_mode_wait_time', 30),
      (
        'slow accepts a custom duration',
        '/slow 120',
        'slow_mode_wait_time',
        120,
      ),
      ('slowoff disables slow mode', '/slowoff', 'slow_mode', false),
    ]) {
      test('/$name', () async {
        final requests = <http.Request>[];
        final handler = createHandler(
          MockClient((req) async {
            requests.add(req);
            return http.Response('', 200);
          }),
        );
        await handler.handle(command, 'a', auth);
        expect(jsonDecode(requests.single.body)[key], value, reason: name);
      });
    }

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

    for (final (name, command, duration) in [
      (
        'followers enables followers-only mode with unit duration',
        '/followers 1h',
        60,
      ),
      ('followersoff disables followers-only mode', '/followersoff', null),
    ]) {
      test('/$name', () async {
        final requests = <http.Request>[];
        final handler = createHandler(
          MockClient((req) async {
            requests.add(req);
            return http.Response('', 200);
          }),
        );
        await handler.handle(command, 'a', auth);
        final body = jsonDecode(requests.single.body) as Map;
        if (duration != null) {
          expect(body['follower_mode'], isTrue, reason: name);
          expect(body['follower_mode_duration'], duration, reason: name);
        } else {
          expect(body['follower_mode'], isFalse, reason: name);
        }
      });
    }

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

    for (final (name, command, usage) in [
      (
        'commercial rejects invalid lengths',
        '/commercial 45',
        'Usage: /commercial',
      ),
    ]) {
      test('/$name', () async {
        var calls = 0;
        final handler = createHandler(
          MockClient((req) async {
            calls++;
            return http.Response('', 200);
          }),
        );
        await handler.handle(command, 'a', auth);
        expect(calls, 0, reason: name);
        expect(systemMessages.single, startsWith(usage), reason: name);
      });
    }

    for (final (name, command, method) in [
      ('raid starts a raid to the resolved user', '/raid foo', 'POST'),
      ('unraid cancels the raid', '/unraid', 'DELETE'),
    ]) {
      test('/$name', () async {
        final requests = <http.Request>[];
        final handler = createHandler(
          MockClient((req) async {
            requests.add(req);
            if (req.url.path == '/helix/users') return userFound();
            if (method == 'POST') return http.Response('{"data":[]}', 200);
            return http.Response('', 204);
          }),
        );
        await handler.handle(command, 'a', auth);
        final req = requests.firstWhere((r) => r.url.path == '/helix/raids');
        expect(req.method, method, reason: name);
      });
    }

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

    test('/w routes feedback and echo through whisper callbacks', () async {
      final whisperMessages = <String>[];
      final whisperSent = <({String target, String message})>[];
      final handler = createHandler(
        MockClient((req) async {
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('', 204);
        }),
        whisperMessages: whisperMessages,
        whisperSent: whisperSent,
      );

      await handler.handle('/w foo hey there', 'a', auth);

      expect(systemMessages, isEmpty);
      expect(whisperMessages, ['Whisper sent.']);
      expect(whisperSent, [(target: 'foo', message: 'hey there')]);
    });

    test('/w failure reports through whisper feedback', () async {
      final whisperMessages = <String>[];
      final handler = createHandler(
        MockClient((req) async {
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('{"message":"rate limit"}', 429);
        }),
        whisperMessages: whisperMessages,
      );

      await handler.handle('/w foo hey', 'a', auth);

      expect(systemMessages, isEmpty);
      expect(whisperMessages.single, contains('Failed to send whisper'));
      expect(whisperMessages.single, contains('rate-limited'));
    });

    for (final (name, command, method, label) in [
      (
        'block blocks the user and reports the local list',
        '/block Foo',
        'PUT',
        'foo',
      ),
      (
        'unblock unblocks the user and reports the local list',
        '/unblock foo',
        'DELETE',
        'foo',
      ),
    ]) {
      test('/$name', () async {
        final requests = <http.Request>[];
        final handler = createHandler(
          MockClient((req) async {
            requests.add(req);
            if (req.url.path == '/helix/users') return userFound();
            return http.Response('', 204);
          }),
          trackBlocks: true,
        );
        await handler.handle(command, 'a', auth);
        final req = requests.firstWhere(
          (r) => r.url.path == '/helix/users/blocks',
        );
        expect(req.method, method, reason: name);
        expect(req.url.queryParameters['target_user_id'], '999', reason: name);
        expect(label, 'foo', reason: name);
      });
    }
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

  group('TwitchAccount.expired', () {
    test('round-trips the expired flag and omits it when false', () {
      final expired = TwitchAccount(
        login: 'test',
        accessToken: 'tok',
        expired: true,
      );
      final restored = TwitchAccount.fromJson(expired.toJson());
      expect(restored.expired, isTrue);

      final fresh = TwitchAccount(login: 'a', accessToken: 't');
      expect(fresh.toJson(), isNot(contains('expired')));
      expect(expired.toJson(), contains('expired'));
    });
  });

  group('TwitchAuth.markActiveExpired', () {
    test('sets the expired flag for named and pending accounts', () async {
      final named = TwitchAuth();
      await named.load();
      named.accessToken = 'tok';
      named.login = 'testuser';
      named.userId = '123';
      named.accounts = [
        TwitchAccount(login: 'testuser', userId: '123', accessToken: 'tok'),
      ];

      named.markActiveExpired();
      expect(named.isActiveExpired, isTrue);
      expect(named.accounts.first.expired, isTrue);

      final pending = TwitchAuth();
      await pending.load();
      pending.accessToken = 'tok';
      pending.login = null;

      pending.markActiveExpired();
      expect(pending.isActiveExpired, isTrue);
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

    test('returns null on auth failure and network error', () async {
      final unauthorized = MockClient((request) async {
        return http.Response(
          '{"status":401,"message":"invalid access token"}',
          401,
        );
      });
      final unauthorizedApi = TwitchApi(client: unauthorized);
      final deadAuth = TwitchAuth();
      deadAuth.accessToken = 'dead-token';

      final unauthorizedResult = await unauthorizedApi.validateToken(deadAuth);
      expect(unauthorizedResult, isNull);
      expect(unauthorizedApi.lastErrorStatus, 401);

      final flaky = MockClient((request) async {
        throw Exception('network');
      });
      final flakyApi = TwitchApi(client: flaky);
      final flakyAuth = TwitchAuth();
      flakyAuth.accessToken = 'tok';

      final flakyResult = await flakyApi.validateToken(flakyAuth);
      expect(flakyResult, isNull);
      expect(flakyApi.lastErrorStatus, isNull);
    });
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

    test('ignores channel-scoped and unrelated global notices', () async {
      const lines = [
        '@msg-id=slow_on :tmi.twitch.tv NOTICE #xqc :This room is now in slow mode.',
        ':tmi.twitch.tv NOTICE * :Some other connection notice',
      ];
      for (final line in lines) {
        final service = IrcService();
        final authFailed = <void>[];
        service.onAuthFailed.listen((_) => authFailed.add(null));

        service.handleLine(line);
        await Future<void>.delayed(Duration.zero);

        expect(authFailed, isEmpty, reason: 'line: $line');
        service.dispose();
      }
    });
  });
}
