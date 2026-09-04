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

    test('clear removes tokens and cached user', () async {
      final auth = TwitchAuth();
      auth.setCredentials(
        accessToken: 'test_token',
        refreshToken: 'test_refresh',
      );
      auth.setUser('testuser', '12345');
      await auth.clear();
      expect(auth.accessToken, isNull);
      expect(auth.refreshToken, isNull);
      expect(auth.isConfigured, isFalse);
      expect(auth.login, isNull);
      expect(auth.userId, isNull);
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

    test('setUser ignores a result attributed to a superseded token', () async {
      final auth = TwitchAuth();
      auth.setCredentials(accessToken: 'token_a');
      auth.setUser('alice', '111');
      // A Helix lookup for alice's identity is now in flight...
      final tokenAtStart = auth.accessToken;

      auth.setCredentials(accessToken: 'token_b');
      auth.setUser('bob', '222');
      await auth.switchTo('bob');

      // ...but resolves after the user switched to bob.
      auth.setUser('alice', '111', resolvedWithToken: tokenAtStart);
      expect(auth.login, 'bob');
      expect(auth.userId, '222');
      expect(auth.accessToken, 'token_b');
      // alice's registry entry must not have been corrupted either.
      expect(
        auth.accounts.firstWhere((a) => a.login == 'alice').accessToken,
        'token_a',
      );
    });

    test(
      'setUser applies a result attributed to the still-active token',
      () async {
        final auth = TwitchAuth();
        auth.setCredentials(accessToken: 'token_a');
        auth.setUser('alice', '111', resolvedWithToken: 'token_a');
        expect(auth.login, 'alice');
        expect(auth.userId, '111');
        expect(auth.accounts.single.accessToken, 'token_a');
      },
    );

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

    test('returns empty map for URL without fragment', () {
      final url = 'https://example.com/twitch-callback';
      final params = TwitchOAuth.parseFragment(url);
      expect(params, isEmpty);
    });

    test('returns empty map when no auth-related params present', () {
      final url = 'https://example.com/twitch-callback#foo=bar';
      final params = TwitchOAuth.parseFragment(url);
      expect(params['access_token'], isNull);
      expect(params['state'], isNull);
      expect(params['error'], isNull);
      expect(params['foo'], 'bar');
    });

    test('handles URL with query params and fragment', () {
      final url =
          'https://example.com/twitch-callback'
          '?some=query'
          '#access_token=token123&state=abc';
      final params = TwitchOAuth.parseFragment(url);
      // parseFragment only looks at the fragment, not query params
      expect(params['access_token'], 'token123');
      expect(params['state'], 'abc');
    });

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
    test('requests blocked_users scopes for the block feature', () {
      final urlInfo = TwitchOAuth.generateAuthUrl();
      expect(urlInfo, isNotNull);

      final url = Uri.parse(urlInfo!.url);
      final scopes = url.queryParameters['scope']!.split(' ');
      expect(
        scopes,
        containsAll(['user:manage:blocked_users', 'user:read:blocked_users']),
      );
    });

    test('requests core chat scopes', () {
      final urlInfo = TwitchOAuth.generateAuthUrl();
      expect(urlInfo, isNotNull);

      final url = Uri.parse(urlInfo!.url);
      final scopes = url.queryParameters['scope']!.split(' ');
      expect(
        scopes,
        containsAll([
          'chat:read',
          'chat:edit',
          'user:write:chat',
          'user:manage:chat_color',
          'moderator:manage:banned_users',
          'moderator:manage:chat_messages',
          'moderator:manage:announcements',
          'moderator:manage:shoutouts',
        ]),
      );
    });

    test('requests scopes for the extended command set', () {
      final urlInfo = TwitchOAuth.generateAuthUrl();
      expect(urlInfo, isNotNull);

      final url = Uri.parse(urlInfo!.url);
      final scopes = url.queryParameters['scope']!.split(' ');
      expect(
        scopes,
        containsAll([
          'moderator:manage:chat_settings',
          'channel:manage:moderators',
          'channel:manage:vips',
          'channel:edit:commercial',
          'channel:manage:raids',
          'moderator:manage:shield_mode',
          'channel:manage:broadcast',
          'user:manage:whispers',
        ]),
      );
    });

    test('requests EventSub moderation scopes', () {
      final urlInfo = TwitchOAuth.generateAuthUrl();
      expect(urlInfo, isNotNull);

      final url = Uri.parse(urlInfo!.url);
      final scopes = url.queryParameters['scope']!.split(' ');
      // channel.moderate v2 rejects the subscription without these.
      expect(
        scopes,
        containsAll([
          'moderator:read:blocked_terms',
          'moderator:read:unban_requests',
        ]),
      );
    });

    test('does not request EventSub-only scopes', () {
      final urlInfo = TwitchOAuth.generateAuthUrl();
      expect(urlInfo, isNotNull);

      final url = Uri.parse(urlInfo!.url);
      final scopes = url.queryParameters['scope']!.split(' ');
      expect(scopes, isNot(contains('user:read:chat')));
      expect(scopes, isNot(contains('channel:moderate')));
    });
  });

  group('UserStore', () {
    test('touches user moves to end of LRU', () {
      final store = UserStore();
      store.addUser('chan', 'User1');
      store.addUser('chan', 'User2');
      store.addUser('chan', 'User1');
      final users = store.usersForChannel('chan');
      final list = users.toList();
      expect(list.first, 'User2');
      expect(list.last, 'User1');
    });

    test('isolates channels', () {
      final store = UserStore();
      store.addUser('chan1', 'User1');
      store.addUser('chan2', 'User2');
      expect(store.usersForChannel('chan1'), {'User1'});
      expect(store.usersForChannel('chan2'), {'User2'});
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

    test('removeChannel clears channel', () {
      final store = UserStore();
      store.addUser('chan', 'User1');
      store.removeChannel('chan');
      expect(store.usersForChannel('chan'), isEmpty);
    });

    test('ignores empty display name', () {
      final store = UserStore();
      store.addUser('chan', '');
      expect(store.usersForChannel('chan'), isEmpty);
    });
  });

  group('AnalyticsService', () {
    test('records totals, unique chatters and top chatters', () {
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
    });

    test('excludes system, history and backfill messages', () {
      final service = AnalyticsService();
      service.recordMessage('chan', msg('alice', 'real'));
      service.recordMessage('chan', msg('bot', 'sys', isSystem: true));
      service.recordMessage('chan', msg('bot', 'hist', isHistory: true));
      service.recordMessage('chan', msg('bot', 'back', isBackfill: true));

      expect(service.totalMessages('chan'), 1);
      expect(service.uniqueChatters('chan'), 1);
    });

    test('ignores blank logins', () {
      final service = AnalyticsService();
      service.recordMessage('chan', msg('', 'anon'));

      expect(service.totalMessages('chan'), 1);
      expect(service.uniqueChatters('chan'), 0);
      expect(service.topChatters('chan', 10), isEmpty);
    });

    test('counts twitch emotes from positions and remaining text as words', () {
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
    });

    test('counts third-party emotes by token match', () {
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
    });

    test('twitch positions take precedence over token match', () {
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
    });

    test('normalizes words and strips punctuation', () {
      final service = AnalyticsService();
      service.recordMessage('chan', msg('alice', 'Hello, world!!'));

      final words = service.topWords('chan', 10);
      expect(words, hasLength(2));
      expect(words.any((w) => w.word == 'hello'), isTrue);
      expect(words.any((w) => w.word == 'world'), isTrue);
    });

    test('stopword filter excludes common words', () {
      final service = AnalyticsService();
      service.recordMessage('chan', msg('alice', 'the cat and dog'));

      final raw = service.topWords('chan', 10);
      expect(raw, hasLength(4));

      final filtered = service.topWords('chan', 10, useStopwords: true);
      final filteredWords = filtered.map((w) => w.word).toList();
      expect(filteredWords, contains('cat'));
      expect(filteredWords, contains('dog'));
      expect(filteredWords, isNot(contains('the')));
      expect(filteredWords, isNot(contains('and')));
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

    test('resets single channel', () {
      final service = AnalyticsService();
      service.recordMessage('chan', msg('alice', 'hi'));
      service.recordMessage('other', msg('bob', 'yo'));

      service.resetChannel('chan');
      expect(service.isTracking('chan'), isFalse);
      expect(service.totalMessages('chan'), 0);
      expect(service.isTracking('other'), isTrue);
    });

    test('resets all channels', () {
      final service = AnalyticsService();
      service.recordMessage('chan', msg('alice', 'hi'));
      service.recordMessage('other', msg('bob', 'yo'));

      service.resetAll();
      expect(service.trackedChannels(), isEmpty);
    });

    test('notifies listeners on record', () async {
      final service = AnalyticsService();
      var notified = 0;
      service.addListener(() => notified++);

      service.recordMessage('chan', msg('alice', 'hi'));
      service.recordModeration('chan', true);

      // Notifications are coalesced into a single microtask turn.
      await Future<void>.delayed(Duration.zero);
      expect(notified, 1);
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

      expect(systemMessages, ['foo timed out for 10m.']);
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

  group('warn', () {
    test('/warn success via Helix posts user_id and reason', () async {
      final requests = <http.Request>[];
      final handler = createHandler(
        MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('{"data":[{"id":"w1"}]}', 200);
        }),
      );

      await handler.handle('/warn foo spamming', 'a', auth);

      expect(systemMessages, ['foo has been warned.']);
      expect(irc.sent, isEmpty);
      final req = requests.firstWhere(
        (r) => r.url.path == '/helix/moderation/warnings',
      );
      expect(req.method, 'POST');
      expect(req.url.queryParameters['broadcaster_id'], '111');
      expect(req.url.queryParameters['moderator_id'], '222');
      final body = jsonDecode(req.body) as Map;
      expect((body['data'] as Map)['user_id'], '999');
      expect((body['data'] as Map)['reason'], 'spamming');
    });

    test('/warn without reason omits it from the body', () async {
      http.Request? captured;
      final handler = createHandler(
        MockClient((req) async {
          if (req.url.path == '/helix/users') return userFound();
          captured = req;
          return http.Response('{"data":[]}', 200);
        }),
      );

      await handler.handle('/warn foo', 'a', auth);

      expect(systemMessages, ['foo has been warned.']);
      final body = jsonDecode(captured!.body) as Map;
      expect(body['data'].containsKey('reason'), isFalse);
    });

    test('/warn with no args shows usage', () async {
      final handler = createHandler(
        MockClient((req) async => http.Response('', 200)),
      );
      await handler.handle('/warn', 'a', auth);
      expect(systemMessages, ['Usage: /warn <username> [reason]']);
    });

    test('/warn reports failure on 401 (missing scopes)', () async {
      final handler = createHandler(
        MockClient((req) async {
          if (req.url.path == '/helix/users') return userFound();
          return http.Response('{"message":"Missing scope"}', 401);
        }),
      );

      await handler.handle('/warn foo', 'a', auth);

      expect(irc.sent, isEmpty);
      expect(
        systemMessages.single,
        'Failed to warn user - Missing required scope. Re-login with your account and try again.',
      );
    });
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

    test('/poll rejects out-of-range duration and single choice', () async {
      final handler = createHandler(
        MockClient((req) async => http.Response('{"data":[]}', 200)),
      );

      await handler.handle('/poll 5s too fast | a | b', 'a', auth);
      expect(systemMessages.single, contains('Duration'));

      systemMessages.clear();
      await handler.handle('/poll only one | a', 'a', auth);
      expect(systemMessages.single, contains('2-5 choices'));
    });

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

    test('/endpoll without an active poll says so', () async {
      final handler = createHandler(
        MockClient(
          (req) async => http.Response(
            '{"data":[{"id":"done","status":"COMPLETED"}]}',
            200,
          ),
        ),
      );

      await handler.handle('/endpoll', 'a', auth);

      expect(systemMessages, ['No poll is currently running.']);
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

    test('/resolveprediction unknown outcome reports it', () async {
      final handler = createHandler(
        MockClient((req) async {
          if (req.url.path == '/helix/predictions' && req.method == 'GET') {
            return http.Response(
              '{"data":[{"id":"pr1","status":"OPEN","outcomes":['
              '{"id":"o1","title":"Blue"}]}]}',
              200,
            );
          }
          return http.Response('{"data":[]}', 200);
        }),
      );

      await handler.handle('/resolveprediction purple', 'a', auth);

      expect(systemMessages, ['No outcome matching "purple".']);
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
