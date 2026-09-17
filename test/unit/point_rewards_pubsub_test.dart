import 'package:ermchat/models/point_rewards.dart';
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
}
