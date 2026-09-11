import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/client/session.dart';
import 'package:ermchat/eventsub/decode/decoder.dart';
import 'package:ermchat/eventsub/topics.dart';
import 'package:ermchat/eventsub/transport/connection.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/eventsub_consumer.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';

class _ConsumerEventSub extends EventSubService {
  String? sessionOverride = 'sess-1';

  @override
  String? get sessionId => sessionOverride;
}

Map<String, dynamic> _frame(
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

Map<String, dynamic> _moderate({
  required String action,
  Map<String, dynamic>? meta,
  String moderatorName = 'moduser',
}) => _frame('channel.moderate', <String, dynamic>{
  'action': action,
  'moderator_user_name': moderatorName,
  ...?meta,
});

void main() {
  late Chat chat;
  late Session session;
  late EventSubTopics topics;
  late EventSubDecoder decoder;
  late EventSubConsumer consumer;
  late _ConsumerEventSub eventSub;
  late Map<String, int> script;
  late List<(String, String)> lines;
  late List<(String, bool)> analytics;
  late List<String> hypeKinds;
  late Map<String, DateTime> armed;
  late Set<String> cleared;

  setUp(() {
    chat = Chat();
    chat.ensure('testchannel');
    chat.channelFor('testchannel')!.info.setBroadcasterId('broadcaster1');
    session = Session();
    session.seed('owner', userId: 'broadcaster1');
    eventSub = _ConsumerEventSub();
    script = {};
    lines = [];
    analytics = [];
    hypeKinds = [];
    armed = {};
    cleared = {};
    final auth = TwitchAuth();
    auth.accessToken = 'test-token';
    // The script consults per-type statuses for fallback-path tests.
    topics = EventSubTopics(
      twitchApi: TwitchApi(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('', script[body['type']] ?? 202);
        }),
      ),
      twitchAuth: auth,
      session: session,
      chat: chat,
      eventSub: eventSub,
    );
    decoder = EventSubDecoder(Stream<Map<String, dynamic>>.empty());
    decoder.setChannelMapping('broadcaster1', 'testchannel');
    consumer = EventSubConsumer(
      chat: chat,
      session: session,
      topics: topics,
      onSystemMessage: (c, t, {Color? accent, String? messageId}) {
        lines.add((c, t));
      },
      onAnalyticsModeration: (c, isTimeout) => analytics.add((c, isTimeout)),
      onHypeTrain: (event) => hypeKinds.add(event.kind),
      onSelfTimeoutArmed: (c, until) => armed[c] = until,
      onSelfTimeoutCleared: (c) => cleared.add(c),
    );
    consumer.attach(decoder);
  });

  tearDown(() {
    consumer.dispose();
    decoder.dispose();
    eventSub.dispose();
  });

  // Activates every family through the real topics path.
  Future<void> subscribeAll() async {
    topics.subscribeChannel('testchannel', 'broadcaster1');
    await Future.delayed(const Duration(milliseconds: 100));
  }

  // Drops the session state, fails moderation re-subscribes, and brings the
  // other families back so fallback paths run with their gate still up.
  Future<void> subscribeWithoutModeration() async {
    topics.clearSessionState();
    script['channel.moderate'] = 500;
    topics.subscribeChannel('testchannel', 'broadcaster1');
    await Future.delayed(const Duration(milliseconds: 100));
    expect(topics.isModerationActive('testchannel'), isFalse);
  }

  void seedMessage(String id, String login, String text) {
    chat
        .channelFor('testchannel')!
        .receive(
          TwitchMessage(
            login: login,
            text: text,
            channel: 'testchannel',
            messageId: id,
          ),
          maxMessages: 100,
          isSelected: false,
          ownLogin: null,
        );
  }

  bool isDeleted(String id) =>
      chat.channelFor('testchannel')!.messages.byId(id)?.deleted ?? false;

  List<String> feedActions() => [
    for (final e in chat.channelFor('testchannel')!.moderation.feed) e.action,
  ];

  group('moderation delete/clear', () {
    test('delete marks the message and announces with the body', () async {
      await subscribeAll();
      seedMessage('msg-1', 'spammer', 'hello');
      decoder.feed(
        _moderate(
          action: 'delete',
          meta: {
            'delete': {
              'user_name': 'spammer',
              'message_id': 'msg-1',
              'message_body': 'hello',
            },
          },
        ),
      );
      expect(isDeleted('msg-1'), isTrue);
      expect(lines.last.$2, 'moduser deleted a message from spammer: "hello".');
      expect(feedActions().first, 'delete');
    });

    test('delete without the subscription is dropped', () async {
      seedMessage('msg-1', 'spammer', 'hello');
      decoder.feed(
        _moderate(
          action: 'delete',
          meta: {
            'delete': {'user_name': 'spammer', 'message_id': 'msg-1'},
          },
        ),
      );
      expect(isDeleted('msg-1'), isFalse);
      expect(lines, isEmpty);
    });

    test('clear marks every message deleted', () async {
      await subscribeAll();
      seedMessage('msg-1', 'alice', 'one');
      seedMessage('msg-2', 'bob', 'two');
      decoder.feed(_moderate(action: 'clear', meta: {}));
      expect(isDeleted('msg-1'), isTrue);
      expect(isDeleted('msg-2'), isTrue);
      expect(lines.last.$2, 'moduser cleared the chat.');
      expect(feedActions().first, 'clear');
    });
  });

  group('ban/timeout self gate', () {
    test('ban tracks the roster and clears the user messages', () async {
      await subscribeAll();
      seedMessage('msg-1', 'spammer', 'bad');
      decoder.feed(
        _moderate(
          action: 'ban',
          meta: {
            'ban': {'user_name': 'spammer', 'reason': 'spam'},
          },
        ),
      );
      expect(isDeleted('msg-1'), isTrue);
      expect(
        chat.channelFor('testchannel')!.moderation.banFor('spammer'),
        isNotNull,
      );
      expect(lines.last.$2, 'moduser banned spammer: "spam".');
      expect(feedActions().first, 'ban');
      expect(analytics.last, ('testchannel', false));
    });

    test('self timeout arms the send gate with a personal line', () async {
      await subscribeAll();
      session.seed('victim', userId: 'u9');
      final expiresAt = DateTime.now()
          .toUtc()
          .add(const Duration(seconds: 600))
          .toIso8601String();
      decoder.feed(
        _moderate(
          action: 'timeout',
          meta: {
            'timeout': {'user_name': 'victim', 'expires_at': expiresAt},
          },
        ),
      );
      expect(armed, contains('testchannel'));
      final wait = armed['testchannel']!.difference(DateTime.now());
      expect(wait.inSeconds, greaterThan(590));
      expect(lines.last.$2, contains('You were timed out for'));
    });

    test('other timeout keeps the third-person line', () async {
      await subscribeAll();
      final expiresAt = DateTime.now()
          .toUtc()
          .add(const Duration(seconds: 600))
          .toIso8601String();
      decoder.feed(
        _moderate(
          action: 'timeout',
          meta: {
            'timeout': {'user_name': 'spammer', 'expires_at': expiresAt},
          },
        ),
      );
      expect(armed, isEmpty);
      expect(lines.last.$2, contains('moduser timed out spammer for'));
    });

    test('self unban clears the send gate', () async {
      await subscribeAll();
      session.seed('victim', userId: 'u9');
      armed['testchannel'] = DateTime.now().add(const Duration(seconds: 60));
      decoder.feed(
        _moderate(
          action: 'unban',
          meta: {
            'unban': {'user_name': 'victim'},
          },
        ),
      );
      expect(cleared, contains('testchannel'));
      expect(lines.last.$2, 'You were unbanned by moduser.');
    });
  });

  group('feed gating', () {
    test('shield toggle lands in the feed with a line', () async {
      await subscribeAll();
      decoder.feed(
        _frame('channel.shield_mode.begin', {'moderator_user_name': 'moduser'}),
      );
      expect(lines.last.$2, 'moduser enabled Shield Mode.');
      expect(feedActions().first, 'shield_on');
    });

    test('feed events without the subscription are dropped', () async {
      decoder.feed(
        _frame('channel.shield_mode.begin', {'moderator_user_name': 'moduser'}),
      );
      decoder.feed(
        _frame('channel.shoutout.create', {
          'broadcaster_user_login': 'streamer',
          'to_broadcaster_user_login': 'friend',
          'moderator_user_name': 'moduser',
        }),
      );
      expect(lines, isEmpty);
      expect(feedActions(), isEmpty);
    });

    test('warning send is skipped while moderate covers it', () async {
      await subscribeAll();
      decoder.feed(
        _frame('channel.warning.send', {
          'moderator_user_name': 'moduser',
          'user_login': 'spammer',
          'reason': 'spam',
        }),
      );
      expect(
        chat.channelFor('testchannel')!.moderation.warningsFor('spammer'),
        isEmpty,
      );
      expect(lines, isEmpty);
    });

    test('warning send logs when moderate is off', () async {
      await subscribeAll();
      await subscribeWithoutModeration();
      expect(topics.isFeedActive('testchannel'), isTrue);
      decoder.feed(
        _frame('channel.warning.send', {
          'moderator_user_name': 'moduser',
          'user_login': 'spammer',
          'reason': 'spam',
        }),
      );
      expect(
        chat.channelFor('testchannel')!.moderation.warningsFor('spammer'),
        hasLength(1),
      );
      expect(lines.last.$2, 'moduser warned spammer: "spam".');
    });

    test('warning acknowledge dismisses and announces', () async {
      await subscribeAll();
      decoder.feed(
        _moderate(
          action: 'warn',
          meta: {
            'warn': {'user_name': 'spammer', 'reason': 'spam'},
          },
        ),
      );
      expect(
        chat.channelFor('testchannel')!.moderation.warningsFor('spammer'),
        hasLength(1),
      );
      decoder.feed(
        _frame('channel.warning.acknowledge', {
          'moderator_user_name': 'moduser',
          'user_login': 'spammer',
        }),
      );
      expect(
        chat.channelFor('testchannel')!.moderation.warningsFor('spammer'),
        isEmpty,
      );
      expect(lines.last.$2, 'spammer acknowledged a warning.');
      expect(feedActions().first, 'warn_ack');
    });
  });

  group('inbox', () {
    test('unban create announces without a feed row', () async {
      await subscribeAll();
      final inboxBefore = chat
          .channelFor('testchannel')!
          .moderation
          .modInboxVersion
          .value;
      decoder.feed(
        _frame('channel.unban_request.create', {'user_login': 'spammer'}),
      );
      expect(lines.last.$2, 'spammer requested an unban.');
      expect(feedActions(), isEmpty);
      expect(
        chat.channelFor('testchannel')!.moderation.modInboxVersion.value,
        greaterThan(inboxBefore),
      );
    });

    test('unban resolve lands in the feed with a line', () async {
      await subscribeAll();
      decoder.feed(
        _frame('channel.unban_request.resolve', {
          'user_login': 'spammer',
          'moderator_user_name': 'moduser',
          'resolution_text': 'second chance',
        }),
      );
      expect(feedActions().first, 'unban_resolved');
      expect(
        lines.last.$2,
        'moduser resolved spammer\'s unban request: "second chance".',
      );
    });

    test('terms update is skipped while moderate covers it', () async {
      await subscribeAll();
      decoder.feed(
        _frame('automod.terms.update', {
          'action': 'add',
          'list': 'blocked',
          'terms': ['bad word'],
          'moderator_user_name': 'moduser',
        }),
      );
      expect(feedActions(), isEmpty);
      expect(lines, isEmpty);
    });

    test('terms update lands when moderate is off', () async {
      await subscribeAll();
      await subscribeWithoutModeration();
      expect(topics.isInboxActive('testchannel'), isTrue);
      decoder.feed(
        _frame('automod.terms.update', {
          'action': 'add',
          'list': 'blocked',
          'terms': ['bad word'],
          'moderator_user_name': 'moduser',
        }),
      );
      expect(feedActions().first, 'add_blocked_term');
      expect(lines.last.$2, 'moduser added blocked term "bad word".');
    });
  });

  group('trust', () {
    test('settings update touches setup with feed and line', () async {
      await subscribeAll();
      final settingsBefore = chat
          .channelFor('testchannel')!
          .moderation
          .modSettingsVersion
          .value;
      decoder.feed(
        _frame('automod.settings.update', {'moderator_user_name': 'moduser'}),
      );
      expect(
        chat.channelFor('testchannel')!.moderation.modSettingsVersion.value,
        greaterThan(settingsBefore),
      );
      expect(feedActions().first, 'automod_settings');
      expect(lines.last.$2, 'moduser updated AutoMod settings.');
    });

    test('suspicious message records silently', () async {
      await subscribeAll();
      decoder.feed(
        _frame('channel.suspicious_user.message', {
          'user_login': 'spammer',
          'low_trust_status': 'restricted',
        }),
      );
      expect(
        chat
            .channelFor('testchannel')!
            .moderation
            .suspiciousFor('spammer')
            ?.status,
        'restricted',
      );
      expect(lines, isEmpty);
    });

    test('suspicious update announces with a feed row', () async {
      await subscribeAll();
      decoder.feed(
        _frame('channel.suspicious_user.update', {
          'user_login': 'spammer',
          'low_trust_status': 'monitored',
          'moderator_user_name': 'moduser',
        }),
      );
      expect(feedActions().first, 'suspicious_flag');
      expect(
        lines.last.$2,
        'moduser updated the suspicious status of spammer.',
      );
    });
  });

  group('points', () {
    Map<String, dynamic> reward(String id, String title) => {
      'id': id,
      'title': title,
      'cost': 500,
    };

    Map<String, dynamic> redemption(String id, String status) => {
      'id': id,
      'user_login': 'fan',
      'user_input': status == 'UNFULFILLED' ? 'do a flip' : '',
      'status': status,
      'redeemed_at': '2026-01-02T03:04:05Z',
      'reward': {'id': 'reward1', 'title': 'Hydrate', 'cost': 500},
    };

    test('reward add merges, update replaces, remove drops', () async {
      await subscribeAll();
      final points = chat.channelFor('testchannel')!.points;
      decoder.feed(
        _frame(
          'channel.channel_points_custom_reward.add',
          reward('reward1', 'Hydrate'),
        ),
      );
      expect(points.rewards.map((r) => r.id), ['reward1']);
      decoder.feed(
        _frame(
          'channel.channel_points_custom_reward.update',
          reward('reward1', 'Hydrate+'),
        ),
      );
      expect(points.rewards.map((r) => r.id), ['reward1']);
      expect(points.rewards.first.title, 'Hydrate+');
      decoder.feed(
        _frame(
          'channel.channel_points_custom_reward.remove',
          reward('reward1', 'Hydrate+'),
        ),
      );
      expect(points.rewards, isEmpty);
      expect(lines, isEmpty);
    });

    test('unfulfilled redemption queues, update resolves', () async {
      await subscribeAll();
      final points = chat.channelFor('testchannel')!.points;
      decoder.feed(
        _frame(
          'channel.channel_points_custom_reward_redemption.add',
          redemption('red1', 'UNFULFILLED'),
        ),
      );
      expect(points.redemptions.map((r) => r.id), ['red1']);
      decoder.feed(
        _frame(
          'channel.channel_points_custom_reward_redemption.update',
          redemption('red1', 'FULFILLED'),
        ),
      );
      expect(points.redemptions, isEmpty);
    });

    test('reward events without the subscription are dropped', () async {
      decoder.feed(
        _frame(
          'channel.channel_points_custom_reward.add',
          reward('reward1', 'Hydrate'),
        ),
      );
      expect(chat.channelFor('testchannel')!.points.rewards, isEmpty);
    });
  });

  group('automod queue', () {
    Map<String, dynamic> heldEvent({String? status}) {
      final event = <String, dynamic>{
        'broadcaster_user_id': 'broadcaster1',
        'user_login': 'spammer',
        'message_id': 'msg-1',
        'message': {'text': 'bad text here', 'fragments': []},
        'automod': {'category': 'bullying', 'level': 4},
      };
      if (status != null) event['status'] = status;
      return event;
    }

    test('hold queues, resolve dequeues', () async {
      await subscribeAll();
      decoder.feed(_frame('automod.message.hold', heldEvent()));
      final held = chat.channelFor('testchannel')!.moderation.held;
      expect(held.map((m) => m.messageId), ['msg-1']);
      expect(held.first.text, 'bad text here');
      expect(lines, isEmpty);
      decoder.feed(
        _frame('automod.message.update', heldEvent(status: 'Approved')),
      );
      expect(chat.channelFor('testchannel')!.moderation.held, isEmpty);
    });

    test('hold without the subscription is dropped', () async {
      decoder.feed(_frame('automod.message.hold', heldEvent()));
      expect(chat.channelFor('testchannel')!.moderation.held, isEmpty);
    });

    test('resolve applies even without the subscription', () async {
      await subscribeAll();
      decoder.feed(_frame('automod.message.hold', heldEvent()));
      expect(chat.channelFor('testchannel')!.moderation.held, hasLength(1));
      topics.clearSessionState();
      decoder.feed(
        _frame('automod.message.update', heldEvent(status: 'Denied')),
      );
      expect(chat.channelFor('testchannel')!.moderation.held, isEmpty);
    });
  });

  group('widgets', () {
    test('hype train surfaces while subscribed', () async {
      await subscribeAll();
      decoder.feed(
        _frame('channel.hype_train.begin', {
          'level': 2,
          'progress': 30,
          'total': 100,
        }),
      );
      expect(hypeKinds, ['begin']);
    });

    test('widgets without the subscription are dropped', () async {
      decoder.feed(
        _frame('channel.hype_train.begin', {
          'level': 2,
          'progress': 30,
          'total': 100,
        }),
      );
      expect(hypeKinds, isEmpty);
    });
  });
}
