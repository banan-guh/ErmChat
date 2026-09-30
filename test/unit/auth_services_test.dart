import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/services/twitch_oauth.dart';
import 'package:ermchat/services/user_store.dart';
import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/emotes/emote_catalog.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/analytics_service.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ermchat/services/command_handler.dart';
import 'package:ermchat/services/mod_actions.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/services/media_uploader.dart';
import 'package:ermchat/client/session.dart';
import 'package:ermchat/irc/transport/write.dart';

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

EmoteLookup emoteMap(Map<String, Emote> byCode) {
  return EmoteLookup(byCode: byCode, suggestions: byCode.values.toList());
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

class _RecordingClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw UnimplementedError();
  }

  @override
  void close() => closed = true;
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('TwitchAuth', () {
    TwitchAuth twoAccounts() {
      final auth = TwitchAuth();
      auth.setCredentials(accessToken: 'token_a');
      auth.setUser('alice', '111');
      auth.setCredentials(accessToken: 'token_b');
      auth.setUser('bob', '222');
      return auth;
    }

    Future<TwitchAuth> reload() async {
      final auth = TwitchAuth();
      await auth.load();
      return auth;
    }

    test('tokens, user and profile image persist through load', () async {
      final auth = TwitchAuth();
      auth.setCredentials(accessToken: 'tok', refreshToken: 'ref');
      auth.setUser(
        'alice',
        '111',
        profileImageUrl: 'https://example.com/a.png',
      );
      expect(auth.isConfigured, isTrue);
      expect(auth.accounts.single.profileImageUrl, 'https://example.com/a.png');
      await auth.switchTo('alice');

      final back = await reload();
      expect(back.accessToken, 'tok');
      expect(back.refreshToken, 'ref');
      expect(back.login, 'alice');
      expect(back.userId, '111');
      expect(back.profileImageUrl, 'https://example.com/a.png');
    });

    test('load restores legacy single-account storage keys', () async {
      FlutterSecureStorage.setMockInitialValues({
        'access_token': 'stored_token',
        'refresh_token': 'stored_refresh',
        'user_login': 'stored_login',
        'user_id': 'stored_id',
      });
      final auth = await reload();
      expect(auth.accessToken, 'stored_token');
      expect(auth.refreshToken, 'stored_refresh');
      expect(auth.login, 'stored_login');
      expect(auth.userId, 'stored_id');
      expect(auth.isConfigured, isTrue);
    });

    test('multiple accounts register, switch and persist', () async {
      final auth = twoAccounts();
      expect(auth.accounts.map((a) => a.login), ['alice', 'bob']);
      expect(auth.login, 'bob');

      await auth.switchTo('alice');
      expect(auth.login, 'alice');
      expect(auth.accessToken, 'token_a');

      final back = await reload();
      expect(back.accounts, hasLength(2));
      expect(back.login, 'alice');
      expect(back.accessToken, 'token_a');
      expect(back.userId, '111');
    });

    test('removing or clearing the active account falls back', () async {
      final auth = twoAccounts();
      await auth.switchTo('alice');
      await auth.removeAccount('alice');
      expect(auth.accounts.single.login, 'bob');
      expect(auth.login, 'bob');
      expect(auth.accessToken, 'token_b');

      final cleared = twoAccounts();
      await cleared.switchTo('alice');
      await cleared.clear();
      expect(cleared.login, 'bob');

      final solo = TwitchAuth();
      solo.setCredentials(accessToken: 'token_a');
      solo.setUser('alice', '111');
      await solo.removeAccount('alice');
      expect(solo.accounts, isEmpty);
      expect(solo.accessToken, isNull);
      expect(solo.login, isNull);
      expect(solo.isConfigured, isFalse);
    });

    test('anonymous keeps the registry, persists and restores', () async {
      expect((await reload()).isAnonymous, isTrue, reason: 'fresh install');

      final auth = twoAccounts();
      await auth.switchToAnonymous();
      expect(auth.isAnonymous, isTrue);
      expect(auth.accessToken, isNull);
      expect(auth.login, isNull);
      expect(auth.isConfigured, isFalse);
      expect(auth.accounts, hasLength(2));

      final back = await reload();
      expect(back.isAnonymous, isTrue);
      expect(back.accounts, hasLength(2));

      await auth.removeAccount('alice');
      expect(auth.isAnonymous, isTrue);
      expect(auth.accounts.single.login, 'bob');

      await auth.switchTo('bob');
      expect(auth.isAnonymous, isFalse);
      expect(auth.accessToken, 'token_b');
      expect((await reload()).login, 'bob');
    });

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

  test('TwitchOAuth.parseFragment decodes the redirect fragment', () {
    const base = 'https://example.com/twitch-callback';
    final ok = TwitchOAuth.parseFragment(
      '$base#access_token=abc123def456&scope=chat%3Aread+chat%3Aedit'
      '&state=csrf_token_here&token_type=bearer',
    );
    expect(ok, {
      'access_token': 'abc123def456',
      'scope': 'chat:read chat:edit',
      'state': 'csrf_token_here',
      'token_type': 'bearer',
    });

    final denied = TwitchOAuth.parseFragment(
      '$base#error=access_denied&error_description=User+denied+access',
    );
    expect(denied['error'], 'access_denied');
    expect(denied['error_description'], 'User denied access');

    expect(TwitchOAuth.parseFragment(base), isEmpty);
    expect(TwitchOAuth.parseFragment('$base#foo=bar')['access_token'], isNull);
  });

  group('TwitchOAuth.generateAuthUrl', () {
    test('does not request EventSub-only scopes', () {
      final scopes = Uri.parse(
        TwitchOAuth.generateAuthUrl()!.url,
      ).queryParameters['scope']!.split(' ');
      expect(scopes, isNot(contains('user:read:chat')));
      expect(scopes, isNot(contains('channel:moderate')));
    });

    test('url covers the full requiredScopes list', () {
      final urlInfo = TwitchOAuth.generateAuthUrl();
      final scopes = Uri.parse(
        urlInfo!.url,
      ).queryParameters['scope']!.split(' ');
      expect(scopes, containsAll(TwitchOAuth.requiredScopes));
      expect(scopes.length, TwitchOAuth.requiredScopes.length);
    });
  });

  group('TwitchOAuth.missingScopes', () {
    test('empty when the grant covers everything', () {
      expect(TwitchOAuth.missingScopes(TwitchOAuth.requiredScopes), isEmpty);
    });

    test('lists absent scopes, ignores extras', () {
      final missing = TwitchOAuth.missingScopes([
        'chat:read',
        'chat:edit',
        'some:future_scope',
      ]);
      expect(missing, contains('moderator:manage:blocked_terms'));
      expect(missing, isNot(contains('chat:read')));
      expect(missing, isNot(contains('some:future_scope')));
    });
  });

  group('UserStore', () {
    test('tracks users per channel in LRU order', () {
      for (final (_, run) in <(String, void Function())>[
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
        run();
      }
    });

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
    test('records and filters messages', () {
      for (final (_, run) in <(String, void Function())>[
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
        run();
      }
    });

    test('counts emotes and words', () {
      for (final (_, run) in <(String, void Function())>[
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
                'monkaS': Emote(
                  id: 'b1',
                  code: 'monkaS',
                  meta: const BttvMeta(),
                  scales: const {EmoteScale.medium: 'https://x'},
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
                'PogChamp': Emote(
                  id: 'b1',
                  code: 'PogChamp',
                  meta: const BttvMeta(),
                  scales: const {EmoteScale.medium: 'https://x'},
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
        run();
      }
    });

    test('normalizes words and filters stopwords on request', () {
      final service = AnalyticsService();
      service.recordMessage('chan', msg('alice', 'Hello, world!! the cat'));
      List<String> words({bool stop = false}) => service
          .topWords('chan', 10, useStopwords: stop)
          .map((w) => w.word)
          .toList();
      expect(words(), containsAll(['hello', 'world', 'the', 'cat']));
      expect(words(stop: true), containsAll(['cat']));
      expect(words(stop: true), isNot(contains('the')));
    });

    test('messages per minute rolls off after 60 minutes', () {
      var now = DateTime(2024, 1, 1, 12, 0, 0);
      final service = AnalyticsService(now: () => now);

      for (var i = 0; i < 5; i++) {
        service.recordMessage('chan', msg('alice', 'hello'));
      }
      expect(service.messagesPerMinute('chan'), 5.0);

      now = now.add(const Duration(minutes: 61));
      service.recordMessage('chan', msg('alice', 'new hour'));

      expect(service.messagesPerMinute('chan'), closeTo(1 / 60, 0.0001));
      expect(service.totalMessages('chan'), 6);
    });

    test('records moderation and resets per channel or globally', () {
      final service = AnalyticsService();
      service.recordModeration('chan', false);
      service.recordModeration('chan', true);
      service.recordModeration('chan', true);
      expect(service.banCount('chan'), 1);
      expect(service.timeoutCount('chan'), 2);

      service.recordMessage('chan', msg('alice', 'hi'));
      service.recordMessage('other', msg('bob', 'yo'));
      service.resetChannel('chan');
      expect(service.isTracking('chan'), isFalse);
      expect(service.totalMessages('chan'), 0);
      expect(service.isTracking('other'), isTrue);
      service.resetAll();
      expect(service.trackedChannels(), isEmpty);
    });
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

  /// Runs [command] against a mock Helix. `/helix/users` resolves to user 999;
  /// [respond] answers everything else.
  Future<List<http.Request>> runCommand(
    String command, {
    http.Response Function(http.Request)? respond,
    bool trackBlocks = false,
    List<String>? whisperMessages,
    List<({String target, String message})>? whisperSent,
  }) async {
    final requests = <http.Request>[];
    final handler = createHandler(
      MockClient((req) async {
        requests.add(req);
        if (req.url.path == '/helix/users') return userFound();
        return respond?.call(req) ?? http.Response('', 204);
      }),
      trackBlocks: trackBlocks,
      whisperMessages: whisperMessages,
      whisperSent: whisperSent,
    );
    await handler.handle(command, 'a', auth);
    return requests;
  }

  const absent = '<absent>';

  void expectSubset(Map expected, Map actual, String reason) {
    expected.forEach((key, want) {
      if (want == absent) {
        expect(actual.containsKey(key), isFalse, reason: '$reason: $key');
      } else if (want is Map) {
        expectSubset(want, actual[key] as Map, '$reason: $key');
      } else {
        expect(actual[key], want, reason: '$reason: $key');
      }
    });
  }

  group('commands send the right Helix request', () {
    // (command, chat message, method, path, expected query, expected body)
    final ok = <(String, String, String, String, Map, Map)>[
      (
        '/ban foo spamming',
        'foo has been banned.',
        'POST',
        '/helix/moderation/bans',
        {'broadcaster_id': '111', 'moderator_id': '222'},
        {
          'data': {'user_id': '999', 'reason': 'spamming', 'duration': absent},
        },
      ),
      (
        '/timeout foo 30 being rude',
        '',
        'POST',
        '/helix/moderation/bans',
        {},
        {
          'data': {'duration': 30, 'reason': 'being rude'},
        },
      ),
      (
        '/timeout foo',
        '',
        'POST',
        '/helix/moderation/bans',
        {},
        {
          'data': {'duration': 600, 'reason': absent},
        },
      ),
      (
        '/timeout foo 2m30s',
        '',
        'POST',
        '/helix/moderation/bans',
        {},
        {
          'data': {'duration': 150},
        },
      ),
      (
        '/timeout foo stop it',
        '',
        'POST',
        '/helix/moderation/bans',
        {},
        {
          'data': {'duration': 600, 'reason': 'stop it'},
        },
      ),
      (
        '/unban foo',
        'foo has been unbanned.',
        'DELETE',
        '/helix/moderation/bans',
        {'user_id': '999'},
        {},
      ),
      (
        '/untimeout foo',
        'foo has been untimed out.',
        'DELETE',
        '/helix/moderation/bans',
        {'user_id': '999'},
        {},
      ),
      (
        '/warn foo spamming',
        'foo has been warned.',
        'POST',
        '/helix/moderation/warnings',
        {},
        {
          'data': {'user_id': '999', 'reason': 'spamming'},
        },
      ),
      (
        '/warn foo',
        'foo has been warned.',
        'POST',
        '/helix/moderation/warnings',
        {},
        {
          'data': {'user_id': '999', 'reason': absent},
        },
      ),
      (
        '/delete abc123',
        'Message deleted.',
        'DELETE',
        '/helix/moderation/chat',
        {'message_id': 'abc123'},
        {},
      ),
      ('/clear', 'Chat cleared.', 'DELETE', '/helix/moderation/chat', {}, {}),
      (
        '/announce hello world',
        '',
        'POST',
        '/helix/chat/announcements',
        {},
        {'color': 'primary', 'message': 'hello world'},
      ),
      (
        '/announce blue hello world',
        '',
        'POST',
        '/helix/chat/announcements',
        {},
        {'color': 'blue', 'message': 'hello world'},
      ),
      (
        '/announceblue hello',
        '',
        'POST',
        '/helix/chat/announcements',
        {},
        {'color': 'blue', 'message': 'hello'},
      ),
      (
        '/shoutout foo',
        'Sent shoutout to foo',
        'POST',
        '/helix/chat/shoutouts',
        {
          'from_broadcaster_id': '111',
          'to_broadcaster_id': '999',
          'moderator_id': '222',
        },
        {},
      ),
      (
        '/color red',
        'Your color has been changed to red',
        'PUT',
        '/helix/chat/color',
        {'color': 'red'},
        {},
      ),
      (
        '/mod foo',
        'You have added foo as a moderator of this channel.',
        'POST',
        '/helix/moderation/moderators',
        {'broadcaster_id': '111', 'user_id': '999'},
        {},
      ),
      (
        '/unmod foo',
        'You have removed foo as a moderator of this channel.',
        'DELETE',
        '/helix/moderation/moderators',
        {},
        {},
      ),
      (
        '/vip foo',
        'You have added foo as a VIP of this channel.',
        'POST',
        '/helix/channels/vips',
        {'user_id': '999'},
        {},
      ),
      (
        '/unvip foo',
        'You have removed foo as a VIP of this channel.',
        'DELETE',
        '/helix/channels/vips',
        {},
        {},
      ),
      (
        '/slow',
        '',
        'PATCH',
        '/helix/chat/settings',
        {},
        {'slow_mode_wait_time': 30},
      ),
      (
        '/slow 1m',
        '',
        'PATCH',
        '/helix/chat/settings',
        {},
        {'slow_mode_wait_time': 60},
      ),
      (
        '/slowoff',
        '',
        'PATCH',
        '/helix/chat/settings',
        {},
        {'slow_mode': false},
      ),
      (
        '/followers 1h',
        '',
        'PATCH',
        '/helix/chat/settings',
        {},
        {'follower_mode': true, 'follower_mode_duration': 60},
      ),
      (
        '/followersoff',
        '',
        'PATCH',
        '/helix/chat/settings',
        {},
        {'follower_mode': false},
      ),
      (
        '/emoteonly',
        'Emote-only mode enabled.',
        'PATCH',
        '/helix/chat/settings',
        {},
        {'emote_mode': true},
      ),
      (
        '/emoteonlyoff',
        'Emote-only mode disabled.',
        'PATCH',
        '/helix/chat/settings',
        {},
        {'emote_mode': false},
      ),
      (
        '/commercial 90',
        'Starting 90 second long commercial break.',
        'POST',
        '/helix/channels/commercial',
        {},
        {'broadcaster_id': '111', 'length': 90},
      ),
      (
        '/shield',
        'Shield mode was activated.',
        'PUT',
        '/helix/moderation/shield_mode',
        {},
        {'is_active': true},
      ),
      (
        '/shieldoff',
        'Shield mode was deactivated.',
        'PUT',
        '/helix/moderation/shield_mode',
        {},
        {'is_active': false},
      ),
      (
        '/marker clip this',
        'Stream marker added.',
        'POST',
        '/helix/streams/markers',
        {},
        {'user_id': '111', 'description': 'clip this'},
      ),
      ('/raid foo', '', 'POST', '/helix/raids', {}, {}),
      ('/unraid', '', 'DELETE', '/helix/raids', {}, {}),
      (
        '/w foo hey there',
        'Whisper sent.',
        'POST',
        '/helix/whispers',
        {'from_user_id': '222', 'to_user_id': '999'},
        {'message': 'hey there'},
      ),
      (
        '/block Foo',
        '',
        'PUT',
        '/helix/users/blocks',
        {'target_user_id': '999'},
        {},
      ),
      (
        '/unblock foo',
        '',
        'DELETE',
        '/helix/users/blocks',
        {'target_user_id': '999'},
        {},
      ),
      (
        '/poll best emote | Kappa | PogChamp',
        'Poll started (60s).',
        'POST',
        '/helix/polls',
        {},
        {'title': 'best emote', 'duration': 60},
      ),
      (
        '/poll 2m pick one | x | y | z',
        'Poll started (120s).',
        'POST',
        '/helix/polls',
        {},
        {'title': 'pick one', 'duration': 120},
      ),
      (
        '/prediction wins the game? | yes | no',
        'Prediction started (60s).',
        'POST',
        '/helix/predictions',
        {},
        {'title': 'wins the game?', 'prediction_window': 60},
      ),
    ];

    const hasBody = {
      '/helix/polls',
      '/helix/predictions',
      '/helix/channels/commercial',
      '/helix/moderation/shield_mode',
      '/helix/moderation/warnings',
      '/helix/streams/markers',
      '/helix/chat/settings',
      '/helix/raids',
    };

    test('mutating commands confirm and hit the expected endpoint', () async {
      for (final (command, say, method, path, query, body) in ok) {
        systemMessages.clear();
        final requests = await runCommand(
          command,
          respond: (req) {
            if (req.method == 'DELETE') return http.Response('', 204);
            if (req.url.path == '/helix/moderation/bans') {
              return http.Response('', 200);
            }
            return hasBody.contains(req.url.path)
                ? http.Response('{"data":[{"id":"x","length":90}]}', 200)
                : http.Response('', 204);
          },
          trackBlocks: true,
        );
        final req = requests.lastWhere(
          (r) => r.url.path == path,
          orElse: () => fail('$command sent no request to $path'),
        );
        expect(req.method, method, reason: command);
        query.forEach((k, v) {
          expect(req.url.queryParameters[k], v, reason: '$command $k');
        });
        if (body.isNotEmpty) {
          expectSubset(body, jsonDecode(req.body) as Map, command);
        }
        if (say.isNotEmpty) {
          expect(systemMessages, [say], reason: command);
        }
        expect(irc.sent, isEmpty, reason: command);
      }
    });

    test('poll and prediction choices reach the request body', () async {
      var requests = await runCommand('/poll best emote | Kappa | PogChamp');
      var body = jsonDecode(requests.single.body) as Map;
      expect((body['choices'] as List).map((c) => c['title']), [
        'Kappa',
        'PogChamp',
      ]);
      requests = await runCommand('/prediction wins? | yes | no');
      body = jsonDecode(requests.single.body) as Map;
      expect((body['outcomes'] as List).map((o) => o['title']), ['yes', 'no']);
    });

    test('shoutout is a query-only call', () async {
      final requests = await runCommand('/shoutout foo');
      expect(requests.last.body, isEmpty);
    });
  });

  group('commands that read state first', () {
    const polls =
        '{"data":[{"id":"old","status":"TERMINATED"},'
        '{"id":"live","status":"ACTIVE"}]}';
    const donePolls = '{"data":[{"id":"done","status":"COMPLETED"}]}';
    const prediction =
        '{"data":[{"id":"pr1","status":"ACTIVE","outcomes":['
        '{"id":"o1","title":"Blue"},{"id":"o2","title":"Red"}]}]}';

    // (command, GET /polls body, chat message part, expected PATCH body)
    final cases = <(String, String, String, Map?)>[
      (
        '/endpoll',
        polls,
        'The poll has ended.',
        {'id': 'live', 'status': 'TERMINATED'},
      ),
      ('/endpoll', donePolls, 'No poll is currently running.', null),
      ('/cancelpoll', polls, 'The poll was cancelled.', {'status': 'ARCHIVED'}),
      (
        '/resolveprediction 2',
        '',
        'resolved: Red.',
        {'status': 'RESOLVED', 'winning_outcome_id': 'o2'},
      ),
      (
        '/resolveprediction blue',
        '',
        'resolved: Blue.',
        {'winning_outcome_id': 'o1'},
      ),
      ('/resolveprediction purple', '', 'No outcome matching', null),
      (
        '/lockprediction',
        '',
        'Predictions are now locked.',
        {'status': 'LOCKED', 'winning_outcome_id': absent},
      ),
      ('/cancelprediction', '', 'refunded', {'status': 'CANCELED'}),
    ];

    test('poll and prediction verbs patch the live item', () async {
      for (final (command, pollsBody, say, patch) in cases) {
        systemMessages.clear();
        final requests = await runCommand(
          command,
          respond: (req) {
            if (req.method != 'GET') return http.Response('{"data":[]}', 200);
            return http.Response(
              req.url.path == '/helix/polls' ? pollsBody : prediction,
              200,
            );
          },
        );
        expect(systemMessages.single, contains(say), reason: command);
        final patches = requests.where((r) => r.method == 'PATCH');
        if (patch == null) {
          expect(patches, isEmpty, reason: command);
        } else {
          expectSubset(patch, jsonDecode(patches.single.body) as Map, command);
        }
      }
    });

    for (final (name, body, expected) in [
      (
        'mods lists the channel moderators',
        '{"data":[{"user_login":"alice"},{"user_login":"bob"}]}',
        'The moderators of this channel are alice, bob.',
      ),
      (
        'mods reports when there are none',
        '{"data":[]}',
        'This channel does not have any moderators.',
      ),
      (
        'vips lists the channel VIPs',
        '{"data":[{"user_login":"alice"}]}',
        'The VIPs of this channel are alice.',
      ),
    ]) {
      test(name, () async {
        await runCommand(
          name.startsWith('vips') ? '/vips' : '/mods',
          respond: (_) => http.Response(body, 200),
        );
        expect(systemMessages, [expected]);
      });
    }
  });

  group('command failures', () {
    test('Helix errors surface as chat notices', () async {
      // (command, status or 0 for a network error, body, expected part)
      final cases = <(String, int, String, String)>[
        (
          '/ban foo',
          401,
          '{"message":"Missing required scope"}',
          'Missing required scope',
        ),
        (
          '/warn foo',
          401,
          '{"message":"Missing required scope"}',
          'Missing required scope',
        ),
        ('/unban foo', 403, '{"message":"permission"}', 'permission'),
        ('/announce hi', 403, '{"message":"permission"}', 'permission'),
        (
          '/ban foo',
          0,
          '',
          'Failed to ban user - An unknown error has occurred.',
        ),
        (
          '/ban foo',
          429,
          'Too Many Requests',
          'Failed to ban user - You are being rate-limited. Try again in a moment.',
        ),
        (
          '/unban foo',
          400,
          '{"message":"The user is not banned in this channel."}',
          'Failed to unban user - The user is not banned in this channel.',
        ),
      ];
      for (final (command, status, body, expected) in cases) {
        systemMessages.clear();
        await runCommand(
          command,
          respond: (_) => status == 0
              ? throw http.ClientException('connection reset')
              : http.Response(body, status),
        );
        expect(systemMessages.single, contains(expected), reason: command);
        expect(irc.sent, isEmpty, reason: command);
      }
    });

    test('whisper failure reports through whisper feedback', () async {
      final whisperMessages = <String>[];
      await runCommand(
        '/w foo hey',
        respond: (_) => http.Response('{"message":"rate limit"}', 429),
        whisperMessages: whisperMessages,
      );
      expect(systemMessages, isEmpty);
      expect(whisperMessages.single, contains('Failed to send whisper'));
      expect(whisperMessages.single, contains('rate-limited'));
    });

    test('bad usage is rejected before any request', () async {
      const cases = [
        ('/ban', 'Usage: /ban'),
        ('/warn', 'Usage: /warn'),
        ('/color', 'Usage: /color'),
        ('/w foo', 'Usage: /w'),
        ('/slow 999', 'Usage: /slow'),
        ('/commercial 45', 'Usage: /commercial'),
        ('/announce blue', 'Usage: /announce [color] <message>'),
        ('/poll 5s too fast | a | b', 'Duration'),
        ('/poll only one | a', '2-5 choices'),
      ];
      for (final (command, usage) in cases) {
        systemMessages.clear();
        final requests = await runCommand(command);
        expect(requests, isEmpty, reason: command);
        expect(systemMessages.single, contains(usage), reason: command);
      }
    });

    test('unresolvable ban targets are refused', () async {
      const cases = [
        ('/ban ghost', '{"data":[]}', 'No user matching that username.'),
        (
          '/ban me',
          '{"data":[{"id":"222","login":"me"}]}',
          'Failed to ban user - You cannot ban yourself.',
        ),
        (
          '/ban broadcaster',
          '{"data":[{"id":"111","login":"broadcaster"}]}',
          'Failed to ban user - You cannot ban the broadcaster.',
        ),
      ];
      for (final (command, userBody, expected) in cases) {
        systemMessages.clear();
        final handler = createHandler(
          MockClient((req) async {
            if (req.url.path == '/helix/users') {
              return http.Response(userBody, 200);
            }
            return http.Response('', 200);
          }),
        );
        await handler.handle(command, 'a', auth);
        expect(systemMessages.single, expected, reason: command);
        expect(irc.sent, isEmpty, reason: command);
      }
    });

    test('/w routes feedback and echo through whisper callbacks', () async {
      final whisperMessages = <String>[];
      final whisperSent = <({String target, String message})>[];
      await runCommand(
        '/w foo hey there',
        whisperMessages: whisperMessages,
        whisperSent: whisperSent,
      );
      expect(systemMessages, isEmpty);
      expect(whisperMessages, ['Whisper sent.']);
      expect(whisperSent, [(target: 'foo', message: 'hey there')]);
    });

    test(
      'unknown, unauthenticated and /me never reach Helix wrongly',
      () async {
        await runCommand('/foo bar');
        expect(systemMessages, ['/foo is not a known command']);

        systemMessages.clear();
        final me = await runCommand('/me dances');
        expect(irc.sent, ['/me dances']);
        expect(me, isEmpty);

        irc.sent.clear();
        systemMessages.clear();
        auth.accessToken = null;
        final blockedRequests = await runCommand('/ban foo');
        expect(blockedRequests, isEmpty);
        expect(systemMessages, [
          'You must be logged in to use the /ban command.',
        ]);
        expect(irc.sent, isEmpty);
      },
    );
  });

  group('expired and stale credentials', () {
    test('expired flag serializes only when set', () {
      final expired = TwitchAccount(
        login: 'test',
        accessToken: 'tok',
        expired: true,
      );
      expect(TwitchAccount.fromJson(expired.toJson()).expired, isTrue);
      expect(
        TwitchAccount(login: 'a', accessToken: 't').toJson(),
        isNot(contains('expired')),
      );
    });

    test('markActiveExpired flags the account until new credentials', () async {
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
      named.setCredentials(accessToken: 'new-tok');
      expect(named.isActiveExpired, isFalse);

      final pending = TwitchAuth();
      await pending.load();
      pending.accessToken = 'tok';
      pending.markActiveExpired();
      expect(pending.isActiveExpired, isTrue);
    });

    test('scopeStale is memory-only and clears on credential change', () async {
      final auth = TwitchAuth();
      await auth.load();
      auth.accessToken = 'tok';
      auth.login = 'testuser';
      auth.accounts = [
        TwitchAccount(login: 'testuser', userId: '123', accessToken: 'tok'),
        TwitchAccount(login: 'other', userId: '456', accessToken: 'tok2'),
      ];

      expect(auth.scopeStale, isFalse);
      auth.markScopeStale();
      expect(auth.scopeStale, isTrue);

      auth.setCredentials(accessToken: 'new-tok');
      expect(auth.scopeStale, isFalse);

      auth.markScopeStale();
      await auth.switchTo('other');
      expect(auth.scopeStale, isFalse);

      auth.markScopeStale();
      await auth.switchToAnonymous();
      expect(auth.scopeStale, isFalse);
    });
  });

  test('TwitchApi.validateToken parses 200 and maps failures to null', () async {
    Future<(dynamic, TwitchApi)> validate(
      Future<http.Response> Function(http.Request) handler,
    ) async {
      final api = TwitchApi(client: MockClient(handler));
      final auth = TwitchAuth()..accessToken = 'tok';
      return (await api.validateToken(auth), api);
    }

    final (ok, _) = await validate(
      (_) async => http.Response(
        '{"client_id":"cid","login":"testuser","scopes":["chat:read","chat:edit"],"expires_in":50000,"user_id":"12345"}',
        200,
      ),
    );
    expect(ok.login, 'testuser');
    expect(ok.userId, '12345');
    expect(ok.expiresIn, 50000);
    expect(ok.scopes, ['chat:read', 'chat:edit']);

    final (unauthorized, api401) = await validate(
      (_) async =>
          http.Response('{"status":401,"message":"invalid access token"}', 401),
    );
    expect(unauthorized, isNull);
    expect(api401.lastErrorStatus, 401);

    final (flaky, apiFlaky) = await validate((_) async {
      throw Exception('network');
    });
    expect(flaky, isNull);
    expect(apiFlaky.lastErrorStatus, isNull);
  });

  group('mod inbox api and actions', () {
    MockClient inboxClient(List<http.Request> requests) => MockClient((
      req,
    ) async {
      requests.add(req);
      final path = req.url.path;
      if (req.method == 'GET' && path.endsWith('moderation/unban_requests')) {
        return http.Response(
          '{"data":[{"id":"req1","user_login":"spammer","text":"sorry","status":"pending","created_at":"2026-01-02T03:04:05Z","resolution_text":null}],"pagination":{}}',
          200,
        );
      }
      if (req.method == 'PATCH' && path.endsWith('moderation/unban_requests')) {
        return http.Response('{"data":[]}', 200);
      }
      if (req.method == 'GET' && path.endsWith('moderation/blocked_terms')) {
        return http.Response(
          '{"data":[{"id":"term1","text":"bad word","created_at":"2026-01-02T03:04:05Z"}],"pagination":{}}',
          200,
        );
      }
      if (req.method == 'POST' && path.endsWith('moderation/blocked_terms')) {
        return http.Response(
          '{"data":[{"id":"term2","text":"worse","created_at":"2026-01-02T03:04:05Z"}]}',
          200,
        );
      }
      if (req.method == 'DELETE' && path.endsWith('moderation/blocked_terms')) {
        return http.Response('', 204);
      }
      return http.Response('{"message":"unexpected"}', 404);
    });

    ModActions inboxActions(TwitchApi api) => ModActions(
      twitchApi: api,
      getChannelUserIds: () => {'a': 'broad1'},
      getCurrentUserId: () => 'mod1',
    );

    TwitchAuth inboxAuth() {
      final auth = TwitchAuth();
      auth.accessToken = 'tok';
      return auth;
    }

    test('getUnbanRequests passes ids and status, parses list', () async {
      final requests = <http.Request>[];
      final api = TwitchApi(client: inboxClient(requests));
      final list = await api.getUnbanRequests(
        inboxAuth(),
        broadcasterId: 'broad1',
        moderatorId: 'mod1',
        status: 'pending',
      );
      final query = requests.single.url.queryParameters;
      expect(query['broadcaster_id'], 'broad1');
      expect(query['moderator_id'], 'mod1');
      expect(query['status'], 'pending');
      expect(list, hasLength(1));
      expect(list.first.id, 'req1');
      expect(list.first.userLogin, 'spammer');
      expect(list.first.text, 'sorry');
    });

    test('resolveUnbanRequest approves with resolution text', () async {
      final requests = <http.Request>[];
      final api = TwitchApi(client: inboxClient(requests));
      final ok = await api.resolveUnbanRequest(
        inboxAuth(),
        broadcasterId: 'broad1',
        moderatorId: 'mod1',
        requestId: 'req1',
        approved: true,
        resolutionText: 'second chance',
      );
      expect(ok, isTrue);
      final query = requests.single.url.queryParameters;
      expect(requests.single.method, 'PATCH');
      expect(query['unban_request_id'], 'req1');
      expect(query['status'], 'approved');
      expect(query['resolution_text'], 'second chance');
    });

    test('blocked terms get/add/remove hit the right shapes', () async {
      final requests = <http.Request>[];
      final api = TwitchApi(client: inboxClient(requests));
      final auth = inboxAuth();

      final terms = await api.getBlockedTerms(
        auth,
        broadcasterId: 'broad1',
        moderatorId: 'mod1',
      );
      expect(terms.single.text, 'bad word');

      final created = await api.addBlockedTerm(
        auth,
        broadcasterId: 'broad1',
        moderatorId: 'mod1',
        text: 'worse',
      );
      expect(created!.id, 'term2');
      expect(jsonDecode(requests[1].body)['text'], 'worse');

      final removed = await api.removeBlockedTerm(
        auth,
        broadcasterId: 'broad1',
        moderatorId: 'mod1',
        termId: 'term1',
      );
      expect(removed, isTrue);
      expect(requests[2].url.queryParameters['id'], 'term1');
    });

    test(
      'ModActions inbox wrappers resolve ids and report notJoined',
      () async {
        final requests = <http.Request>[];
        final actions = inboxActions(TwitchApi(client: inboxClient(requests)));
        final auth = inboxAuth();

        final list = await actions.getUnbanRequests(
          auth,
          'a',
          status: 'pending',
        );
        expect(list, hasLength(1));

        final approved = await actions.resolveUnbanRequest(
          auth,
          'a',
          requestId: 'req1',
          approved: false,
        );
        expect(approved.ok, isTrue);
        expect(requests[1].url.queryParameters['status'], 'denied');
        expect(
          requests[1].url.queryParameters.containsKey('resolution_text'),
          isFalse,
        );

        expect(await actions.getUnbanRequests(auth, 'missing'), isEmpty);
        final notJoined = await actions.resolveUnbanRequest(
          auth,
          'missing',
          requestId: 'req1',
          approved: true,
        );
        expect(notJoined.ok, isFalse);
        expect(notJoined.failure, ModFailure.notJoined);

        final added = await actions.addBlockedTerm(auth, 'a', 'worse');
        expect(added.ok, isTrue);
        final removed = await actions.removeBlockedTerm(auth, 'a', 'term1');
        expect(removed.ok, isTrue);
      },
    );

    test('getBannedUsers parses bans and timeouts', () async {
      final requests = <http.Request>[];
      final api = TwitchApi(
        client: MockClient((req) async {
          requests.add(req);
          return http.Response(
            '{"data":['
            '{"user_login":"permaban","expires_at":"","reason":"hate","moderator_name":"moduser"},'
            '{"user_login":"timeoutguy","expires_at":"2026-02-01T00:10:00Z","reason":"","moderator_name":"moduser"}'
            '],"pagination":{}}',
            200,
          );
        }),
      );
      final auth = inboxAuth();
      final list = await api.getBannedUsers(auth, 'broad1');
      expect(requests.single.url.queryParameters['broadcaster_id'], 'broad1');
      expect(list, hasLength(2));
      expect(list[0].userLogin, 'permaban');
      expect(list[0].expiresAt, isNull);
      expect(list[0].reason, 'hate');
      expect(list[1].userLogin, 'timeoutguy');
      expect(list[1].expiresAt, '2026-02-01T00:10:00Z');
      expect(list[1].reason, isNull);

      final actions = inboxActions(api);
      expect(await actions.getBannedUsers(auth, 'missing'), isEmpty);
    });
  });

  group('mod automod settings and suspicious api', () {
    const settingsJson =
        '{"data":[{"broadcaster_id":"broad1","moderator_id":"mod1","overall_level":null,"disability":3,"aggression":4,"sexuality_sex_or_gender":3,"misogyny":3,"bullying":4,"swearing":1,"race_ethnicity_or_religion":3,"sex_based_terms":2}]}';

    MockClient settingsClient(List<http.Request> requests) => MockClient((
      req,
    ) async {
      requests.add(req);
      final path = req.url.path;
      if (req.method == 'GET' && path.endsWith('moderation/automod/settings')) {
        return http.Response(settingsJson, 200);
      }
      if (req.method == 'PUT' && path.endsWith('moderation/automod/settings')) {
        return http.Response(settingsJson, 200);
      }
      if (req.method == 'POST' &&
          path.endsWith('moderation/suspicious_users')) {
        return http.Response('{"data":[]}', 200);
      }
      if (req.method == 'DELETE' &&
          path.endsWith('moderation/suspicious_users')) {
        return http.Response('', 204);
      }
      if (req.url.path == '/helix/users') {
        return http.Response('{"data":[{"id":"u9","login":"spammer"}]}', 200);
      }
      return http.Response('{"message":"unexpected"}', 404);
    });

    ModActions trustActions(TwitchApi api) => ModActions(
      twitchApi: api,
      getChannelUserIds: () => {'a': 'broad1'},
      getCurrentUserId: () => 'mod1',
    );

    TwitchAuth trustAuth() {
      final auth = TwitchAuth();
      auth.accessToken = 'tok';
      return auth;
    }

    test('getAutoModSettings parses levels and null overall', () async {
      final requests = <http.Request>[];
      final api = TwitchApi(client: settingsClient(requests));
      final settings = await api.getAutoModSettings(
        trustAuth(),
        broadcasterId: 'broad1',
        moderatorId: 'mod1',
      );
      expect(settings, isNotNull);
      expect(settings!.overallLevel, isNull);
      expect(settings.levels['bullying'], 4);
      expect(settings.levels['swearing'], 1);
      expect(settings.levels, hasLength(8));
    });

    test('updateAutoModSettings puts levels and parses applied', () async {
      final requests = <http.Request>[];
      final api = TwitchApi(client: settingsClient(requests));
      final applied = await api.updateAutoModSettings(
        trustAuth(),
        broadcasterId: 'broad1',
        moderatorId: 'mod1',
        levels: const {'overall_level': 3},
      );
      expect(requests.single.method, 'PUT');
      expect(jsonDecode(requests.single.body), {'overall_level': 3});
      expect(applied, isNotNull);
    });

    test('suspicious add/remove hit the right shapes', () async {
      final requests = <http.Request>[];
      final api = TwitchApi(client: settingsClient(requests));
      final auth = trustAuth();

      final added = await api.addSuspiciousStatus(
        auth,
        broadcasterId: 'broad1',
        moderatorId: 'mod1',
        userId: 'u9',
        restricted: true,
      );
      expect(added, isTrue);
      expect(jsonDecode(requests[0].body), {
        'user_id': 'u9',
        'status': 'RESTRICTED',
      });

      final monitored = await api.addSuspiciousStatus(
        auth,
        broadcasterId: 'broad1',
        moderatorId: 'mod1',
        userId: 'u9',
        restricted: false,
      );
      expect(monitored, isTrue);
      expect(jsonDecode(requests[1].body)['status'], 'ACTIVE_MONITORING');

      final cleared = await api.removeSuspiciousStatus(
        auth,
        broadcasterId: 'broad1',
        moderatorId: 'mod1',
        userId: 'u9',
      );
      expect(cleared, isTrue);
      expect(requests[2].url.queryParameters['user_id'], 'u9');
    });

    test('ModActions trust wrappers resolve users and report', () async {
      final requests = <http.Request>[];
      final actions = trustActions(TwitchApi(client: settingsClient(requests)));
      final auth = trustAuth();

      final settings = await actions.getAutoModSettings(auth, 'a');
      expect(settings, isNotNull);
      expect(await actions.getAutoModSettings(auth, 'missing'), isNull);

      final saved = await actions.updateAutoModSettings(auth, 'a', const {
        'bullying': 4,
      });
      expect(saved.ok, isTrue);
      final notJoined = await actions.updateAutoModSettings(
        auth,
        'missing',
        const {'bullying': 4},
      );
      expect(notJoined.ok, isFalse);
      expect(notJoined.failure, ModFailure.notJoined);

      final restricted = await actions.setSuspiciousStatus(
        auth,
        'a',
        login: 'spammer',
        restricted: true,
      );
      expect(restricted.ok, isTrue);
      final cleared = await actions.clearSuspiciousStatus(
        auth,
        'a',
        login: 'spammer',
      );
      expect(cleared.ok, isTrue);
    });
  });

  group('mod points api and actions', () {
    const rewardsJson =
        '{"data":[{"id":"reward1","title":"Hydrate","cost":500,"is_enabled":true,"is_paused":false}],"pagination":{}}';
    const redemptionsJson =
        '{"data":[{"id":"red1","user_login":"fan","user_input":"do a flip","status":"UNFULFILLED","redeemed_at":"2026-01-02T03:04:05Z","reward":{"id":"reward1","title":"Hydrate","cost":500}}],"pagination":{}}';

    MockClient pointsClient(List<http.Request> requests) => MockClient((
      req,
    ) async {
      requests.add(req);
      final path = req.url.path;
      if (req.method == 'GET' &&
          path.endsWith('channel_points/custom_rewards')) {
        return http.Response(rewardsJson, 200);
      }
      if (req.method == 'PATCH' &&
          path.endsWith('channel_points/custom_rewards')) {
        return http.Response(rewardsJson, 200);
      }
      if (req.method == 'GET' && path.endsWith('custom_rewards/redemptions')) {
        return http.Response(redemptionsJson, 200);
      }
      if (req.method == 'PATCH' &&
          path.endsWith('custom_rewards/redemptions')) {
        return http.Response('{"data":[]}', 200);
      }
      return http.Response('{"message":"unexpected"}', 404);
    });

    TwitchAuth pointsAuth() {
      final auth = TwitchAuth();
      auth.accessToken = 'tok';
      return auth;
    }

    test('rewards and redemptions parse', () async {
      final requests = <http.Request>[];
      final api = TwitchApi(client: pointsClient(requests));
      final auth = pointsAuth();

      final rewards = await api.getCustomRewards(auth, broadcasterId: 'broad1');
      expect(requests.single.url.queryParameters['broadcaster_id'], 'broad1');
      expect(rewards.single.title, 'Hydrate');
      expect(rewards.single.cost, 500);
      expect(rewards.single.isPaused, isFalse);

      final queue = await api.getRedemptions(
        auth,
        broadcasterId: 'broad1',
        rewardId: 'reward1',
      );
      final query = requests[1].url.queryParameters;
      expect(query['reward_id'], 'reward1');
      expect(query['status'], 'UNFULFILLED');
      expect(queue.single.userLogin, 'fan');
      expect(queue.single.userInput, 'do a flip');
    });

    test('pause and fulfill hit the right shapes', () async {
      final requests = <http.Request>[];
      final api = TwitchApi(client: pointsClient(requests));
      final auth = pointsAuth();

      final paused = await api.setRewardPaused(
        auth,
        broadcasterId: 'broad1',
        rewardId: 'reward1',
        paused: true,
      );
      expect(paused, isTrue);
      expect(requests.single.method, 'PATCH');
      expect(requests.single.url.queryParameters['id'], 'reward1');
      expect(jsonDecode(requests.single.body), {'is_paused': true});

      final fulfilled = await api.updateRedemptionStatus(
        auth,
        broadcasterId: 'broad1',
        rewardId: 'reward1',
        redemptionId: 'red1',
        fulfilled: false,
      );
      expect(fulfilled, isTrue);
      expect(requests[1].url.queryParameters['id'], 'red1');
      expect(jsonDecode(requests[1].body), {'status': 'CANCELED'});
    });

    test('ModActions points wrappers need a joined channel', () async {
      final requests = <http.Request>[];
      final actions = ModActions(
        twitchApi: TwitchApi(client: pointsClient(requests)),
        getChannelUserIds: () => {'a': 'broad1'},
        getCurrentUserId: () => 'mod1',
      );
      final auth = pointsAuth();

      expect(await actions.getPointRewards(auth, 'a'), hasLength(1));
      expect(await actions.getPointRewards(auth, 'missing'), isEmpty);
      expect(
        await actions.getPointRedemptions(auth, 'a', 'reward1'),
        hasLength(1),
      );

      final paused = await actions.setRewardPaused(auth, 'a', 'reward1', true);
      expect(paused.ok, isTrue);
      final notJoined = await actions.setRewardPaused(
        auth,
        'missing',
        'reward1',
        true,
      );
      expect(notJoined.ok, isFalse);

      final fulfilled = await actions.resolveRedemption(
        auth,
        'a',
        'reward1',
        'red1',
        true,
      );
      expect(fulfilled.ok, isTrue);
    });
  });

  group('TwitchApi.getFollowDate', () {
    test('returns followed_at when following', () async {
      final client = MockClient((request) async {
        expect(request.url.queryParameters['broadcaster_id'], 'broad1');
        expect(request.url.queryParameters['user_id'], 'user9');
        return http.Response(
          '{"total":1,"data":[{"user_id":"user9","followed_at":"2024-05-06T07:08:09Z"}],"pagination":{}}',
          200,
        );
      });

      final api = TwitchApi(client: client);
      final auth = TwitchAuth();
      auth.accessToken = 'tok';

      expect(
        await api.getFollowDate(auth, broadcasterId: 'broad1', userId: 'user9'),
        '2024-05-06T07:08:09Z',
      );
    });

    test('returns null when not following or on failure', () async {
      final empty = TwitchApi(
        client: MockClient(
          (request) async =>
              http.Response('{"total":0,"data":[],"pagination":{}}', 200),
        ),
      );
      final auth = TwitchAuth();
      auth.accessToken = 'tok';
      expect(
        await empty.getFollowDate(
          auth,
          broadcasterId: 'broad1',
          userId: 'user9',
        ),
        isNull,
      );

      final failing = TwitchApi(
        client: MockClient(
          (request) async => http.Response('{"message":"forbidden"}', 403),
        ),
      );
      expect(
        await failing.getFollowDate(
          auth,
          broadcasterId: 'broad1',
          userId: 'user9',
        ),
        isNull,
      );
      expect(failing.lastErrorStatus, 403);
    });
  });

  test(
    'IrcService signals auth failure only for the global login notice',
    () async {
      const lines = {
        ':tmi.twitch.tv NOTICE * :Login authentication failed': 1,
        '@msg-id=slow_on :tmi.twitch.tv NOTICE #xqc :This room is now in slow mode.':
            0,
        ':tmi.twitch.tv NOTICE * :Some other connection notice': 0,
      };
      for (final MapEntry(key: line, value: expected) in lines.entries) {
        final service = IrcService();
        final authFailed = <void>[];
        service.onAuthFailed.listen((_) => authFailed.add(null));
        service.handleLine(line);
        await Future<void>.delayed(Duration.zero);
        expect(authFailed, hasLength(expected), reason: line);
        service.dispose();
      }
    },
  );

  test('services close their injected http clients', () {
    final clients = List.generate(3, (_) => _RecordingClient());
    TwitchApi(client: clients[0]).close();
    TwitchBadgeService(client: clients[1]).close();
    MediaUploader(client: clients[2]).close();
    expect(clients.map((c) => c.closed), everyElement(isTrue));
  });

  test('session apply announces, seed and clear stay silent', () {
    final session = Session();
    addTearDown(session.dispose);
    var ticks = 0;
    session.version.addListener(() => ticks++);

    session.seed('alice', userId: '1');
    expect(session.login, 'alice');
    expect(session.userId, '1');
    expect(ticks, 0, reason: 'seed must not announce');

    session.apply('bob', userId: '2');
    expect(session.login, 'bob');
    expect(session.userId, '2');
    expect(ticks, 1);

    session.apply('bob', keepUserId: true);
    expect(session.userId, '2', reason: 'keepUserId preserves the id');
    expect(ticks, 2);

    session.clear();
    expect(session.login, isNull);
    expect(session.userId, isNull);
    expect(ticks, 2, reason: 'clear stays silent');
  });
}
