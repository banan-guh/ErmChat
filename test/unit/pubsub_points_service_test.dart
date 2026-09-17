import 'dart:convert';

import 'package:ermchat/services/pubsub_points_service.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
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
}
