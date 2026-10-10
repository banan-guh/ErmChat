import 'dart:async';
import 'dart:convert';

import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/eventsub/decode/events.dart';
import 'package:ermchat/models/point_rewards.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/pubsub_points_consumer.dart';
import 'package:ermchat/services/pubsub_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../helpers/fake_web_socket.dart';

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
  String login = 'fan',
  bool requiresInput = false,
  bool automatic = false,
}) => PointRedemption(
  id: id,
  userLogin: login,
  userDisplayName: 'Fan',
  rewardId: rewardId,
  rewardTitle: 'Hydrate',
  cost: 500,
  userInput: '',
  status: 'UNFULFILLED',
  redeemedAt: '2026-09-17T00:00:00.000Z',
  requiresUserInput: requiresInput,
  imageUrl: 'https://cdn/x/4.png',
  isAutomatic: automatic,
);

void main() {
  group('PointRedemption.fromPubSub', () {
    test('parses user, reward, default and custom images', () {
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

      final custom = PointRedemption.fromPubSub(
        redemptionJson(
          image: {
            'url_1x': 'https://cdn/custom/1.png',
            'url_4x': 'https://cdn/custom/4.png',
          },
        ),
        '',
      );
      expect(custom.imageUrl, 'https://cdn/custom/4.png');
    });

    test('automatic rewards key by msg-id and may cost bits', () {
      final gigantify = PointRedemption.fromPubSub({
        'id': 'r2',
        'user': {'login': 'fan'},
        'reward': {
          'id': 'some-uuid',
          'title': '',
          'cost': 0,
          'bits_cost': 25,
          'reward_type': 'SEND_GIGANTIFIED_EMOTE',
        },
      }, '');
      expect(gigantify.isAutomatic, isTrue);
      expect(gigantify.rewardId, 'gigantified-emote-message');
      expect(gigantify.rewardTitle, 'Gigantify an Emote');
      expect(gigantify.cost, 25);
      expect(gigantify.costInBits, isTrue);
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

  group('PubSubService frames', () {
    test('routes reward-redeemed to the mapped channel', () async {
      final service = PubSubService();
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

    test('widget topics decode to banner events', () {
      final service = PubSubService();
      addTearDown(service.dispose);
      service.seedTopic('lirik', '23161357');
      final hype = <HypeTrainEvent>[];
      final predictions = <PredictionEvent>[];
      final pins = <PinnedMessageEvent>[];
      final subs = [
        service.onHypeTrain.listen(hype.add),
        service.onPrediction.listen(predictions.add),
        service.onPinned.listen(pins.add),
      ];
      addTearDown(() {
        for (final s in subs) {
          s.cancel();
        }
      });

      // Trimmed from live anonymous frames (2026-10-05).
      service.feedText(
        messageFrame('hype-train-events-v1.23161357', {
          'type': 'hype-train-progression',
          'data': {
            'progress': {
              'level': {'value': 18, 'goal': 192200},
              'value': 20051,
              'goal': 28600,
              'total': 183651,
              'remaining_seconds': 181,
            },
            'expires_at': '2026-10-05T22:16:02.981310906Z',
          },
        }),
      );
      service.feedText(
        messageFrame('predictions-channel-v1.23161357', {
          'type': 'event-updated',
          'data': {
            'event': {
              'status': 'LOCKED',
              'title': r'Wardogs: Banked $ @ end of stream',
              'outcomes': [
                {'title': r'0 - $200k', 'total_points': 500, 'total_users': 1},
              ],
            },
          },
        }),
      );
      service.feedText(
        messageFrame('pinned-chat-updates-v1.23161357', {
          'type': 'pin-message',
          'data': {
            'id': 'pin1',
            'pinned_by': {'login': 'moddy', 'display_name': 'Moddy'},
            'message': {
              'id': '42a6d485-ceeb-4fb6-b592-fdb6cbb4db2d',
              'sender': {
                'id': '974273622',
                'login': 'moddy',
                'display_name': 'Moddy',
              },
              'content': {
                'text': 'GET THE ADDON Kappa',
                'fragments': [
                  {'text': 'GET THE ADDON '},
                  {
                    'text': 'Kappa',
                    'emoticon': {'emoticonID': '25', 'emoticonSetID': '0'},
                  },
                ],
              },
              'ends_at': 1791239991,
            },
          },
        }),
      );
      // #14: a Hype Chat rides the same topic and replaced the mod pin.
      service.feedText(
        messageFrame('pinned-chat-updates-v1.23161357', {
          'type': 'pin-message',
          'data': {
            'id': 'paid1',
            'message': {
              'id': 'hype-msg',
              'sender': {'id': '1', 'display_name': 'Rando'},
              'content': {'text': 'paid message'},
              'type': 'PAID',
            },
          },
        }),
      );
      service.feedText(
        messageFrame('pinned-chat-updates-v1.23161357', {
          'type': 'unpin-message',
          'data': {'id': 'pin1'},
        }),
      );

      final train = hype.single;
      expect(train.channel, 'lirik');
      expect(train.kind, HypeTrainKind.progress);
      expect(train.level, 18);
      expect((train.progress, train.goal), (20051, 28600));
      expect(train.expiresAt, isNotNull);

      final prediction = predictions.single;
      expect(prediction.kind, PredictionKind.lock);
      expect(prediction.outcomes.single.users, 1);
      expect(prediction.outcomes.single.channelPoints, 500);

      expect(pins.first.senderName, 'Moddy');
      expect(pins.first.text, 'GET THE ADDON Kappa');
      expect(pins.first.senderId, '974273622');
      expect(pins.first.messageId, '42a6d485-ceeb-4fb6-b592-fdb6cbb4db2d');
      expect(
        [
          for (final e in pins.first.emotes)
            (e.emoteId, e.startIndex, e.endIndex),
        ],
        [('25', 14, 19)],
        reason: 'fragment emotes map to text ranges',
      );
      expect(pins.first.endsAt?.millisecondsSinceEpoch, 1791239991000);
      expect(pins, hasLength(2), reason: 'a PAID pin is not the mod pin');
      expect(pins.last.removed, isTrue);
      expect(pins.last.id, 'pin1');
    });

    test('ignores unknown topics, other types, and malformed frames', () {
      final service = PubSubService();
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

    test('reconnect resubscribes in frames Twitch accepts', () async {
      // Twitch silently drops the socket on a LISTEN frame over about 1 KB,
      // which killed every widget topic after the first reconnect.
      final socket = FakeWebSocketChannel();
      final service = _FakeSocketPubSub(socket);
      addTearDown(service.dispose);
      for (var i = 0; i < 12; i++) {
        service.seedTopic('channel$i', '${1468479097 + i}');
      }
      await service.connect();
      expect(socket.sent, hasLength(12));
      for (final frame in socket.sent) {
        expect(utf8.encode(frame).length, lessThan(1000), reason: frame);
      }
    });

    test('listen is idempotent and unlisten drops the mapping', () {
      final service = PubSubService();
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
        isHiddenUser: (login) => login == 'troll',
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
      expect(items.single.text, 'Fan redeemed Hydrate');
      expect(items.single.messageId, 'redemp:r1');
      expect(items.single.redemptionImageUrl, 'https://cdn/x/4.png');
      expect(items.single.redemptionPoints, 500);

      // Same redemption id dedups instead of stacking.
      source.add(
        PubSubPointRedemption(channel: 'shroud', redemption: redemption()),
      );
      expect(chat.channelFor('shroud')!.messages.items, hasLength(1));

      for (final (r, why) in [
        (redemption(id: 'r2', login: 'troll'), 'blocked or ignored user'),
        (redemption(id: 'r3', automatic: true), 'automatic reward'),
      ]) {
        source.add(PubSubPointRedemption(channel: 'shroud', redemption: r));
        expect(
          chat.channelFor('shroud')!.messages.items,
          hasLength(1),
          reason: '$why posted a header',
        );
      }
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
      expect(items[1].text, 'Redeemed Hydrate');
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
  });
}

class _FakeSocketPubSub extends PubSubService {
  _FakeSocketPubSub(this.socket);

  final FakeWebSocketChannel socket;

  @override
  WebSocketChannel openChannel() => socket;
}
