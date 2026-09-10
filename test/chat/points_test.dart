import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/models/point_rewards.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
