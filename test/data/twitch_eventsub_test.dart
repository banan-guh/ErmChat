import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/services/twitch_eventsub.dart';

Map<String, dynamic> _welcome({String id = 'session-abc', int timeout = 10}) =>
    {
      'metadata': {'message_type': 'session_welcome'},
      'payload': {
        'session': {'id': id, 'keepalive_timeout_seconds': timeout},
      },
    };

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
    test('sets sessionId and emits connected status', () {
      final statuses = <EventSubStatus>[];
      service.onStatus.listen(statuses.add);

      service.handleRawMessage(_welcome(id: 'sess-1', timeout: 20));

      expect(service.sessionId, 'sess-1');
      expect(statuses, contains(EventSubStatus.connected));
    });

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
}
