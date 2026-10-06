import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/recent_messages.dart';
import 'dart:convert';
import 'package:http/testing.dart';
import 'package:ermchat/services/mod_actions.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/twitch_config.dart';
import 'package:ermchat/eventsub/decode/decoder.dart';
import 'package:ermchat/eventsub/decode/events.dart';
import 'package:ermchat/irc/decode/codec.dart';
import 'package:ermchat/irc/message.dart';

import 'package:http/http.dart' as http;

Map<String, dynamic> _moderate({
  required String action,
  Map<String, dynamic>? meta,
  String moderatorName = 'moduser',
  String? moderatorUserId,
}) => <String, dynamic>{
  'metadata': <String, dynamic>{
    'message_type': 'notification',
    'subscription_type': 'channel.moderate',
  },
  'payload': <String, dynamic>{
    'subscription': <String, dynamic>{
      'condition': <String, dynamic>{'broadcaster_user_id': 'broadcaster1'},
    },
    'event': <String, dynamic>{
      'action': action,
      'moderator_user_name': moderatorName,
      'moderator_user_id': moderatorUserId,
      ...?meta,
    },
  },
};

void main() {
  group('parseIrcLine', () {
    const purple = Color(0xFF7C47D1);
    const ts = 'rm-received-ts=1700000000000';
    const user = ':forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc';

    test('parses PRIVMSG fields, timestamp and palette fallback', () {
      final msg = RecentMessagesService.parseIrcLine(
        '@display-name=forsen;color=#FF0000;id=abc-123;$ts $user :Hello chat',
      )!;
      expect(msg.login, 'forsen');
      expect(msg.text, 'Hello chat');
      expect(msg.color, '#FF0000');
      expect(msg.messageId, 'abc-123');
      expect(msg.isHistory, isTrue);
      expect(msg.channel, isNull);
      expect(msg.timestamp.millisecondsSinceEpoch, 1700000000000);
      expect(msg.bitsAmount, isNull);
      expect(msg.systemAccent, isNull);
      expect(msg.msgId, isNull);
      expect(msg.customRewardId, isNull);
      expect(msg.pinnedPaidAmount, isNull);

      final a = RecentMessagesService.parseIrcLine(
        '@display-name=forsen;id=a;$ts $user :one',
      )!;
      final b = RecentMessagesService.parseIrcLine(
        '@display-name=forsen;id=b;$ts $user :two',
      )!;
      expect(a.color, startsWith('#'));
      expect(a.color, b.color, reason: 'palette color is stable per user');
    });

    test('parses single-word message without trailing colon', () {
      final msg = RecentMessagesService.parseIrcLine(
        '@display-name=t;id=s;$ts :t!t@t.tmi.twitch.tv PRIVMSG #xqc eerm',
      )!;
      expect(msg.login, 't');
      expect(msg.text, 'eerm');
    });

    test('parses cheer and highlight tags', () {
      final cheer = RecentMessagesService.parseIrcLine(
        '@badges=bits/1000;bits=100;display-name=ronni;id=c1;$ts $user :Cheer100 bits',
      )!;
      expect(cheer.bitsAmount, 100);
      expect(cheer.systemAccent, purple);

      final hl = RecentMessagesService.parseIrcLine(
        '@msg-id=highlighted-message;custom-reward-id=reward-9;pinned-chat-paid-amount=100;display-name=forsen;id=e1 $user :yo',
      )!;
      expect(hl.msgId, 'highlighted-message');
      expect(hl.customRewardId, 'reward-9');
      expect(hl.pinnedPaidAmount, '100');
    });

    test('parses reply tags, unescapes the body and keeps bad escapes', () {
      final msg = RecentMessagesService.parseIrcLine(
        '@display-name=forsen;id=r;$ts;reply-parent-msg-id=p1;reply-parent-display-name=Prev;reply-parent-msg-body=original\\smessage $user :@Prev reply text',
      )!;
      expect(msg.replyToParentId, 'p1');
      expect(msg.replyToUser, 'Prev');
      expect(msg.replyToText, 'original message');
      expect(msg.text, 'reply text');

      final bad = RecentMessagesService.parseIrcLine(
        '@display-name=forsen;id=r2;$ts;reply-parent-msg-id=p1;reply-parent-display-name=Prev;reply-parent-msg-body=unknown\\qescape $user :@Prev hi',
      )!;
      expect(bad.replyToText, r'unknown\qescape');
    });

    test('reply emote offsets shift past the stripped mention', () {
      // Offsets index the original text; stripping '@SomeUser ' must not
      // push the range past the end of the shortened text.
      final reply = RecentMessagesService.parseIrcLine(
        '@display-name=t;id=e1;$ts;reply-parent-msg-id=p;reply-parent-display-name=SomeUser;reply-parent-msg-body=hi;emotes=123456:16-22 $user :@SomeUser hello forsenE',
      )!;
      expect(reply.text, 'hello forsenE');
      final p = reply.emotePositions!.single;
      expect(
        (p.emoteId, p.emoteCode, p.startIndex, p.endIndex),
        ('123456', 'forsenE', 6, 13),
      );

      final plain = RecentMessagesService.parseIrcLine(
        '@display-name=t;id=e2;$ts;emotes=123456:6-12 $user :hello forsenE',
      )!;
      final q = plain.emotePositions!.single;
      expect((q.emoteCode, q.startIndex, q.endIndex), ('forsenE', 6, 13));
    });

    test('returns null for lines that are not chat', () {
      for (final (name, raw) in [
        ('JOIN', '@display-name=forsen :tmi.twitch.tv JOIN #xqc'),
        (
          'empty display-name and text',
          '@display-name=;id=z :user!user@user.tmi.twitch.tv PRIVMSG #xqc :',
        ),
        (
          'CLEARCHAT without trailing',
          '@ban-duration=300;$ts :tmi.twitch.tv CLEARCHAT #ermugo2',
        ),
        (
          'USERNOTICE without msg-id',
          '@login=ronni;display-name=ronni;$ts :tmi.twitch.tv USERNOTICE #xqc :hello',
        ),
        ('NOTICE without text', ':tmi.twitch.tv NOTICE #xqc'),
      ]) {
        printOnFailure(name);
        expect(RecentMessagesService.parseIrcLine(raw), isNull);
      }
    });

    test('parses CLEARCHAT forms', () {
      for (final (name, raw, text, channel, own) in [
        (
          'timeout',
          '@ban-duration=300;target-user-id=974273622;$ts;historical=1 :tmi.twitch.tv CLEARCHAT #ermugo2 :ermugo1',
          'ermugo1 was timed out for 5m.',
          null,
          null,
        ),
        (
          'ban',
          '@target-user-id=974273622;$ts :tmi.twitch.tv CLEARCHAT #ermugo2 :ermugo1',
          'ermugo1 was banned.',
          null,
          null,
        ),
        (
          'own timeout reads in the second person',
          '@ban-duration=300;target-user-id=974273622;$ts;historical=1 :tmi.twitch.tv CLEARCHAT #ermugo2 :ermugo1',
          'You are timed out for 5m.',
          null,
          'ErmUgo1',
        ),
        (
          'own ban reads in the second person',
          '@target-user-id=974273622;$ts :tmi.twitch.tv CLEARCHAT #ermugo2 :ermugo1',
          'You were banned.',
          null,
          'ermugo1',
        ),
        (
          'robotty form without trailing colon',
          '@ban-duration=300;target-user-id=974273622;$ts;historical=1 :tmi.twitch.tv CLEARCHAT #ermugo2 ermugo1',
          'ermugo1 was timed out for 5m.',
          null,
          null,
        ),
        (
          'channel parameter',
          '@ban-duration=1;$ts :tmi.twitch.tv CLEARCHAT #ermugo2 :ermugo1',
          null,
          'ermugo2',
          null,
        ),
      ]) {
        printOnFailure(name);
        final msg = RecentMessagesService.parseIrcLine(
          raw,
          channel: channel,
          ownLogin: own,
        )!;
        expect(msg.isSystem, isTrue);
        expect(msg.isHistory, isTrue);
        expect(msg.isBanNotice, isTrue);
        if (text != null) expect(msg.text, text);
        expect(msg.channel, channel);
      }
    });

    test('parses USERNOTICE forms', () {
      for (final (name, raw, text, login, accent, id) in [
        (
          'resub with user message',
          '@msg-id=resub;system-msg=ronni\\shas\\ssubscribed\\sfor\\s6\\smonths!;login=ronni;display-name=ronni;id=notice-1;$ts :tmi.twitch.tv USERNOTICE #xqc :Great stream!',
          'ronni has subscribed for 6 months!',
          '',
          purple,
          'notice-1:label',
        ),
        (
          'label without an id',
          '@msg-id=resub;system-msg=ronni\\shas\\ssubscribed!;login=ronni;display-name=ronni;$ts :tmi.twitch.tv USERNOTICE #xqc',
          'ronni has subscribed!',
          '',
          purple,
          null,
        ),
        (
          'subgift',
          '@msg-id=subgift;system-msg=TWW2\\sgifted\\sa\\sTier\\s1\\ssub\\sto\\sMr_Woodchuck!;login=tww2;display-name=TWW2;$ts :tmi.twitch.tv USERNOTICE #xqc',
          'TWW2 gifted a Tier 1 sub to Mr_Woodchuck!',
          '',
          purple,
          null,
        ),
        (
          'raid',
          '@msg-id=raid;system-msg=ronni\\sis\\sraiding\\sxqc!;login=ronni;display-name=ronni;$ts :tmi.twitch.tv USERNOTICE #xqc',
          'ronni is raiding xqc!',
          '',
          purple,
          null,
        ),
        (
          'announcement with color',
          '@msg-id=announcement;msg-param-color=BLUE;login=mm2pl;display-name=Mm2PL;$ts :tmi.twitch.tv USERNOTICE #xqc :my primary color',
          'Announcement',
          'mm2pl',
          const Color(0xFF1F69FF),
          null,
        ),
        (
          'announcement without color',
          '@msg-id=announcement;login=mm2pl;display-name=Mm2PL;$ts :tmi.twitch.tv USERNOTICE #xqc :hello',
          'Announcement',
          'mm2pl',
          purple,
          null,
        ),
        (
          'empty announcement',
          '@msg-id=announcement;msg-param-color=ORANGE;login=mm2pl;display-name=Mm2PL;$ts :tmi.twitch.tv USERNOTICE #xqc',
          'Announcement',
          'mm2pl',
          const Color(0xFFFF6F00),
          null,
        ),
      ]) {
        printOnFailure(name);
        final msg = RecentMessagesService.parseIrcLine(raw)!;
        expect(msg.isSystem, isTrue);
        expect(msg.text, text);
        expect(msg.login, login);
        expect(msg.systemAccent, accent);
        expect(msg.messageId, id);
      }
    });

    test('parses NOTICE, falling back to parse time without a timestamp', () {
      final msg = RecentMessagesService.parseIrcLine(
        '@msg-id=slow_on;$ts :tmi.twitch.tv NOTICE #xqc :This room is now in slow mode.',
      )!;
      expect(msg.isSystem, isTrue);
      expect(msg.text, 'This room is now in slow mode.');
      expect(msg.isHistory, isTrue);

      final live = RecentMessagesService.parseIrcLine(
        '@msg-id=slow_on :tmi.twitch.tv NOTICE #xqc :slow',
      )!;
      expect(
        DateTime.now().difference(live.timestamp).abs(),
        lessThan(const Duration(seconds: 5)),
      );
    });
  });

  group('parseAnnouncementChild / parseSubChild', () {
    const purple = Color(0xFF7C47D1);
    const ts = 'rm-received-ts=1700000000000';

    test('announcement child is a normal chat message with its accent', () {
      final child = RecentMessagesService.parseAnnouncementChild(
        '@msg-id=announcement;msg-param-color=BLUE;login=mm2pl;display-name=Mm2PL;color=#FF0000;badges=broadcaster/1;id=abc-123;user-id=456;emotes=emotesv2_123:0-7;$ts :tmi.twitch.tv USERNOTICE #xqc :PogChamp test',
      )!;
      expect(child.isSystem, isFalse);
      expect(child.text, 'PogChamp test');
      expect(child.login, 'mm2pl');
      expect(child.displayName, 'Mm2PL');
      expect(child.color, '#FF0000');
      expect(child.userId, '456');
      expect(child.messageId, 'abc-123');
      expect(child.badges!.single.setId, 'broadcaster');
      expect(child.systemAccent, const Color(0xFF1F69FF));
      expect(child.isHistory, isTrue);
      expect(
        child.timestamp,
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final e = child.emotePositions!.single;
      expect((e.emoteCode, e.startIndex, e.endIndex), ('PogChamp', 0, 8));
    });

    test('sub child is a normal chat message with the default accent', () {
      final child = RecentMessagesService.parseSubChild(
        '@msg-id=resub;system-msg=ronni\\shas\\ssubscribed;login=ronni;display-name=ronni;color=#0000FF;badges=subscriber/6;id=abc-123;user-id=456;emotes=emotesv2_123:0-7;$ts :tmi.twitch.tv USERNOTICE #xqc :PogChamp test',
      )!;
      expect(child.isSystem, isFalse);
      expect(child.text, 'PogChamp test');
      expect(child.login, 'ronni');
      expect(child.color, '#0000FF');
      expect(child.userId, '456');
      expect(child.messageId, 'abc-123');
      expect(child.badges!.single.setId, 'subscriber');
      expect(child.systemAccent, purple);
      expect(child.isHistory, isTrue);
      expect(child.emotePositions!.single.emoteCode, 'PogChamp');
    });

    test('parseAnnouncementChild rejects non-announcements', () {
      for (final (name, raw) in [
        (
          'non-announcement USERNOTICE',
          '@msg-id=resub;login=ronni;$ts :tmi.twitch.tv USERNOTICE #xqc :Great stream!',
        ),
        (
          'announcement without text',
          '@msg-id=announcement;msg-param-color=ORANGE;login=mm2pl;$ts :tmi.twitch.tv USERNOTICE #xqc',
        ),
        (
          'PRIVMSG',
          '@display-name=forsen :f!f@f.tmi.twitch.tv PRIVMSG #xqc :hi',
        ),
      ]) {
        printOnFailure(name);
        expect(RecentMessagesService.parseAnnouncementChild(raw), isNull);
      }
    });

    test('parseSubChild rejects non-subs', () {
      for (final (name, raw) in [
        (
          'announcement USERNOTICE',
          '@msg-id=announcement;msg-param-color=BLUE;login=mm2pl;$ts :tmi.twitch.tv USERNOTICE #xqc :hello',
        ),
        (
          'resub without user message',
          '@msg-id=resub;login=ronni;$ts :tmi.twitch.tv USERNOTICE #xqc',
        ),
        (
          'PRIVMSG',
          '@display-name=forsen :f!f@f.tmi.twitch.tv PRIVMSG #xqc :hi',
        ),
      ]) {
        printOnFailure(name);
        expect(RecentMessagesService.parseSubChild(raw), isNull);
      }
    });

    test('robotty lines without a trailing colon parse label and child', () {
      const announcement =
          '@color=#0000FF;id=1151c190;mod=0;rm-received-ts=1785668914195;'
          'historical=1;system-msg;msg-id=announcement;'
          'msg-param-color=PRIMARY;user-type;login=ermugo2;flags;'
          'badges=broadcaster/1;emotes;display-name=ermugo2 '
          ':tmi.twitch.tv USERNOTICE #ermugo2 uuh';
      final label = RecentMessagesService.parseIrcLine(announcement)!;
      expect(label.text, 'Announcement');
      expect(label.systemAccent, purple);
      final child = RecentMessagesService.parseAnnouncementChild(announcement)!;
      expect((child.text, child.login), ('uuh', 'ermugo2'));
      expect(child.messageId, '1151c190');
      expect(child.badges, hasLength(1));

      const resub =
          '@color=#0000FF;id=abc;rm-received-ts=1785668914195;historical=1;'
          'system-msg=ronni\\shas\\ssubscribed!;msg-id=resub;'
          'badge-info;login=ronni;flags;badges=subscriber/6;emotes;'
          'display-name=ronni :tmi.twitch.tv USERNOTICE #xqc hello';
      expect(
        RecentMessagesService.parseIrcLine(resub)!.text,
        'ronni has subscribed!',
      );
      final sub = RecentMessagesService.parseSubChild(resub)!;
      expect((sub.text, sub.login), ('hello', 'ronni'));
    });
  });

  group('history sweeps', () {
    final t0 = DateTime(2024, 1, 1, 12);
    TwitchMessage message(String id, String login, int sec) => TwitchMessage(
      login: login,
      text: 'hi',
      messageId: id,
      timestamp: t0.add(Duration(seconds: sec)),
      channel: 'xqc',
    );

    TwitchMessage system(
      String text,
      String login,
      int sec, {
      bool ban = false,
    }) => TwitchMessage(
      login: login,
      text: text,
      messageId: 'sys-$text',
      isSystem: true,
      isBanNotice: ban,
      timestamp: t0.add(Duration(seconds: sec)),
      channel: 'xqc',
    );

    test('a ban deletes only the target user, and announcements do not', () {
      final messages = [
        message('m1', 'someone_else', 0),
        message('m2', 'forsen', 1),
        message('m3', 'mm2pl', 2),
        system('forsen was banned.', 'forsen', 5, ban: true),
        system('Announcement: hi', 'mm2pl', 6),
      ];
      RecentMessagesService.applyBanSweep(messages);
      expect(messages.map((m) => m.deleted), [
        false,
        true,
        false,
        false,
        false,
      ]);
    });

    test('CLEARMSG target ids drive per-message deletion', () {
      expect(
        RecentMessagesService.clearMsgTargetId(
          '@login=ermugo1;target-msg-id=8c41deb9 :tmi.twitch.tv CLEARMSG #xqc :kuh',
        ),
        '8c41deb9',
      );
      expect(
        RecentMessagesService.clearMsgTargetId(
          ':tmi.twitch.tv CLEARMSG #xqc :kuh',
        ),
        isNull,
      );
      expect(
        RecentMessagesService.clearMsgTargetId(
          '@display-name=f :f!f@f.tmi.twitch.tv PRIVMSG #xqc :hi',
        ),
        isNull,
      );

      final messages = [message('m1', 'a', 0), message('m2', 'b', 0)];
      RecentMessagesService.applyMessageDeletions(messages, ['m2']);
      expect(messages.map((m) => m.deleted), [false, true]);
    });
  });
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

  ModActions modActions(
    TwitchApi api, {
    Map<String, String> channels = const {'testchannel': 'broadcaster1'},
    String? moderatorId = 'mod1',
  }) => ModActions(
    twitchApi: api,
    getChannelUserIds: () => channels,
    getCurrentUserId: () => moderatorId,
  );

  TwitchApi stubApi(
    List<http.BaseRequest> seen, {
    Map<String, http.Response> routes = const {},
    String loginId = 'target1',
  }) => TwitchApi(
    client: MockClient((request) async {
      seen.add(request);
      if (request.url.path == '/helix/users') {
        return http.Response(
          '{"data": [{"id": "$loginId", "login": "target"}]}',
          200,
        );
      }
      final key = '${request.method} ${request.url.path}';
      return routes[key] ?? http.Response('', 200);
    }),
  );

  group('user lookups', () {
    const one = '{"data": [{"id": "1", "login": "u", "display_name": "U"}]}';

    for (final (name, call, url)
        in <(String, Future<Object?> Function(TwitchApi), String)>[
          (
            'getUserId',
            (api) => api.getUserId(auth, 'testuser'),
            'https://api.twitch.tv/helix/users?login=testuser',
          ),
          (
            'getCurrentUser',
            (api) => api.getCurrentUser(auth),
            'https://api.twitch.tv/helix/users',
          ),
          (
            'getUserProfile',
            (api) => api.getUserProfile(auth, 'testuser'),
            'https://api.twitch.tv/helix/users?login=testuser',
          ),
        ]) {
      test('$name sends GET and returns the user on 200', () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response(one, 200),
        );
        expect(await call(api), isNotNull);
        expect(captured.method, 'GET');
        expect(captured.url.toString(), url);
        expectAuthHeaders(captured);
      });

      test('$name returns null and records an error on failure', () async {
        for (final (status, body) in [
          (200, '{"data": []}'),
          (404, 'Not Found'),
        ]) {
          final api = createApi(
            (_) {},
            respond: () => http.Response(body, status),
          );
          expect(await call(api), isNull);
          expect(api.lastError, isNotNull);
        }
      });
    }

    test('getUserId and getUserProfile read the payload fields', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response(
          '{"data": [{"id": "123", "login": "t", "display_name": "TestUser", "profile_image_url": "https://example.com/img.png"}]}',
          200,
        ),
      );
      expect(await api.getUserId(auth, 't'), '123');
      final profile = await api.getUserProfile(auth, 't');
      expect(profile!['display_name'], 'TestUser');
      expect(profile['profile_image_url'], 'https://example.com/img.png');
      final me = await api.getCurrentUser(auth);
      expect((me!['id'], me['login']), ('123', 't'));
    });
  });

  group('getUserLoginsByIds', () {
    test('maps ids to logins with GET /helix/users?id=', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response(
          '{"data": [{"id": "1", "login": "alpha"}, {"id": "2", "login": "beta"}]}',
          200,
        ),
      );

      final result = await api.getUserLoginsByIds(auth, ['1', '2']);

      expect(result, {'1': 'alpha', '2': 'beta'});
      expect(captured.method, 'GET');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/users?id=1&id=2',
      );
      expectAuthHeaders(captured);
    });

    test('batches into chunks of 100 and merges results', () async {
      final requests = <String>[];
      final api = TwitchApi(
        client: MockClient((request) async {
          requests.add(request.url.toString());
          final ids = request.url.queryParametersAll['id'] ?? [];
          final data = [
            for (final id in ids) {'id': id, 'login': 'user_$id'},
          ];
          return http.Response(jsonEncode({'data': data}), 200);
        }),
      );
      final ids = [for (var i = 0; i < 150; i++) '$i'];

      final result = await api.getUserLoginsByIds(auth, ids);

      expect(requests.length, 2);
      expect(requests[0], contains('id=0&id=1'));
      expect(requests[1], isNot(contains('id=0')));
      expect(result.length, 150);
      expect(result['149'], 'user_149');
      expect(result['0'], 'user_0');
    });

    test('dedups input ids before building the query', () async {
      for (final (name, input, expectedUrl) in [
        (
          'dedups input ids before building the query',
          ['1', '1', '1'],
          'https://api.twitch.tv/helix/users?id=1',
        ),
      ]) {
        final requests = <String>[];
        final api = TwitchApi(
          client: MockClient((request) async {
            requests.add(request.url.toString());
            return http.Response('{"data": []}', 200);
          }),
        );
        await api.getUserLoginsByIds(auth, input);
        expect(requests.single, expectedUrl, reason: name);
      }
    });

    test('skips failed chunks and returns whatever resolved', () async {
      var call = 0;
      final api = TwitchApi(
        client: MockClient((request) async {
          call++;
          if (call == 1) return http.Response('Error', 500);
          return http.Response(
            '{"data": [{"id": "target2", "login": "beta"}]}',
            200,
          );
        }),
      );
      // 101 distinct ids: the first chunk (100 ids) fails, the second carries
      // "target2".
      final ids = [for (var i = 0; i < 100; i++) 'id$i', 'target2'];

      final result = await api.getUserLoginsByIds(auth, ids);

      expect(result, {'target2': 'beta'});
      expect(api.lastError, contains('getUserLoginsByIds'));
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

    test(
      'createEventSubSubscription treats 409 as success and other errors as failure',
      () async {
        for (final (name, status, expected) in [
          ('returns true on 409 (already exists)', 409, true),
          ('returns false on other HTTP error', 403, false),
        ]) {
          final api = createApi(
            (_) {},
            respond: () => http.Response('err', status),
          );
          expect(
            await api.createEventSubSubscription(
              auth: auth,
              sessionId: 's1',
              type: 'channel.moderate',
              version: '2',
              condition: {'broadcaster_user_id': 'b1'},
            ),
            expected,
            reason: name,
          );
        }
      },
    );
  });

  group('blockUser / unblockUser', () {
    test('blockUser and unblockUser call /users/blocks', () async {
      for (final (name, method, status, expected) in [
        ('blockUser', 'PUT', 204, true),
        ('blockUser', 'PUT', 403, false),
        ('unblockUser', 'DELETE', 204, true),
        ('unblockUser', 'DELETE', 403, false),
      ]) {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response('x', status),
        );
        final ok = name == 'blockUser'
            ? await api.blockUser(auth, 'target123')
            : await api.unblockUser(auth, 'target123');
        expect(ok, expected);
        expect(captured.method, method);
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/users/blocks?target_user_id=target123',
        );
        expectAuthHeaders(captured);
      }
    });
  });

  group('sendChatMessage', () {
    test('sendChatMessage sends the body and reply parent', () async {
      for (final (name, replyId) in [
        (
          'sends POST /helix/chat/messages with message body and returns id',
          null,
        ),
        ('includes reply_parent_message_id when replying', 'parent1'),
      ]) {
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
          replyParentMessageId: replyId,
        );
        expect(id, 'abc123', reason: name);
        final body = jsonDecode(captured.body) as Map<String, dynamic>;
        if (replyId != null) {
          expect(body['reply_parent_message_id'], replyId, reason: name);
        } else {
          expect(body['message'], 'hello chat', reason: name);
        }
      }
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

    test('moderator and VIP add/remove use POST and DELETE', () async {
      for (final (name, method, path) in [
        ('addModerator', 'POST', '/helix/moderation/moderators'),
        ('removeModerator', 'DELETE', '/helix/moderation/moderators'),
        ('addVip', 'POST', '/helix/channels/vips'),
        ('removeVip', 'DELETE', '/helix/channels/vips'),
      ]) {
        late http.Request captured;
        final api = createApi((req) => captured = req);
        final ok = switch (name) {
          'addModerator' => await api.addModerator(
            auth,
            broadcasterId: 'b1',
            userId: 'u1',
          ),
          'removeModerator' => await api.removeModerator(
            auth,
            broadcasterId: 'b1',
            userId: 'u1',
          ),
          'addVip' => await api.addVip(auth, broadcasterId: 'b1', userId: 'u1'),
          _ => await api.removeVip(auth, broadcasterId: 'b1', userId: 'u1'),
        };
        expect(ok, isTrue);
        expect(captured.method, method);
        expect(
          captured.url.toString(),
          'https://api.twitch.tv$path?broadcaster_id=b1&user_id=u1',
        );
      }
    });
  });

  group('updateChatSettings', () {
    test('updateChatSettings PATCHes and reports failure', () async {
      for (final (name, status, expected) in [
        ('PATCHes /helix/chat/settings with the given body', 200, true),
        ('returns false on non-200', 403, false),
      ]) {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response('{"data": []}', status),
        );
        final ok = await api.updateChatSettings(
          auth,
          broadcasterId: 'b1',
          moderatorId: 'm1',
          body: {'slow_mode': true, 'slow_mode_wait_time': 30},
        );
        expect(ok, expected, reason: name);
        if (expected) {
          expect(captured.method, 'PATCH');
          expect(
            captured.url.toString(),
            'https://api.twitch.tv/helix/chat/settings?broadcaster_id=b1&moderator_id=m1',
          );
        }
      }
    });
  });

  group('ModActions', () {
    test('timeoutUser resolves login and posts duration plus reason', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(seen);
      final result = await modActions(api).timeoutUser(
        auth,
        'testchannel',
        login: 'target',
        duration: 600,
        reason: 'spam',
      );
      expect(result.ok, isTrue);
      expect(seen, hasLength(2));
      final post = seen[1] as http.Request;
      expect(post.method, 'POST');
      expect(post.url.path, '/helix/moderation/bans');
      expect(post.url.queryParameters['broadcaster_id'], 'broadcaster1');
      expect(post.url.queryParameters['moderator_id'], 'mod1');
      final body = jsonDecode(post.body)['data'] as Map<String, dynamic>;
      expect(body['user_id'], 'target1');
      expect(body['duration'], 600);
      expect(body['reason'], 'spam');
    });

    test('refuses self and broadcaster targets', () async {
      for (final (name, loginId, failure) in [
        ('refuses self targets', 'mod1', ModFailure.selfTarget),
        (
          'refuses broadcaster targets',
          'broadcaster1',
          ModFailure.broadcasterTarget,
        ),
      ]) {
        final seen = <http.BaseRequest>[];
        final api = stubApi(seen, loginId: loginId);
        final result = await modActions(
          api,
        ).timeoutUser(auth, 'testchannel', login: 'x', duration: 60);
        expect(result.ok, isFalse, reason: name);
        expect(result.failure, failure, reason: name);
        expect(seen, hasLength(1), reason: 'no mod call after guard');
      }
    });

    test('unknown login fails without a mod call', () async {
      final seen = <http.BaseRequest>[];
      final api = TwitchApi(
        client: MockClient((request) async {
          seen.add(request);
          return http.Response('{"data": []}', 200);
        }),
      );
      final result = await modActions(
        api,
      ).banUser(auth, 'testchannel', login: 'ghost');
      expect(result.ok, isFalse);
      expect(result.failure, ModFailure.unknownUser);
      expect(seen, hasLength(1));
    });

    test('missing ids fail as notJoined without HTTP', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(seen);
      final noChannel = await modActions(
        api,
        channels: const {},
      ).clearChat(auth, 'testchannel');
      expect(noChannel.failure, ModFailure.notJoined);
      final noMod = await modActions(
        api,
        moderatorId: null,
      ).clearChat(auth, 'testchannel');
      expect(noMod.failure, ModFailure.notJoined);
      expect(seen, isEmpty);
    });

    test('API 403 surfaces the permission reason', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(
        seen,
        routes: {
          'POST /helix/moderation/bans': http.Response(
            '{"message": "forbidden"}',
            403,
          ),
        },
      );
      final result = await modActions(
        api,
      ).banUser(auth, 'testchannel', login: 'target');
      expect(result.ok, isFalse);
      expect(result.failure, ModFailure.apiError);
      expect(result.reason, contains("don't have permission"));
    });

    test('setSlowMode posts on/off bodies', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(seen);
      final actions = modActions(api);
      expect(
        (await actions.setSlowMode(auth, 'testchannel', enabled: true)).ok,
        isTrue,
      );
      final slowPatch = seen[0] as http.Request;
      expect(slowPatch.method, 'PATCH');
      expect(slowPatch.url.queryParameters['broadcaster_id'], 'broadcaster1');
      expect(slowPatch.url.queryParameters['moderator_id'], 'mod1');
      expect(jsonDecode(slowPatch.body), {
        'slow_mode': true,
        'slow_mode_wait_time': 30,
      });
      expect(
        (await actions.setSlowMode(
          auth,
          'testchannel',
          enabled: true,
          seconds: 120,
        )).ok,
        isTrue,
      );
      expect(jsonDecode((seen[1] as http.Request).body), {
        'slow_mode': true,
        'slow_mode_wait_time': 120,
      });
      expect(
        (await actions.setSlowMode(auth, 'testchannel', enabled: false)).ok,
        isTrue,
      );
      expect(jsonDecode((seen[2] as http.Request).body), {'slow_mode': false});
    });

    test('emote/subs/unique/shield send the right bodies', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(seen);
      final actions = modActions(api);
      await actions.setEmoteOnly(auth, 'testchannel', enabled: true);
      await actions.setFollowersMode(auth, 'testchannel', enabled: true);
      await actions.setSubscribersOnly(auth, 'testchannel', enabled: false);
      await actions.setUniqueChat(auth, 'testchannel', enabled: true);
      await actions.setShieldMode(auth, 'testchannel', active: true);
      await actions.setFollowersMode(
        auth,
        'testchannel',
        enabled: true,
        minutes: 30,
      );
      expect(jsonDecode((seen[5] as http.Request).body), {
        'follower_mode': true,
        'follower_mode_duration': 30,
      });
      for (var i = 0; i < 4; i++) {
        expect((seen[i] as http.Request).method, 'PATCH');
      }
      expect(jsonDecode((seen[0] as http.Request).body), {'emote_mode': true});
      expect(jsonDecode((seen[1] as http.Request).body), {
        'follower_mode': true,
      }, reason: 'no duration key without minutes');
      expect(jsonDecode((seen[2] as http.Request).body), {
        'subscriber_mode': false,
      });
      expect(jsonDecode((seen[3] as http.Request).body), {
        'unique_chat_mode': true,
      });
      final shield = seen[4] as http.Request;
      expect(shield.method, 'PUT');
      expect(shield.url.queryParameters['broadcaster_id'], 'broadcaster1');
      expect(jsonDecode(shield.body), {'is_active': true});
    });

    test('failureReason maps 401, 429, and Helix messages', () async {
      final seen = <http.BaseRequest>[];
      Future<ModResult> banWith(int status, String body) => modActions(
        stubApi(
          seen,
          routes: {'POST /helix/moderation/bans': http.Response(body, status)},
        ),
      ).banUser(auth, 'testchannel', login: 'target');
      expect(
        (await banWith(401, 'Unauthorized')).reason,
        contains('Missing required scope'),
      );
      expect(
        (await banWith(429, 'slow down')).reason,
        contains('rate-limited'),
      );
      expect(
        (await banWith(400, '{"message": "You are timed out."}')).reason,
        'You are timed out.',
      );
    });

    test('deleteMessage targets one id, clearChat targets none', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(
        seen,
        routes: {'DELETE /helix/moderation/chat': http.Response('', 204)},
      );
      final actions = modActions(api);
      expect(
        (await actions.deleteMessage(auth, 'testchannel', 'msg-1')).ok,
        isTrue,
      );
      final del = seen[0] as http.Request;
      expect(del.method, 'DELETE');
      expect(
        del.url.toString(),
        'https://api.twitch.tv/helix/moderation/chat?broadcaster_id=broadcaster1&moderator_id=mod1&message_id=msg-1',
      );
      expect((await actions.clearChat(auth, 'testchannel')).ok, isTrue);
      final clear = seen[1] as http.Request;
      expect(clear.method, 'DELETE');
      expect(
        clear.url.toString(),
        'https://api.twitch.tv/helix/moderation/chat?broadcaster_id=broadcaster1&moderator_id=mod1',
      );
    });

    test('unban and warn hit their endpoints', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(
        seen,
        routes: {'DELETE /helix/moderation/bans': http.Response('', 204)},
      );
      final actions = modActions(api);
      expect(
        (await actions.unbanUser(auth, 'testchannel', login: 'target')).ok,
        isTrue,
      );
      final unban = seen[1] as http.Request;
      expect(unban.method, 'DELETE');
      expect(
        unban.url.toString(),
        'https://api.twitch.tv/helix/moderation/bans?broadcaster_id=broadcaster1&moderator_id=mod1&user_id=target1',
      );
      expect(
        (await actions.warnUser(
          auth,
          'testchannel',
          login: 'target',
          reason: 'r',
        )).ok,
        isTrue,
      );
      final warn = seen[2] as http.Request;
      expect(warn.method, 'POST');
      expect(
        warn.url.toString(),
        'https://api.twitch.tv/helix/moderation/warnings?broadcaster_id=broadcaster1&moderator_id=mod1',
      );
      expect(jsonDecode(warn.body)['data']['reason'], 'r');
    });

    test('setModerator and setVip use POST to add, DELETE to remove', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(
        seen,
        routes: {
          'POST /helix/moderation/moderators': http.Response('', 204),
          'DELETE /helix/moderation/moderators': http.Response('', 204),
          'POST /helix/channels/vips': http.Response('', 204),
          'DELETE /helix/channels/vips': http.Response('', 204),
        },
      );
      final actions = modActions(api);
      await actions.setModerator(auth, 'testchannel', login: 't', add: true);
      final modAdd = seen[1] as http.Request;
      expect(modAdd.method, 'POST');
      expect(
        modAdd.url.toString(),
        'https://api.twitch.tv/helix/moderation/moderators?broadcaster_id=broadcaster1&user_id=target1',
      );
      // Second call reuses the cached user id, so no GET precedes it.
      await actions.setModerator(auth, 'testchannel', login: 't', add: false);
      final modRemove = seen[2] as http.Request;
      expect(modRemove.method, 'DELETE');
      expect(modRemove.url.path, '/helix/moderation/moderators');
      await actions.setVip(auth, 'testchannel', login: 't', add: true);
      final vipAdd = seen[3] as http.Request;
      expect(vipAdd.method, 'POST');
      expect(
        vipAdd.url.toString(),
        'https://api.twitch.tv/helix/channels/vips?broadcaster_id=broadcaster1&user_id=target1',
      );
      await actions.setVip(auth, 'testchannel', login: 't', add: false);
      final vipRemove = seen[4] as http.Request;
      expect(vipRemove.method, 'DELETE');
      expect(vipRemove.url.path, '/helix/channels/vips');
    });

    test('announce, shoutout, commercial, raid, marker', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(
        seen,
        routes: {
          'POST /helix/chat/announcements': http.Response('', 204),
          'POST /helix/chat/shoutouts': http.Response('', 204),
          'DELETE /helix/raids': http.Response('', 204),
        },
      );
      final actions = modActions(api);
      await actions.sendAnnouncement(
        auth,
        'testchannel',
        message: 'hi',
        color: 'blue',
      );
      final announce = seen[0] as http.Request;
      expect(announce.url.path, '/helix/chat/announcements');
      expect(announce.url.queryParameters['broadcaster_id'], 'broadcaster1');
      expect(announce.url.queryParameters['moderator_id'], 'mod1');
      expect(jsonDecode(announce.body)['color'], 'blue');
      expect(
        (await actions.sendShoutout(auth, 'testchannel', login: 'target')).ok,
        isTrue,
      );
      final shoutout = seen[2] as http.Request;
      expect(shoutout.method, 'POST');
      expect(shoutout.body, isEmpty, reason: 'query-only call');
      expect(
        shoutout.url.toString(),
        'https://api.twitch.tv/helix/chat/shoutouts?from_broadcaster_id=broadcaster1&to_broadcaster_id=target1&moderator_id=mod1',
      );
      await actions.startCommercial(auth, 'testchannel', length: 30);
      final commercial = seen[3] as http.Request;
      expect(commercial.method, 'POST');
      expect(
        commercial.url.toString(),
        'https://api.twitch.tv/helix/channels/commercial',
      );
      expect(jsonDecode(commercial.body)['length'], 30);
      // 'target' is cached from the shoutout, so no GET precedes the POST.
      await actions.startRaid(auth, 'testchannel', login: 'target');
      final raid = seen[4] as http.Request;
      expect(raid.method, 'POST');
      expect(
        raid.url.toString(),
        'https://api.twitch.tv/helix/raids?from_broadcaster_id=broadcaster1&to_broadcaster_id=target1',
      );
      await actions.cancelRaid(auth, 'testchannel');
      final unraid = seen[5] as http.Request;
      expect(unraid.method, 'DELETE');
      expect(
        unraid.url.toString(),
        'https://api.twitch.tv/helix/raids?broadcaster_id=broadcaster1',
      );
      await actions.createMarker(auth, 'testchannel', description: 'x' * 200);
      final marker = seen[6] as http.Request;
      expect(marker.method, 'POST');
      expect(marker.url.path, '/helix/streams/markers');
      expect((jsonDecode(marker.body)['description'] as String).length, 140);
    });
  });

  group('commercial / raid / shield / marker / whisper', () {
    test('shield mode and whisper requests', () async {
      for (final (name, run) in <(String, Future<void> Function())>[
        (
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
        ),
        (
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
        ),
      ]) {
        printOnFailure(name);
        await run();
      }
    });
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

  late EventSubDecoder service;

  setUp(() {
    service = EventSubDecoder(Stream<Map<String, dynamic>>.empty());
    service.setChannelMapping('broadcaster1', 'testchannel');
  });

  tearDown(() {
    service.dispose();
  });

  group('notification (channel.moderate)', () {
    String expiresIn300() => DateTime.now()
        .toUtc()
        .add(const Duration(seconds: 300))
        .toIso8601String();

    test('emits a ModerationEvent per action', () {
      for (final (name, action, meta, check)
          in <
            (
              String,
              String,
              Map<String, dynamic>,
              void Function(ModerationEvent),
            )
          >[
            (
              'ban',
              'ban',
              {
                'ban': {
                  'user_id': 'target1',
                  'user_name': 'targetuser',
                  'reason': 'spam',
                },
              },
              (e) {
                expect(e.action, ModerationAction.ban);
                expect(e.channel, 'testchannel');
                expect(e.moderatorName, 'moduser');
                expect(e.targetName, 'targetuser');
                expect(e.reason, 'spam');
              },
            ),
            (
              'timeout duration comes from expires_at',
              'timeout',
              {
                'timeout': {
                  'user_name': 'targetuser',
                  'expires_at': expiresIn300(),
                },
              },
              (e) {
                expect(e.action, ModerationAction.timeout);
                expect(e.durationSeconds, closeTo(300, 10));
              },
            ),
            (
              'shared_chat_timeout maps to timeout with duration',
              'shared_chat_timeout',
              {
                'shared_chat_timeout': {
                  'user_name': 'spammer',
                  'expires_at': expiresIn300(),
                },
              },
              (e) {
                expect(e.action, ModerationAction.timeout);
                expect(e.targetName, 'spammer');
                expect(e.durationSeconds, closeTo(300, 10));
              },
            ),
            (
              'shared_chat_ban maps to ban',
              'shared_chat_ban',
              {
                'shared_chat_ban': {'user_name': 'targetuser'},
              },
              (e) {
                expect(e.action, ModerationAction.ban);
                expect(e.rawAction, 'ban');
              },
            ),
            (
              'delete carries message id and body',
              'delete',
              {
                'delete': {
                  'user_name': 'targetuser',
                  'message_id': 'msg-1',
                  'message_body': 'hello',
                },
              },
              (e) {
                expect(e.action, ModerationAction.delete);
                expect(e.messageId, 'msg-1');
                expect(e.messageBody, 'hello');
              },
            ),
            (
              'add_blocked_term carries terms',
              'add_blocked_term',
              {
                'automod_terms': {
                  'action': 'add',
                  'list': 'blocked',
                  'terms': ['bad word', 'worse*'],
                  'from_automod': false,
                },
              },
              (e) {
                expect(e.action, ModerationAction.addBlockedTerm);
                expect(e.terms, ['bad word', 'worse*']);
                expect(e.targetName, isNull);
              },
            ),
            (
              'approve_unban_request carries target and resolution',
              'approve_unban_request',
              {
                'unban_request': {
                  'user_name': 'spammer',
                  'resolution_text': 'second chance',
                },
              },
              (e) {
                expect(e.action, ModerationAction.approveUnbanRequest);
                expect(e.targetName, 'spammer');
                expect(e.reason, 'second chance');
              },
            ),
            (
              'clear has no target',
              'clear',
              <String, dynamic>{},
              (e) {
                expect(e.action, ModerationAction.clear);
                expect(e.targetName, isNull);
              },
            ),
            (
              'bare room-setting actions still emit',
              'followersoff',
              <String, dynamic>{},
              (e) => expect(e.action, ModerationAction.followersOff),
            ),
            (
              'unknown future actions still emit for the feed',
              'some_future_action',
              <String, dynamic>{},
              (e) {
                expect(e.action, ModerationAction.unknown);
                expect(e.rawAction, 'some_future_action');
              },
            ),
          ]) {
        printOnFailure(name);
        final events = <ModerationEvent>[];
        service.onModeration.listen(events.add);
        service.feed(_moderate(action: action, meta: meta));
        expect(events, hasLength(1));
        check(events.single);
      }
    });

    test('ignores unknown types and unmapped channels', () {
      for (final (name, type, broadcaster) in [
        (
          'ignores notifications for unknown subscription types',
          'channel.chat.message',
          'broadcaster1',
        ),
        (
          'drops events without a channel mapping',
          'channel.moderate',
          'unknown_broadcaster',
        ),
      ]) {
        final events = <ModerationEvent>[];
        service.onModeration.listen(events.add);
        service.feed(<String, dynamic>{
          'metadata': <String, dynamic>{
            'message_type': 'notification',
            'subscription_type': type,
          },
          'payload': <String, dynamic>{
            'subscription': <String, dynamic>{
              'condition': <String, dynamic>{
                'broadcaster_user_id': broadcaster,
              },
            },
            'event': <String, dynamic>{'action': 'clear'},
          },
        });
        expect(events, isEmpty, reason: name);
      }
    });
  });

  group('notification (shield/shoutout/warning feed)', () {
    Map<String, dynamic> topic(
      String type,
      Map<String, dynamic> event,
    ) => <String, dynamic>{
      'metadata': <String, dynamic>{
        'message_type': 'notification',
        'subscription_type': type,
      },
      'payload': <String, dynamic>{
        'subscription': <String, dynamic>{
          'condition': <String, dynamic>{'broadcaster_user_id': 'broadcaster1'},
        },
        'event': event,
      },
    };

    test('shield begin/end toggle active', () async {
      final events = <ShieldModeEvent>[];
      service.onShieldMode.listen(events.add);
      service.feed(
        topic('channel.shield_mode.begin', {'moderator_user_name': 'moduser'}),
      );
      service.feed(
        topic('channel.shield_mode.end', {'moderator_user_name': 'moduser'}),
      );
      expect(events.map((e) => e.active), [true, false]);
      expect(events[0].channel, 'testchannel');
    });

    test('decodes feed notifications', () {
      for (final (name, type, event, stream, check)
          in <
            (
              String,
              String,
              Map<String, dynamic>,
              Stream<Object> Function(),
              void Function(dynamic),
            )
          >[
            (
              'shoutout create',
              'channel.shoutout.create',
              {
                'broadcaster_user_login': 'streamer',
                'to_broadcaster_user_login': 'friend',
                'moderator_user_name': 'moduser',
              },
              () => service.onShoutout,
              (e) {
                expect(e.kind, ShoutoutKind.create);
                expect((e.fromLogin, e.toLogin), ('streamer', 'friend'));
              },
            ),
            (
              'shoutout receive',
              'channel.shoutout.receive',
              {
                'broadcaster_user_login': 'streamer',
                'from_broadcaster_user_login': 'friend',
                'moderator_user_name': 'moduser',
              },
              () => service.onShoutout,
              (e) {
                expect(e.kind, ShoutoutKind.receive);
                expect((e.fromLogin, e.toLogin), ('friend', 'streamer'));
              },
            ),
            (
              'warning send',
              'channel.warning.send',
              {
                'moderator_user_name': 'moduser',
                'user_login': 'spammer',
                'reason': 'spam',
              },
              () => service.onWarning,
              (e) {
                expect(e.kind, WarningKind.send);
                expect((e.userLogin, e.reason), ('spammer', 'spam'));
              },
            ),
            (
              'warning acknowledge',
              'channel.warning.acknowledge',
              {'moderator_user_name': 'moduser', 'user_login': 'spammer'},
              () => service.onWarning,
              (e) {
                expect(e.kind, WarningKind.acknowledge);
                expect(e.userLogin, 'spammer');
              },
            ),
            (
              'unban request create',
              'channel.unban_request.create',
              {'user_login': 'spammer'},
              () => service.onUnbanRequest,
              (e) {
                expect(e.kind, UnbanRequestKind.create);
                expect(e.userLogin, 'spammer');
              },
            ),
            (
              'unban request resolve',
              'channel.unban_request.resolve',
              {
                'user_login': 'spammer',
                'moderator_user_name': 'moduser',
                'resolution_text': 'second chance',
              },
              () => service.onUnbanRequest,
              (e) {
                expect(e.kind, UnbanRequestKind.resolve);
                expect(e.userLogin, 'spammer');
                expect(e.moderatorName, 'moduser');
                expect(e.resolutionText, 'second chance');
              },
            ),
            (
              'automod terms update',
              'automod.terms.update',
              {
                'action': 'add',
                'list': 'blocked',
                'terms': ['bad word'],
                'moderator_user_name': 'moduser',
              },
              () => service.onAutomodTerms,
              (e) {
                expect(e.action, AutomodTermsAction.add);
                expect(e.rawAction, 'add');
                expect(e.list, 'blocked');
                expect(e.terms, ['bad word']);
              },
            ),
            (
              'automod terms unknown action keeps the raw wire',
              'automod.terms.update',
              {
                'action': 'modify',
                'list': 'blocked',
                'terms': ['bad word'],
                'moderator_user_name': 'moduser',
              },
              () => service.onAutomodTerms,
              (e) {
                expect(e.action, AutomodTermsAction.unknown);
                expect(e.rawAction, 'modify');
              },
            ),
            (
              'automod settings update',
              'automod.settings.update',
              {'moderator_user_name': 'moduser'},
              () => service.onAutomodSettings,
              (e) {
                expect(e.channel, 'testchannel');
                expect(e.moderatorName, 'moduser');
              },
            ),
            (
              'suspicious message',
              'channel.suspicious_user.message',
              {
                'user_login': 'spammer',
                'low_trust_status': 'restricted',
                'types': ['manually_added'],
                'ban_evasion_evaluation': 'possible',
                'shared_ban_channel_ids': ['111', '222'],
              },
              () => service.onSuspiciousUser,
              (e) {
                expect(e.kind, SuspiciousUserKind.message);
                expect((e.userLogin, e.status), ('spammer', 'restricted'));
                expect(e.types, ['manually_added']);
                expect(e.banEvasion, 'possible');
                expect(e.sharedBanChannelIds, ['111', '222']);
              },
            ),
            (
              'suspicious update',
              'channel.suspicious_user.update',
              {
                'user_login': 'spammer',
                'low_trust_status': 'monitored',
                'moderator_user_name': 'moduser',
              },
              () => service.onSuspiciousUser,
              (e) {
                expect(e.kind, SuspiciousUserKind.update);
                expect((e.status, e.moderatorName), ('monitored', 'moduser'));
              },
            ),
            (
              'points reward add',
              'channel.channel_points_custom_reward.add',
              {
                'id': 'reward1',
                'title': 'Hydrate',
                'cost': 500,
                'is_enabled': true,
                'is_paused': false,
              },
              () => service.onPointReward,
              (e) {
                expect(e.kind, PointRewardKind.add);
                expect(
                  (e.reward.id, e.reward.title, e.reward.cost),
                  ('reward1', 'Hydrate', 500),
                );
              },
            ),
            (
              'points redemption add',
              'channel.channel_points_custom_reward_redemption.add',
              {
                'id': 'red1',
                'user_login': 'fan',
                'user_input': 'do a flip',
                'status': 'UNFULFILLED',
                'redeemed_at': '2026-01-02T03:04:05Z',
                'reward': {'id': 'reward1', 'title': 'Hydrate', 'cost': 500},
              },
              () => service.onPointRedemption,
              (e) {
                expect(e.kind, PointRedemptionKind.add);
                expect(e.redemption.userLogin, 'fan');
                expect(e.redemption.userInput, 'do a flip');
                expect(e.redemption.rewardId, 'reward1');
              },
            ),
            (
              'points redemption update',
              'channel.channel_points_custom_reward_redemption.update',
              {
                'id': 'red1',
                'user_login': 'fan',
                'status': 'FULFILLED',
                'reward': {'id': 'reward1', 'title': 'Hydrate', 'cost': 500},
              },
              () => service.onPointRedemption,
              (e) {
                expect(e.kind, PointRedemptionKind.update);
                expect(
                  (e.redemption.id, e.redemption.status),
                  ('red1', 'FULFILLED'),
                );
              },
            ),
          ]) {
        printOnFailure(name);
        final events = <Object>[];
        stream().listen(events.add);
        service.feed(topic(type, event));
        expect(events, hasLength(1));
        check(events.single);
      }
    });
  });

  group('notification (automod.message.hold/update)', () {
    Map<String, dynamic> automod(
      String type,
      Map<String, dynamic> event, {
      String broadcaster = 'broadcaster1',
    }) => <String, dynamic>{
      'metadata': <String, dynamic>{
        'message_type': 'notification',
        'subscription_type': type,
      },
      'payload': <String, dynamic>{
        'subscription': <String, dynamic>{
          'condition': <String, dynamic>{'broadcaster_user_id': broadcaster},
        },
        'event': event,
      },
    };

    // v2 shape: message and category are nested objects.
    Map<String, dynamic> heldEvent({
      String status = 'held',
      String? category = 'bullying',
      String messageId = 'msg-1',
    }) {
      final event = <String, dynamic>{
        'broadcaster_user_id': 'broadcaster1',
        'user_id': 'u1',
        'user_login': 'spammer',
        'user_name': 'Spammer',
        'message_id': messageId,
        'message': <String, dynamic>{'text': 'bad text here', 'fragments': []},
        'reason': 'automod',
        'held_at': '2026-01-01T00:00:00Z',
      };
      if (category != null) {
        event['automod'] = <String, dynamic>{'category': category, 'level': 4};
      }
      if (status != 'held') event['status'] = status;
      return event;
    }

    test('hold queues with user, text, and category', () async {
      final events = <AutomodHeldEvent>[];
      service.onAutomodHeld.listen(events.add);
      service.feed(automod('automod.message.hold', heldEvent()));
      expect(events, hasLength(1));
      expect(events[0].channel, 'testchannel');
      expect(events[0].messageId, 'msg-1');
      expect(events[0].userLogin, 'spammer');
      expect(events[0].text, 'bad text here');
      expect(events[0].category, 'bullying');
      expect(events[0].status, 'held');

      final blocked = heldEvent(category: null)..['reason'] = 'blocked_term';
      service.feed(automod('automod.message.hold', blocked));
      expect(
        events[1].category,
        'blocked_term',
        reason: 'falls back to reason',
      );
    });

    test('v1 shape reads bare message string and top-level category', () async {
      final events = <AutomodHeldEvent>[];
      service.onAutomodHeld.listen(events.add);
      service.feed(
        automod('automod.message.hold', <String, dynamic>{
          'broadcaster_user_id': 'broadcaster1',
          'user_login': 'spammer',
          'message_id': 'msg-9',
          'message': 'v1 bad text',
          'category': 'swearing',
          'level': 2,
          'held_at': '2026-01-01T00:00:00Z',
        }),
      );
      expect(events, hasLength(1));
      expect(events[0].text, 'v1 bad text');
      expect(events[0].category, 'swearing');
    });

    test('update lowercases the resolution status', () async {
      final events = <AutomodHeldEvent>[];
      service.onAutomodHeld.listen(events.add);
      service.feed(
        automod('automod.message.update', heldEvent(status: 'Approved')),
      );
      expect(events, hasLength(1));
      expect(events[0].status, 'approved');
    });

    test('drops holds without a message id or channel mapping', () async {
      final events = <AutomodHeldEvent>[];
      service.onAutomodHeld.listen(events.add);
      service.feed(automod('automod.message.hold', heldEvent(messageId: '')));
      service.feed(
        automod(
          'automod.message.hold',
          heldEvent(),
          broadcaster: 'unknown_broadcaster',
        ),
      );
      expect(events, isEmpty);
    });
  });

  group('manageHeldAutoModMessages', () {
    test('POSTs moderator, msg id, and ALLOW with no query params', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response('', 204),
      );
      final ok = await api.manageHeldAutoModMessages(
        auth,
        moderatorId: 'mod1',
        messageId: 'msg-1',
        allow: true,
      );
      expect(ok, isTrue);
      expect(captured.method, 'POST');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/moderation/automod/message',
      );
      expect(jsonDecode(captured.body), {
        'user_id': 'mod1',
        'msg_id': 'msg-1',
        'action': 'ALLOW',
      });
      expectAuthHeaders(captured);
    });

    test('DENY posts DENY; non-204 fails', () async {
      http.Request? captured;
      final api = TwitchApi(
        client: MockClient((request) async {
          captured = request;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('', body['action'] == 'DENY' ? 204 : 400);
        }),
      );
      expect(
        await api.manageHeldAutoModMessages(
          auth,
          moderatorId: 'mod1',
          messageId: 'msg-1',
          allow: false,
        ),
        isTrue,
      );
      expect(jsonDecode(captured!.body)['action'], 'DENY');
      expect(
        await api.manageHeldAutoModMessages(
          auth,
          moderatorId: 'mod1',
          messageId: 'msg-1',
          allow: true,
        ),
        isFalse,
      );
      expect(api.lastErrorStatus, 400);
    });
  });

  group('getShieldModeStatus', () {
    test('returns the flag on 200, null on failure', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response(
          '{"data": [{"is_active": true, "moderator_id": "m1"}]}',
          200,
        ),
      );
      expect(
        await api.getShieldModeStatus(
          auth,
          broadcasterId: 'b1',
          moderatorId: 'm1',
        ),
        isTrue,
      );
      expect(captured.method, 'GET');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/moderation/shield_mode?broadcaster_id=b1&moderator_id=m1',
      );
      final failing = createApi(
        (_) {},
        respond: () => http.Response('[]', 403),
      );
      expect(
        await failing.getShieldModeStatus(
          auth,
          broadcasterId: 'b1',
          moderatorId: 'm1',
        ),
        isNull,
      );
      expect(failing.lastErrorStatus, 403);
    });
  });

  group('ModActions.decideHeldMessage', () {
    test('allow resolves the moderator id from the session getter', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(
        seen,
        routes: {
          'POST /helix/moderation/automod/message': http.Response('', 204),
        },
      );
      final result = await modActions(
        api,
      ).decideHeldMessage(auth, 'testchannel', messageId: 'msg-1', allow: true);
      expect(result.ok, isTrue);
      final post = seen[0] as http.Request;
      expect(post.url.path, '/helix/moderation/automod/message');
      expect(post.url.queryParameters, isEmpty, reason: 'body-only call');
      expect(jsonDecode(post.body), {
        'user_id': 'mod1',
        'msg_id': 'msg-1',
        'action': 'ALLOW',
      });
    });

    test('notJoined without ids, apiError on rejection', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(
        seen,
        routes: {
          'POST /helix/moderation/automod/message': http.Response('', 403),
        },
      );
      final noIds = await modActions(
        api,
        moderatorId: null,
      ).decideHeldMessage(auth, 'testchannel', messageId: 'm', allow: false);
      expect(noIds.failure, ModFailure.notJoined);
      final denied = await modActions(
        api,
      ).decideHeldMessage(auth, 'testchannel', messageId: 'm', allow: false);
      expect(denied.failure, ModFailure.apiError);
      expect(seen, hasLength(1));
    });
  });

  Map<String, dynamic> widget(
    String type,
    Map<String, dynamic> event,
  ) => <String, dynamic>{
    'metadata': <String, dynamic>{
      'message_type': 'notification',
      'subscription_type': type,
    },
    'payload': <String, dynamic>{
      'subscription': <String, dynamic>{
        'condition': <String, dynamic>{'broadcaster_user_id': 'broadcaster1'},
      },
      'event': event,
    },
  };

  group('notification (channel.hype_train)', () {
    test(
      'begin emits level, goal and contributors; unknown kinds keep the raw wire',
      () async {
        final events = <HypeTrainEvent>[];
        service.onHypeTrain.listen(events.add);

        service.feed(
          widget('channel.hype_train.begin', <String, dynamic>{
            'level': 2,
            'progress': 30,
            'goal': 100,
            'total': 450,
            'expires_at': '2030-01-01T00:00:00Z',
            'top_contributions': <Map<String, dynamic>>[
              {'user_name': 'bitsuser', 'type': 'BITS', 'total': 2000},
              {'user_name': 'subuser', 'type': 'SUBS', 'total': 5},
            ],
          }),
        );

        expect(events, hasLength(1));
        final e = events[0];
        expect(e.channel, 'testchannel');
        expect(e.kind, HypeTrainKind.begin);
        expect(e.level, 2);
        expect(e.progress, 30);
        expect(e.goal, 100, reason: 'the bar fills toward the level goal');
        expect(e.total, 450);
        expect(e.expiresAt, isNotNull);
        expect(e.topContributions, hasLength(2));
        expect(e.topContributions[0].userName, 'bitsuser');
        expect(e.topContributions[0].type, 'BITS');

        service.feed(
          widget('channel.hype_train.pause', <String, dynamic>{'level': 1}),
        );
        expect(events[1].kind, HypeTrainKind.unknown);
        expect(events[1].rawKind, 'pause');
      },
    );
  });

  group('parseIrcMessage', () {
    test('parses PING message', () {
      final msg = parseIrcMessage('PING :tmi.twitch.tv');
      expect(msg, isNotNull);
      expect(msg!.command, 'PING');
    });

    test('handles malformed message', () {
      final msg = parseIrcMessage(':');
      expect(msg, isNull);
    });

    test('parses tag-carrying IRC lines', () {
      for (final (name, line, command, trailing) in [
        (
          'parses CLEARCHAT with tags (timeout)',
          '@ban-duration=300;target-user-id=12345 :tmi.twitch.tv CLEARCHAT #xqc :forsen',
          'CLEARCHAT',
          'forsen',
        ),
        (
          'parses CLEARMSG with target-msg-id and login tags',
          '@login=forsen;target-msg-id=abc-123;room-id=12345 :tmi.twitch.tv CLEARMSG #xqc :bad message',
          'CLEARMSG',
          'bad message',
        ),
        (
          'handles message with spaces in trailing',
          ':user!user@user.tmi.twitch.tv PRIVMSG #channel :hello world this is a test',
          'PRIVMSG',
          'hello world this is a test',
        ),
        (
          'keeps colons and space runs inside trailing verbatim',
          ':user!user@user.tmi.twitch.tv PRIVMSG #channel :a  :b c ',
          'PRIVMSG',
          'a  :b c ',
        ),
        (
          'parses NOTICE with tags',
          '@msg-id=slow_mode :tmi.twitch.tv NOTICE #xqc :You are sending messages too fast.',
          'NOTICE',
          'You are sending messages too fast.',
        ),
        (
          'parses WHISPER message',
          '@badges=;color=#FF0000;display-name=SomeUser;emotes=;message-id=whisper-1;thread-id=abc;turbo=0;user-id=999;user-type= :someuser!someuser@someuser.tmi.twitch.tv WHISPER recipient :hey there',
          'WHISPER',
          'hey there',
        ),
      ]) {
        final msg = parseIrcMessage(line);
        expect(msg, isNotNull, reason: name);
        expect(msg!.command, command, reason: name);
        expect(msg.trailing, trailing, reason: name);
      }
    });
  });

  group('parseIrcEmotePositions', () {
    test('maps tag offset to emote code with no supplementary chars', () {
      const text = 'hey app LUL';
      final positions = parseIrcEmotePositions(
        'emotesv2_1:8-10',
        originalText: text,
        strippedText: text,
      );
      expect(positions, hasLength(1));
      expect(positions!.first.emoteId, 'emotesv2_1');
      expect(positions.first.emoteCode, 'LUL');
      expect(positions.first.startIndex, 8);
      expect(positions.first.endIndex, 11);
    });

    test('adjusts for supplementary characters before the emote', () {
      // '🙂' is a single codepoint occupying 2 UTF-16 units; the tag offset
      // counts it as 1, so the emote (at UTF-16 index 7..10) reads as 6..8
      // in tag space and must be shifted forward by 1 in Dart indexing.
      const text = '🙂 hey LUL';
      final positions = parseIrcEmotePositions(
        'emotesv2_2:6-8',
        originalText: text,
        strippedText: text,
      );
      expect(positions, hasLength(1));
      expect(positions!.first.emoteCode, 'LUL');
      expect(positions.first.startIndex, 7);
      expect(positions.first.endIndex, 10);
    });

    test('returns null for empty or null tag', () {
      expect(
        parseIrcEmotePositions('', originalText: 'x', strippedText: 'x'),
        isNull,
      );
      expect(
        parseIrcEmotePositions(null, originalText: 'x', strippedText: 'x'),
        isNull,
      );
    });

    test('handles 100 repeated positions past supplementary chars', () {
      final text = '🙂 ${List.filled(100, 'K').join(' ')}';
      final ranges = List.generate(100, (i) {
        final start = 2 + i * 2;
        return '$start-$start';
      }).join(',');
      final positions = parseIrcEmotePositions(
        '25:$ranges',
        originalText: text,
        strippedText: text,
      );
      expect(positions, hasLength(100));
      expect(positions!.first.startIndex, 3);
      expect(positions.first.emoteCode, 'K');
      expect(positions.last.emoteCode, 'K');
      for (var i = 1; i < positions.length; i++) {
        expect(
          positions[i].startIndex,
          greaterThan(positions[i - 1].startIndex),
        );
      }
    });

    test('ACTION messages adjust emote positions', () {
      for (final (name, tag, original, stripped, prefix, start, end) in [
        (
          'ACTION messages use body-relative positions',
          '25:0-4',
          '\x01ACTION Kappa\x01',
          'Kappa',
          0,
          0,
          5,
        ),
        (
          'ACTION messages with reply prefix adjust by reply length only',
          '25:9-13',
          '\x01ACTION @User hi Kappa\x01',
          'hi Kappa',
          6,
          3,
          8,
        ),
      ]) {
        final positions = parseIrcEmotePositions(
          tag,
          originalText: original,
          strippedText: stripped,
          prefixLen: prefix,
        );
        expect(positions, hasLength(1), reason: name);
        expect(positions!.first.emoteCode, 'Kappa', reason: name);
        expect(positions.first.startIndex, start, reason: name);
        expect(positions.first.endIndex, end, reason: name);
      }
    });
  });

  group('shared chat', () {
    (String?, String?) source(String raw) {
      final msg = RecentMessagesService.parseIrcLine(raw)!;
      return (msg.sourceBroadcasterId, msg.sourceMessageId);
    }

    test('only mirrored PRIVMSGs carry the source chip fields', () {
      expect(
        source(
          '@display-name=Forsen;id=copy-1;room-id=9999;source-id=orig-1;source-room-id=1234;user-id=42 :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :Hello',
        ),
        ('1234', 'orig-1'),
      );
      expect(
        source(
          '@display-name=XQC;id=native-1;room-id=9999;source-room-id=9999;user-id=99 :xqc!xqc@xqc.tmi.twitch.tv PRIVMSG #xqc :My own',
        ),
        (null, null),
        reason: 'native message during a session',
      );
      expect(
        source(
          '@display-name=Forsen;id=abc-123;user-id=42 :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :Plain',
        ),
        (null, null),
      );
    });

    test('mirrored USERNOTICEs keep only announcements', () {
      for (final kind in ['resub', 'bitsbadgetier']) {
        expect(
          RecentMessagesService.parseIrcLine(
            '@msg-id=sharedchatnotice;source-msg-id=$kind;login=forsen;system-msg=x; :tmi.twitch.tv USERNOTICE #xqc',
          ),
          isNull,
          reason: kind,
        );
      }
      expect(
        RecentMessagesService.parseAnnouncementChild(
          '@msg-id=sharedchatnotice;source-msg-id=resub;login=forsen; :tmi.twitch.tv USERNOTICE #xqc :Some text',
        ),
        isNull,
      );

      const announcement =
          '@msg-id=sharedchatnotice;source-msg-id=announcement;login=forsen;display-name=Forsen;msg-param-color=PURPLE;user-id=42;id=c1; :tmi.twitch.tv USERNOTICE #xqc :Hello';
      final label = RecentMessagesService.parseIrcLine(announcement)!;
      expect(label.text, 'Announcement');
      expect(label.systemAccent, isNotNull);
      final child = RecentMessagesService.parseAnnouncementChild(announcement)!;
      expect((child.login, child.text), ('forsen', 'Hello'));
    });
  });

  group('parseIrcGifPositions', () {
    test('parses docs example into one attachment', () {
      const text = '[Y A Y Yes GIF by Djemilah Birnie]';
      final gifs = parseIrcGifPositions(
        '0-33|joSNxeswxuc74Juo8X|https://media4.giphy.com/media/joSNxeswxuc74Juo8X/giphy.gif?cid=abc&rid=giphy.gif&ct=g',
        originalText: text,
        strippedText: text,
      );
      expect(gifs, hasLength(1));
      expect(gifs!.first.gifId, 'joSNxeswxuc74Juo8X');
      expect(gifs.first.startIndex, 0);
      expect(gifs.first.endIndex, text.length);
      expect(gifs.first.url, contains('media4.giphy.com'));
    });

    test('returns null for empty or null tag', () {
      expect(
        parseIrcGifPositions('', originalText: 'x', strippedText: 'x'),
        isNull,
      );
      expect(
        parseIrcGifPositions(null, originalText: 'x', strippedText: 'x'),
        isNull,
      );
    });

    test('skips malformed entries and non-https urls', () {
      const text = 'hello world';
      final gifs = parseIrcGifPositions(
        'bogus,0-4|id1|http://insecure/x.gif,0-4|id2|https://giphy.com/x.gif',
        originalText: text,
        strippedText: text,
      );
      expect(gifs, hasLength(1));
      expect(gifs!.first.gifId, 'id2');
    });

    test('full PRIVMSG with gifs tag round-trips through json', () {
      const raw =
          '@badge-info=subscriber/30;badges=broadcaster/1,subscriber/0;'
          'color=#033700;display-name=TwitchDev;emotes=;first-msg=0;flags=;'
          'gifs=0-33|joSNxeswxuc74Juo8X|https://media4.giphy.com/media/joSNxeswxuc74Juo8X/giphy.gif?cid=abc&rid=giphy.gif&ct=g;'
          'id=401abf17-7e99-45d6-9bdf-43934e839327;mod=0;room-id=12826;'
          'subscriber=1;tmi-sent-ts=1783632907018;turbo=0;user-id=141981764;'
          'user-type= :twitchdev!twitchdev@twitchdev.tmi.twitch.tv PRIVMSG #twitch :[Y A Y Yes GIF by Djemilah Birnie]';
      final irc = parseIrcMessage(raw)!;
      final msg = parseIrcChatMessage(irc, channel: 'twitch');
      expect(msg.gifAttachments, hasLength(1));
      final restored = TwitchMessage.fromJson(msg.toJson());
      expect(restored.gifAttachments, hasLength(1));
      expect(restored.gifAttachments!.first.url, msg.gifAttachments!.first.url);
    });
  });
}
