import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/services/twitch_eventsub.dart';

Map<String, dynamic> _moderate({
  required String action,
  Map<String, dynamic>? meta,
  String moderatorName = 'moduser',
  String? moderatorUserId,
}) => <String, dynamic>{
  'metadata': <String, dynamic>{
    'message_type': 'notification',
    'subscription_type': 'channel.moderate',
  },
  'payload': <String, dynamic>{
    'subscription': <String, dynamic>{
      'condition': <String, dynamic>{'broadcaster_user_id': 'broadcaster1'},
    },
    'event': <String, dynamic>{
      'action': action,
      'moderator_user_name': moderatorName,
      'moderator_user_id': moderatorUserId,
      ...?meta,
    },
  },
};

void main() {
  late EventSubService service;

  setUp(() {
    service = EventSubService();
    service.setChannelMapping('broadcaster1', 'testchannel');
  });

  tearDown(() {
    service.dispose();
  });

  group('session_welcome', () {
    test('session_welcome with null timeout defaults to 10', () {
      service.handleRawMessage(<String, dynamic>{
        'metadata': <String, dynamic>{'message_type': 'session_welcome'},
        'payload': <String, dynamic>{
          'session': <String, dynamic>{'id': 'sess-2'},
        },
      });

      expect(service.sessionId, 'sess-2');
    });
  });

  group('session_keepalive', () {
    test('does not crash', () {
      expect(
        () => service.handleRawMessage(<String, dynamic>{
          'metadata': <String, dynamic>{'message_type': 'session_keepalive'},
          'payload': <String, dynamic>{},
        }),
        returnsNormally,
      );
    });
  });

  group('notification (channel.moderate)', () {
    test('ban emits ModerationEvent with target and reason', () async {
      final events = <ModerationEvent>[];
      service.onModeration.listen(events.add);

      service.handleRawMessage(
        _moderate(
          action: 'ban',
          meta: {
            'ban': {
              'user_id': 'target1',
              'user_name': 'targetuser',
              'reason': 'spam',
            },
          },
        ),
      );

      expect(events, hasLength(1));
      expect(events[0].channel, 'testchannel');
      expect(events[0].action, 'ban');
      expect(events[0].moderatorName, 'moduser');
      expect(events[0].targetName, 'targetuser');
      expect(events[0].reason, 'spam');
    });

    test('timeout carries duration from expires_at', () async {
      final events = <ModerationEvent>[];
      service.onModeration.listen(events.add);

      final expiresAt = DateTime.now()
          .toUtc()
          .add(const Duration(seconds: 300))
          .toIso8601String();
      service.handleRawMessage(
        _moderate(
          action: 'timeout',
          meta: {
            'timeout': {'user_name': 'targetuser', 'expires_at': expiresAt},
          },
        ),
      );

      expect(events, hasLength(1));
      expect(events[0].action, 'timeout');
      expect(events[0].durationSeconds, closeTo(300, 10));
    });

    test('delete carries message id and body', () async {
      final events = <ModerationEvent>[];
      service.onModeration.listen(events.add);

      service.handleRawMessage(
        _moderate(
          action: 'delete',
          meta: {
            'delete': {
              'user_name': 'targetuser',
              'message_id': 'msg-1',
              'message_body': 'hello',
            },
          },
        ),
      );

      expect(events, hasLength(1));
      expect(events[0].action, 'delete');
      expect(events[0].targetName, 'targetuser');
      expect(events[0].messageId, 'msg-1');
      expect(events[0].messageBody, 'hello');
    });

    test('shared_chat actions map to their base action', () async {
      final events = <ModerationEvent>[];
      service.onModeration.listen(events.add);

      service.handleRawMessage(
        _moderate(
          action: 'shared_chat_ban',
          meta: {
            'shared_chat_ban': {'user_name': 'targetuser'},
          },
        ),
      );

      expect(events, hasLength(1));
      expect(events[0].action, 'ban');
    });

    test('ignores notifications for unknown subscription types', () async {
      final events = <ModerationEvent>[];
      service.onModeration.listen(events.add);

      service.handleRawMessage(<String, dynamic>{
        'metadata': <String, dynamic>{
          'message_type': 'notification',
          'subscription_type': 'channel.chat.message',
        },
        'payload': <String, dynamic>{
          'subscription': <String, dynamic>{
            'condition': <String, dynamic>{
              'broadcaster_user_id': 'broadcaster1',
            },
          },
          'event': <String, dynamic>{'chatter_user_name': 'someone'},
        },
      });

      expect(events, isEmpty);
    });

    test('drops events without a channel mapping', () async {
      final events = <ModerationEvent>[];
      service.onModeration.listen(events.add);

      service.handleRawMessage(<String, dynamic>{
        'metadata': <String, dynamic>{
          'message_type': 'notification',
          'subscription_type': 'channel.moderate',
        },
        'payload': <String, dynamic>{
          'subscription': <String, dynamic>{
            'condition': <String, dynamic>{
              'broadcaster_user_id': 'unknown_broadcaster',
            },
          },
          'event': <String, dynamic>{'action': 'clear'},
        },
      });

      expect(events, isEmpty);
    });

    test('clear emits event without target', () async {
      final events = <ModerationEvent>[];
      service.onModeration.listen(events.add);

      service.handleRawMessage(
        _moderate(action: 'clear', meta: <String, dynamic>{}),
      );

      expect(events, hasLength(1));
      expect(events[0].action, 'clear');
      expect(events[0].targetName, isNull);
    });
  });

  group('session_reconnect and revocation', () {
    test('session_reconnect does not crash', () {
      expect(
        () => service.handleRawMessage(<String, dynamic>{
          'metadata': <String, dynamic>{'message_type': 'session_reconnect'},
          'payload': <String, dynamic>{},
        }),
        returnsNormally,
      );
    });

    test('revocation does not crash', () {
      expect(
        () => service.handleRawMessage(<String, dynamic>{
          'metadata': <String, dynamic>{'message_type': 'revocation'},
          'payload': <String, dynamic>{},
        }),
        returnsNormally,
      );
    });
  });

  Map<String, dynamic> widget(
    String type,
    Map<String, dynamic> event,
  ) => <String, dynamic>{
    'metadata': <String, dynamic>{
      'message_type': 'notification',
      'subscription_type': type,
    },
    'payload': <String, dynamic>{
      'subscription': <String, dynamic>{
        'condition': <String, dynamic>{'broadcaster_user_id': 'broadcaster1'},
      },
      'event': event,
    },
  };

  group('notification (channel.hype_train)', () {
    test(
      'begin emits HypeTrainEvent with level, goal and contributors',
      () async {
        final events = <HypeTrainEvent>[];
        service.onHypeTrain.listen(events.add);

        service.handleRawMessage(
          widget('channel.hype_train.begin', <String, dynamic>{
            'level': 2,
            'progress': 30,
            'total': 100,
            'expires_at': '2030-01-01T00:00:00Z',
            'top_contributions': <Map<String, dynamic>>[
              {'user_name': 'bitsuser', 'type': 'BITS', 'total': 2000},
              {'user_name': 'subuser', 'type': 'SUBS', 'total': 5},
            ],
          }),
        );

        expect(events, hasLength(1));
        final e = events[0];
        expect(e.channel, 'testchannel');
        expect(e.kind, 'begin');
        expect(e.level, 2);
        expect(e.progress, 30);
        expect(e.total, 100);
        expect(e.expiresAt, isNotNull);
        expect(e.topContributions, hasLength(2));
        expect(e.topContributions[0].userName, 'bitsuser');
        expect(e.topContributions[0].type, 'BITS');
      },
    );

    test('end emits event with no channel when mapping missing', () async {
      final events = <HypeTrainEvent>[];
      service.onHypeTrain.listen(events.add);

      service.handleRawMessage(
        widget('channel.hype_train.end', <String, dynamic>{
          'level': 3,
          'progress': 100,
          'total': 100,
        }),
      );

      // Mapping is present for broadcaster1, so the channel resolves.
      expect(events, hasLength(1));
      expect(events[0].kind, 'end');
    });
  });

  group('notification (channel.poll)', () {
    test('progress emits PollEvent with choices and votes', () async {
      final events = <PollEvent>[];
      service.onPoll.listen(events.add);

      service.handleRawMessage(
        widget('channel.poll.progress', <String, dynamic>{
          'title': 'Best game?',
          'status': 'ACTIVE',
          'choices': <Map<String, dynamic>>[
            {'id': '1', 'title': 'Minecraft', 'votes': 10},
            {'id': '2', 'title': 'Terraria', 'votes': 20},
          ],
        }),
      );

      expect(events, hasLength(1));
      final e = events[0];
      expect(e.channel, 'testchannel');
      expect(e.kind, 'progress');
      expect(e.title, 'Best game?');
      expect(e.choices, hasLength(2));
      expect(e.choices[0].title, 'Minecraft');
      expect(e.choices[0].votes, 10);
      expect(e.choices[1].votes, 20);
    });
  });

  group('notification (channel.prediction)', () {
    test('lock emits PredictionEvent with outcomes', () async {
      final events = <PredictionEvent>[];
      service.onPrediction.listen(events.add);

      service.handleRawMessage(
        widget('channel.prediction.lock', <String, dynamic>{
          'title': 'Will we win?',
          'status': 'LOCKED',
          'outcomes': <Map<String, dynamic>>[
            {
              'id': '1',
              'title': 'Yes',
              'users': 15,
              'channel_points': 300,
              'color': 'BLUE',
            },
            {
              'id': '2',
              'title': 'No',
              'users': 5,
              'channel_points': 100,
              'color': 'PINK',
            },
          ],
        }),
      );

      expect(events, hasLength(1));
      final e = events[0];
      expect(e.channel, 'testchannel');
      expect(e.kind, 'lock');
      expect(e.title, 'Will we win?');
      expect(e.outcomes, hasLength(2));
      expect(e.outcomes[0].title, 'Yes');
      expect(e.outcomes[0].users, 15);
      expect(e.outcomes[0].channelPoints, 300);
    });
  });
}
