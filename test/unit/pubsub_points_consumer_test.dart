import 'dart:async';

import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/models/point_rewards.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/pubsub_points_consumer.dart';
import 'package:ermchat/services/pubsub_points_service.dart';
import 'package:flutter_test/flutter_test.dart';

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
