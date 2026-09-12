import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/client/session.dart';
import 'package:ermchat/eventsub/topics.dart';
import 'package:ermchat/eventsub/transport/connection.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';

// The subscription types per family, mirroring the production table. Failing
// every sibling isolates one family's success rule.
const _automodTypes = ['automod.message.hold', 'automod.message.update'];
const _feedTypes = [
  'channel.shield_mode.begin',
  'channel.shield_mode.end',
  'channel.shoutout.create',
  'channel.shoutout.receive',
  'channel.warning.send',
  'channel.warning.acknowledge',
];
const _inboxTypes = [
  'channel.unban_request.create',
  'channel.unban_request.resolve',
  'automod.terms.update',
];
const _trustTypes = [
  'automod.settings.update',
  'channel.suspicious_user.message',
  'channel.suspicious_user.update',
];
const _pointsTypes = [
  'channel.channel_points_custom_reward.add',
  'channel.channel_points_custom_reward.update',
  'channel.channel_points_custom_reward.remove',
  'channel.channel_points_custom_reward_redemption.add',
  'channel.channel_points_custom_reward_redemption.update',
];

class _TopicsEventSub extends EventSubService {
  String? sessionOverride = 'sess-1';

  @override
  String? get sessionId => sessionOverride;
}

void main() {
  late Chat chat;
  late Session session;
  late TwitchAuth auth;
  late _TopicsEventSub eventSub;
  late TwitchApi api;
  late EventSubTopics topics;
  late Map<String, int> script;
  late List<String> seenTypes;
  late int calls;

  void buildTopics() {
    topics = EventSubTopics(
      twitchApi: api,
      twitchAuth: auth,
      session: session,
      chat: chat,
      eventSub: eventSub,
    );
  }

  setUp(() {
    chat = Chat();
    chat.ensure('testchannel');
    chat.channelFor('testchannel')!.info.setBroadcasterId('broadcaster1');
    session = Session();
    session.seed('moduser', userId: 'mod1');
    auth = TwitchAuth();
    auth.accessToken = 'test-token';
    eventSub = _TopicsEventSub();
    script = {};
    seenTypes = [];
    calls = 0;
    api = TwitchApi(
      client: MockClient((request) async {
        calls++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        seenTypes.add(body['type'] as String);
        return http.Response('', script[body['type']] ?? 202);
      }),
    );
    buildTopics();
  });

  tearDown(() {
    eventSub.dispose();
  });

  // Lets the unawaited per-family subscribes finish their Helix calls.
  Future<void> flush() => Future.delayed(const Duration(milliseconds: 100));

  int modVersion() => chat.channelFor('testchannel')!.moderation.version.value;

  void failAll(Iterable<String> types) {
    for (final type in types) {
      script[type] = 500;
    }
  }

  group('moderation (single)', () {
    test('success sets the active set and wakes the mod view', () async {
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(topics.isModerationActive('testchannel'), isTrue);
      expect(modVersion(), greaterThan(0));
    });

    test('403 sets the skip set: no retry on the next join', () async {
      script['channel.moderate'] = 403;
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(topics.isModerationActive('testchannel'), isFalse);
      final first = calls;
      expect(first, greaterThan(0));
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(calls, first);
    });

    test('non-403 failure sets neither set: the next join retries', () async {
      script['channel.moderate'] = 500;
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(topics.isModerationActive('testchannel'), isFalse);
      final first = calls;
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      // Only the failed moderation subscription retries.
      expect(calls, first + 1);
    });
  });

  group('automod (all)', () {
    test('both types up activates and wakes the mod view', () async {
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(topics.isAutomodActive('testchannel'), isTrue);
      expect(modVersion(), greaterThan(0));
    });

    test('partial success leaves the queue inactive', () async {
      script['automod.message.update'] = 500;
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(topics.isAutomodActive('testchannel'), isFalse);
    });

    test('403 on hold dooms update too', () async {
      script['automod.message.hold'] = 403;
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(topics.isAutomodActive('testchannel'), isFalse);
      expect(seenTypes.where((t) => t.startsWith('automod.message.')), [
        'automod.message.hold',
      ]);
    });
  });

  group('feed/inbox/trust/points (any)', () {
    final families = {
      'feed': (
        check: (EventSubTopics t) => t.isFeedActive('testchannel'),
        types: _feedTypes,
      ),
      'inbox': (
        check: (EventSubTopics t) => t.isInboxActive('testchannel'),
        types: _inboxTypes,
      ),
      'trust': (
        check: (EventSubTopics t) => t.isTrustActive('testchannel'),
        types: _trustTypes,
      ),
      'points': (
        check: (EventSubTopics t) => t.isPointsActive('testchannel'),
        types: _pointsTypes,
      ),
    };

    test('one success activates even when the rest fail', () async {
      session.seed('owner', userId: 'broadcaster1');
      buildTopics();
      for (final family in families.values) {
        // First type succeeds, every sibling fails.
        failAll(family.types.skip(1));
      }
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      for (final family in families.values) {
        expect(family.check(topics), isTrue);
      }
    });

    test('403 on one type dooms the rest of the family', () async {
      script['channel.shield_mode.begin'] = 403;
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(topics.isFeedActive('testchannel'), isFalse);
      expect(seenTypes.where((t) => t.startsWith('channel.shield_mode.')), [
        'channel.shield_mode.begin',
      ]);
    });
  });

  group('widgets (all)', () {
    setUp(() {
      session.seed('owner', userId: 'broadcaster1');
      buildTopics();
    });

    test('all types up activates without waking the mod view', () async {
      failAll([
        'channel.moderate',
        ..._automodTypes,
        ..._feedTypes,
        ..._inboxTypes,
        ..._trustTypes,
        ..._pointsTypes,
      ]);
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(topics.isWidgetActive('testchannel'), isTrue);
      expect(modVersion(), 0);
    });

    test('any failure leaves widgets inactive', () async {
      script['channel.poll.begin'] = 500;
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(topics.isWidgetActive('testchannel'), isFalse);
    });

    test('403 skips the channel silently', () async {
      script['channel.hype_train.begin'] = 403;
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(topics.isWidgetActive('testchannel'), isFalse);
      expect(seenTypes.where((t) => t.startsWith('channel.hype_train.')), [
        'channel.hype_train.begin',
      ]);
      final first = calls;
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(calls, first);
    });

    test('join re-runs widgets while other families stay guarded', () async {
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(topics.isWidgetActive('testchannel'), isTrue);
      expect(topics.isModerationActive('testchannel'), isTrue);
      final widgetCalls = seenTypes
          .where((t) => t.startsWith('channel.hype_train.'))
          .length;
      final moderationCalls = seenTypes
          .where((t) => t == 'channel.moderate')
          .length;
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      // Widgets skip the already-subscribed guard on the join path.
      expect(
        seenTypes.where((t) => t.startsWith('channel.hype_train.')).length,
        greaterThan(widgetCalls),
      );
      expect(
        seenTypes.where((t) => t == 'channel.moderate').length,
        moderationCalls,
      );
    });
  });

  group('broadcaster gate', () {
    test('points and widgets make no calls for non-broadcaster', () async {
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(topics.isPointsActive('testchannel'), isFalse);
      expect(topics.isWidgetActive('testchannel'), isFalse);
      expect(seenTypes.where((t) => t.contains('channel_points')), isEmpty);
      expect(seenTypes.where((t) => t.contains('hype_train')), isEmpty);
      expect(seenTypes.where((t) => t.contains('channel.poll.')), isEmpty);
      expect(
        seenTypes.where((t) => t.contains('channel.prediction.')),
        isEmpty,
      );
    });

    test('points and widgets subscribe for the broadcaster', () async {
      session.seed('owner', userId: 'broadcaster1');
      buildTopics();
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(topics.isPointsActive('testchannel'), isTrue);
      expect(topics.isWidgetActive('testchannel'), isTrue);
    });
  });

  group('gates', () {
    test('no session login means no subscriptions', () async {
      session = Session();
      buildTopics();
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(calls, 0);
    });

    test('no EventSub session means no subscriptions', () async {
      eventSub.sessionOverride = null;
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await Future.delayed(const Duration(seconds: 4));
      expect(calls, 0);
      expect(topics.isModerationActive('testchannel'), isFalse);
    });
  });

  group('isBroadcaster', () {
    test('true when the session owns the channel', () {
      session.seed('owner', userId: 'broadcaster1');
      buildTopics();
      expect(topics.isBroadcaster('testchannel'), isTrue);
    });

    test('false for other channels and anonymous sessions', () {
      expect(topics.isBroadcaster('testchannel'), isFalse);
      expect(topics.isBroadcaster('unknown'), isFalse);
      session = Session();
      buildTopics();
      expect(topics.isBroadcaster('testchannel'), isFalse);
    });
  });

  group('clear vs reset vs forget', () {
    test('clearSessionState drops actives but keeps skips', () async {
      script['automod.message.hold'] = 403;
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(topics.isModerationActive('testchannel'), isTrue);
      final moderationCalls = seenTypes
          .where((t) => t == 'channel.moderate')
          .length;
      final holdCalls = seenTypes
          .where((t) => t == 'automod.message.hold')
          .length;

      topics.clearSessionState();
      expect(topics.isModerationActive('testchannel'), isFalse);

      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      // Active dropped: moderation re-subscribes. Skip kept: no hold retry.
      expect(topics.isModerationActive('testchannel'), isTrue);
      expect(
        seenTypes.where((t) => t == 'channel.moderate').length,
        moderationCalls + 1,
      );
      expect(
        seenTypes.where((t) => t == 'automod.message.hold').length,
        holdCalls,
      );
    });

    test('resetAccountScope drops skips but keeps actives', () async {
      script['automod.message.hold'] = 403;
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(topics.isModerationActive('testchannel'), isTrue);
      final moderationCalls = seenTypes
          .where((t) => t == 'channel.moderate')
          .length;
      final holdCalls = seenTypes
          .where((t) => t == 'automod.message.hold')
          .length;

      topics.resetAccountScope();
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      // Active kept: no moderation re-subscribe. Skip dropped: hold retried.
      expect(topics.isModerationActive('testchannel'), isTrue);
      expect(
        seenTypes.where((t) => t == 'channel.moderate').length,
        moderationCalls,
      );
      expect(
        seenTypes.where((t) => t == 'automod.message.hold').length,
        holdCalls + 1,
      );
    });

    test('forgetChannel drops one channel actives, skips survive', () async {
      chat.ensure('other');
      chat.channelFor('other')!.info.setBroadcasterId('broadcaster2');
      topics.subscribeChannel('testchannel', 'broadcaster1');
      topics.subscribeChannel('other', 'broadcaster2');
      await flush();
      expect(topics.isModerationActive('testchannel'), isTrue);
      expect(topics.isModerationActive('other'), isTrue);

      topics.forgetChannel('testchannel');
      expect(topics.isModerationActive('testchannel'), isFalse);
      expect(topics.isModerationActive('other'), isTrue);

      topics.resubscribeEventSubChannels(['testchannel', 'other']);
      await flush();
      // Only the forgotten channel re-subscribes.
      expect(topics.isModerationActive('testchannel'), isTrue);
      expect(seenTypes.where((t) => t == 'channel.moderate').length, 3);
    });

    test('resubscribe restores the session state', () async {
      session.seed('owner', userId: 'broadcaster1');
      buildTopics();
      topics.subscribeChannel('testchannel', 'broadcaster1');
      await flush();
      expect(topics.isModerationActive('testchannel'), isTrue);
      expect(topics.isWidgetActive('testchannel'), isTrue);

      topics.clearSessionState();
      topics.resubscribeEventSubChannels(['testchannel']);
      await flush();
      expect(topics.isModerationActive('testchannel'), isTrue);
      expect(topics.isWidgetActive('testchannel'), isTrue);
    });
  });
}
