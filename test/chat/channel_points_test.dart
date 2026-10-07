import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/models/point_rewards.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:flutter_test/flutter_test.dart';

TwitchMessage row(String id, {bool system = false}) => TwitchMessage(
  login: system ? '' : 'fan',
  text: system ? 'Fan redeemed Hydrate' : 'hello',
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
  });

  group('redemption header retro-insert', () {
    test('lands above the target; misses on gone targets and duplicates', () {
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
      final channel = chat.channelFor('shroud')!;
      List<String?> ids() =>
          channel.messages.items.map((m) => m.messageId).toList();
      final header = row('redemp:r1', system: true);

      expect(
        channel.insertHeaderAbove('missing', header, maxMessages: max),
        isFalse,
      );
      expect(channel.insertHeaderAbove('m2', header, maxMessages: max), isTrue);
      expect(ids(), ['m2', 'redemp:r1', 'm1']);
      expect(
        channel.insertHeaderAbove('m1', header, maxMessages: max),
        isFalse,
        reason: 'header id already buffered',
      );
      expect(ids(), hasLength(3));
    });
  });
}
