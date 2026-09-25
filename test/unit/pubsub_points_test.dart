import 'dart:async';
import 'dart:convert';

import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/models/point_rewards.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/pubsub_points_consumer.dart';
import 'package:ermchat/services/pubsub_points_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> redemptionJson({
  String id = 'r1',
  bool requiresInput = false,
  Map<String, dynamic>? image,
  Map<String, dynamic>? defaultImage,
}) => {
  'id': id,
  'user': {'id': 'u1', 'login': 'fan', 'display_name': 'Fan'},
  'reward': {
    'id': 'rw1',
    'title': 'Hydrate',
    'cost': 500,
    'is_user_input_required': requiresInput,
    'image': image,
    'default_image':
        defaultImage ??
        {
          'url_1x': 'https://cdn/x/1.png',
          'url_2x': 'https://cdn/x/2.png',
          'url_4x': 'https://cdn/x/4.png',
        },
  },
};

String messageFrame(String topic, Map<String, dynamic> inner) => jsonEncode({
  'type': 'MESSAGE',
  'data': {'topic': topic, 'message': jsonEncode(inner)},
});

Map<String, dynamic> rewardRedeemed({bool requiresInput = false}) => {
  'type': 'reward-redeemed',
  'data': {
    'timestamp': '2026-09-17T00:00:00.000Z',
    'redemption': {
      'id': 'r1',
      'user': {'id': 'u1', 'login': 'fan', 'display_name': 'Fan'},
      'reward': {
        'id': 'rw1',
        'title': 'Hydrate',
        'cost': 500,
        'is_user_input_required': requiresInput,
        'image': null,
        'default_image': {
          'url_1x': 'https://cdn/x/1.png',
          'url_2x': 'https://cdn/x/2.png',
          'url_4x': 'https://cdn/x/4.png',
        },
      },
    },
  },
};

PointRedemption redemption({
  String id = 'r1',
  String rewardId = 'rw1',
  bool requiresInput = false,
}) => PointRedemption(
  id: id,
  userLogin: 'fan',
  userDisplayName: 'Fan',
  rewardId: rewardId,
  rewardTitle: 'Hydrate',
  cost: 500,
  userInput: '',
  status: 'UNFULFILLED',
  redeemedAt: '2026-09-17T00:00:00.000Z',
  requiresUserInput: requiresInput,
  imageUrl: 'https://cdn/x/4.png',
);

void main() {
  group('PointRedemption.fromPubSub', () {
    test('parses user, reward, and large image fallback', () {
      final redemption = PointRedemption.fromPubSub(
        redemptionJson(),
        '2026-09-17T00:00:00.000Z',
      );
      expect(redemption.id, 'r1');
      expect(redemption.userLogin, 'fan');
      expect(redemption.userDisplayName, 'Fan');
      expect(redemption.rewardId, 'rw1');
      expect(redemption.rewardTitle, 'Hydrate');
      expect(redemption.cost, 500);
      expect(redemption.requiresUserInput, isFalse);
      expect(redemption.imageUrl, 'https://cdn/x/4.png');
      expect(redemption.redeemedAt, '2026-09-17T00:00:00.000Z');
    });

    test('prefers the custom image over the default set', () {
      final redemption = PointRedemption.fromPubSub(
        redemptionJson(
          image: {
            'url_1x': 'https://cdn/custom/1.png',
            'url_2x': 'https://cdn/custom/2.png',
            'url_4x': 'https://cdn/custom/4.png',
          },
        ),
        '2026-09-17T00:00:00.000Z',
      );
      expect(redemption.imageUrl, 'https://cdn/custom/4.png');
    });

    test('missing fields degrade to empty, never throw', () {
      final redemption = PointRedemption.fromPubSub(const {}, '');
      expect(redemption.id, isEmpty);
      expect(redemption.userLogin, isEmpty);
      expect(redemption.rewardId, isEmpty);
      expect(redemption.rewardTitle, isEmpty);
      expect(redemption.cost, 0);
      expect(redemption.imageUrl, isNull);
    });
  });

  group('PubSubPointsService frames', () {
    test('routes reward-redeemed to the mapped channel', () async {
      final service = PubSubPointsService();
      addTearDown(service.dispose);
      service.seedTopic('shroud', '12345');
      final events = <PubSubPointRedemption>[];
      final sub = service.onRedemption.listen(events.add);
      addTearDown(sub.cancel);

      service.feedText(
        messageFrame('community-points-channel-v1.12345', rewardRedeemed()),
      );

      expect(events, hasLength(1));
      expect(events.single.channel, 'shroud');
      expect(events.single.redemption.rewardTitle, 'Hydrate');
      expect(events.single.redemption.imageUrl, 'https://cdn/x/4.png');
    });

    test('ignores unknown topics, other types, and malformed frames', () {
      final service = PubSubPointsService();
      addTearDown(service.dispose);
      service.seedTopic('shroud', '12345');
      var count = 0;
      final sub = service.onRedemption.listen((_) => count++);
      addTearDown(sub.cancel);

      // Topic with no channel mapping (parted race).
      service.feedText(
        messageFrame('community-points-channel-v1.99999', rewardRedeemed()),
      );
      // Wrong inner type.
      service.feedText(
        messageFrame('community-points-channel-v1.12345', {
          'type': 'something-else',
          'data': {},
        }),
      );
      // Not JSON at all.
      service.feedText('definitely not json {{{');
      // PONG and error RESPONSE are control frames, not redemptions.
      service.feedText('{"type":"PONG"}');
      service.feedText('{"type":"RESPONSE","error":"ERR_BADAUTH"}');

      expect(count, 0);
    });

    test('listen is idempotent and unlisten drops the mapping', () {
      final service = PubSubPointsService();
      addTearDown(service.dispose);
      service.seedTopic('shroud', '12345');
      var count = 0;
      final sub = service.onRedemption.listen((_) => count++);
      addTearDown(sub.cancel);

      service.unlistenChannel('shroud');
      service.feedText(
        messageFrame('community-points-channel-v1.12345', rewardRedeemed()),
      );
      expect(count, 0);
    });
  });

  group('PubSubPointsConsumer', () {
    test('stages input-required partners for takeStaged', () async {
      final chat = Chat();
      addTearDown(chat.dispose);
      final source = StreamController<PubSubPointRedemption>.broadcast(
        sync: true,
      );
      final consumer = PubSubPointsConsumer(
        chat: chat,
        getMaxMessages: () => 500,
      );
      addTearDown(() async {
        consumer.dispose();
        await source.close();
      });
      consumer.attach(source.stream);

      source.add(
        PubSubPointRedemption(
          channel: 'shroud',
          redemption: redemption(requiresInput: true),
        ),
      );

      final staged = consumer.takeStaged('shroud', 'rw1');
      expect(staged?.rewardTitle, 'Hydrate');
      expect(staged?.imageUrl, 'https://cdn/x/4.png');
      expect(consumer.takeStaged('shroud', 'rw1'), isNull);
    });

    test('no-input redemptions post standalone headers', () async {
      final chat = Chat();
      addTearDown(chat.dispose);
      final source = StreamController<PubSubPointRedemption>.broadcast(
        sync: true,
      );
      final consumer = PubSubPointsConsumer(
        chat: chat,
        getMaxMessages: () => 500,
      );
      addTearDown(() async {
        consumer.dispose();
        await source.close();
      });
      consumer.attach(source.stream);
      chat.ensure('shroud');

      source.add(
        PubSubPointRedemption(channel: 'shroud', redemption: redemption()),
      );

      final items = chat.channelFor('shroud')!.messages.items;
      expect(items, hasLength(1));
      expect(items.single.isSystem, isTrue);
      expect(items.single.text, 'Fan redeemed Hydrate (500 pts)');
      expect(items.single.messageId, 'redemp:r1');
      expect(items.single.redemptionImageUrl, 'https://cdn/x/4.png');

      // Same redemption id dedups instead of stacking.
      source.add(
        PubSubPointRedemption(channel: 'shroud', redemption: redemption()),
      );
      expect(chat.channelFor('shroud')!.messages.items, hasLength(1));
    });

    test('late PubSub retro-inserts the header above its chat line', () async {
      final chat = Chat();
      addTearDown(chat.dispose);
      final source = StreamController<PubSubPointRedemption>.broadcast(
        sync: true,
      );
      final consumer = PubSubPointsConsumer(
        chat: chat,
        getMaxMessages: () => 500,
      );
      addTearDown(() async {
        consumer.dispose();
        await source.close();
      });
      consumer.attach(source.stream);

      chat.receive(
        'shroud',
        TwitchMessage(
          login: 'fan',
          displayName: 'Fan',
          text: 'highlight me',
          messageId: 'm1',
          channel: 'shroud',
          customRewardId: 'rw1',
        ),
        maxMessages: 500,
        isSelected: true,
        ownLogin: null,
      );
      consumer.noteIrcRedemption('shroud', 'rw1', 'm1');
      source.add(
        PubSubPointRedemption(
          channel: 'shroud',
          redemption: redemption(requiresInput: true),
        ),
      );

      // Newest-first: chat line first, header directly above it in display.
      final items = chat.channelFor('shroud')!.messages.items;
      expect(items.map((m) => m.messageId), ['m1', 'redemp:r1']);
      expect(items[1].text, 'Redeemed Hydrate (500 pts)');
    });

    test('expired partners fall back instead of pairing', () async {
      final chat = Chat();
      addTearDown(chat.dispose);
      var now = DateTime(2026, 9, 17);
      final source = StreamController<PubSubPointRedemption>.broadcast(
        sync: true,
      );
      final consumer = PubSubPointsConsumer(
        chat: chat,
        getMaxMessages: () => 500,
        clock: () => now,
      );
      addTearDown(() async {
        consumer.dispose();
        await source.close();
      });
      consumer.attach(source.stream);

      source.add(
        PubSubPointRedemption(
          channel: 'shroud',
          redemption: redemption(requiresInput: true),
        ),
      );
      now = now.add(const Duration(seconds: 11));
      expect(consumer.takeStaged('shroud', 'rw1'), isNull);
    });

    test('companion header posts before its chat line', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final consumer = PubSubPointsConsumer(
        chat: chat,
        getMaxMessages: () => 500,
      );
      addTearDown(consumer.dispose);

      expect(
        consumer.insertCompanionHeader(
          'shroud',
          redemption(requiresInput: true),
        ),
        isFalse,
        reason: 'no channel yet, nothing to attach to',
      );
      chat.ensure('shroud');
      expect(
        consumer.insertCompanionHeader(
          'shroud',
          redemption(requiresInput: true),
        ),
        isTrue,
      );
      expect(
        chat.channelFor('shroud')!.messages.items.single.text,
        'Redeemed Hydrate (500 pts)',
      );
    });
  });
}
