import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/models/point_rewards.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:flutter_test/flutter_test.dart';

TwitchMessage row(String id, {bool system = false}) => TwitchMessage(
  login: system ? '' : 'fan',
  text: system ? 'Fan redeemed Hydrate (500 pts)' : 'hello',
  messageId: id,
  channel: 'shroud',
  isSystem: system,
);

void main() {
  group('Points', () {
    test('rewards set, redemptions queue oldest first', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final points = chat.ensure('test').points;
      const reward = PointReward(
        id: 'reward1',
        title: 'Hydrate',
        cost: 500,
        isEnabled: true,
        isPaused: false,
      );
      final version = points.version.value;
      points.setRewards(const [reward]);
      expect(points.rewards, hasLength(1));
      expect(points.version.value, version + 1);

      PointRedemption redemption(String id, String at) => PointRedemption(
        id: id,
        userLogin: 'fan',
        rewardId: 'reward1',
        rewardTitle: 'Hydrate',
        cost: 500,
        userInput: '',
        status: 'UNFULFILLED',
        redeemedAt: at,
      );
      // Newest inserted first still reads oldest first.
      points.upsertRedemption(redemption('r2', '2026-01-02T00:01:00Z'));
      points.upsertRedemption(redemption('r1', '2026-01-02T00:00:00Z'));
      expect(points.redemptions.map((r) => r.id), ['r1', 'r2']);
      // Re-upsert replaces in place.
      points.upsertRedemption(redemption('r1', '2026-01-02T00:00:00Z'));
      expect(points.redemptions, hasLength(2));

      expect(points.resolveRedemption('r1'), isTrue);
      expect(points.redemptions.map((r) => r.id), ['r2']);
      expect(points.resolveRedemption('r1'), isFalse);
      expect(points.resolveRedemption('r2'), isTrue);
      expect(points.redemptions, isEmpty);
    });

    test('clear and account switch drop points state', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final points = chat.ensure('test').points;
      const reward = PointReward(
        id: 'reward1',
        title: 'Hydrate',
        cost: 500,
        isEnabled: true,
        isPaused: false,
      );
      points.setRewards(const [reward]);
      points.upsertRedemption(
        const PointRedemption(
          id: 'r1',
          userLogin: 'fan',
          rewardId: 'reward1',
          rewardTitle: 'Hydrate',
          cost: 500,
          userInput: '',
          status: 'UNFULFILLED',
          redeemedAt: '2026-01-02T00:00:00Z',
        ),
      );
      final version = points.version.value;
      chat.ensure('empty').points.clear();
      expect(
        chat.channelFor('empty')!.points.version.value,
        0,
        reason: 'no-op is quiet',
      );
      points.clear();
      expect(points.rewards, isEmpty);
      expect(points.redemptions, isEmpty);
      expect(points.version.value, version + 1);

      points.setRewards(const [reward]);
      points.clearForAccountSwitch();
      expect(points.rewards, isEmpty);
      chat.remove('test');
      expect(chat.channelFor('test'), isNull);
    });
  });

  group('redemption header retro-insert', () {
    test('insertAfter lands directly above the target line', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      const max = 500;
      for (final id in ['m1', 'm2']) {
        chat.receive(
          'shroud',
          row(id),
          maxMessages: max,
          isSelected: true,
          ownLogin: null,
        );
      }
      // Newest-first: m2 on top.
      expect(
        chat.channelFor('shroud')!.messages.items.map((m) => m.messageId),
        ['m2', 'm1'],
      );

      final ok = chat
          .channelFor('shroud')!
          .insertHeaderAbove(
            'm2',
            row('redemp:r1', system: true),
            maxMessages: max,
          );

      expect(ok, isTrue);
      expect(
        chat.channelFor('shroud')!.messages.items.map((m) => m.messageId),
        ['m2', 'redemp:r1', 'm1'],
      );
    });

    test('misses on gone targets and duplicate header ids', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      const max = 500;
      chat.receive(
        'shroud',
        row('m1'),
        maxMessages: max,
        isSelected: true,
        ownLogin: null,
      );
      final channel = chat.channelFor('shroud')!;

      expect(
        channel.insertHeaderAbove(
          'missing',
          row('redemp:r1', system: true),
          maxMessages: max,
        ),
        isFalse,
      );
      expect(
        channel.insertHeaderAbove(
          'm1',
          row('redemp:r1', system: true),
          maxMessages: max,
        ),
        isTrue,
      );
      expect(
        channel.insertHeaderAbove(
          'm1',
          row('redemp:r1', system: true),
          maxMessages: max,
        ),
        isFalse,
        reason: 'header id already buffered',
      );
      expect(channel.messages.items, hasLength(2));
    });
  });
}
