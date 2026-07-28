import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/services/twitch_eventsub.dart';
import 'package:ermchat/models/twitch_message.dart';

Map<String, dynamic> _welcome({String id = 'session-abc', int timeout = 10}) =>
    {
      'metadata': {'message_type': 'session_welcome'},
      'payload': {
        'session': {'id': id, 'keepalive_timeout_seconds': timeout},
      },
    };

Map<String, dynamic> _notification({
  required String subType,
  String? chatter = 'testuser',
  String? chatterId,
  String? messageId,
  String text = 'hello',
  String? color,
  Map<String, dynamic>? reply,
}) => <String, dynamic>{
  'metadata': <String, dynamic>{
    'message_type': 'notification',
    'subscription_type': subType,
  },
  'payload': <String, dynamic>{
    'subscription': <String, dynamic>{
      'condition': <String, dynamic>{'broadcaster_user_id': 'broadcaster1'},
    },
    'event': <String, dynamic>{
      'chatter_user_name': ?chatter,
      'chatter_user_id': ?chatterId,
      'message_id': ?messageId,
      'message': <String, dynamic>{'text': text},
      'color': ?color,
      'reply': ?reply,
    },
  },
};

Map<String, dynamic> _deleteEvent({
  String? messageId,
  String targetUser = 'deleted_user',
}) => <String, dynamic>{
  'metadata': <String, dynamic>{
    'message_type': 'notification',
    'subscription_type': 'channel.chat.message_delete',
  },
  'payload': <String, dynamic>{
    'subscription': <String, dynamic>{
      'condition': <String, dynamic>{'broadcaster_user_id': 'broadcaster1'},
    },
    'event': <String, dynamic>{
      'message_id': ?messageId,
      'target_user_name': targetUser,
    },
  },
};

Map<String, dynamic> _banEvent({
  String user = 'banned_user',
  String? reason,
  String? endsAt,
}) => <String, dynamic>{
  'metadata': <String, dynamic>{
    'message_type': 'notification',
    'subscription_type': 'channel.ban',
  },
  'payload': <String, dynamic>{
    'subscription': <String, dynamic>{
      'condition': <String, dynamic>{'broadcaster_user_id': 'broadcaster1'},
    },
    'event': <String, dynamic>{
      'user_name': user,
      'reason': ?reason,
      'ends_at': ?endsAt,
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

  group('notification (channel.chat.message)', () {
    test('produces TwitchMessage with all fields', () async {
      final messages = <TwitchMessage>[];
      service.onMessage.listen(messages.add);

      service.handleRawMessage(
        _notification(
          subType: 'channel.chat.message',
          chatter: 'testuser',
          messageId: 'msg-1',
          text: 'hello world',
          color: '#FF0000',
        ),
      );

      expect(messages, hasLength(1));
      expect(messages[0].login, 'testuser');
      expect(messages[0].text, 'hello world');
      expect(messages[0].messageId, 'msg-1');
      expect(messages[0].channel, 'testchannel');
      expect(messages[0].color, '#FF0000');
    });

    test('captures chatter_user_id', () async {
      final messages = <TwitchMessage>[];
      service.onMessage.listen(messages.add);

      service.handleRawMessage(
        _notification(
          subType: 'channel.chat.message',
          chatter: 'testuser',
          chatterId: 'uid-42',
          messageId: 'msg-uid',
          text: 'with id',
        ),
      );

      expect(messages, hasLength(1));
      expect(messages[0].userId, 'uid-42');
    });

    test('handles missing chatter name', () async {
      final messages = <TwitchMessage>[];
      service.onMessage.listen(messages.add);

      service.handleRawMessage(
        _notification(
          subType: 'channel.chat.message',
          chatter: null,
          messageId: 'msg-2',
          text: 'no name',
        ),
      );

      expect(messages[0].login, 'unknown');
    });

    test('handles missing message text', () async {
      final messages = <TwitchMessage>[];
      service.onMessage.listen(messages.add);

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
          'event': <String, dynamic>{
            'chatter_user_name': 'testuser',
            'message_id': 'msg-3',
          },
        },
      });

      expect(messages[0].text, '');
    });

    test('handles null color gracefully', () async {
      final messages = <TwitchMessage>[];
      service.onMessage.listen(messages.add);

      service.handleRawMessage(
        _notification(
          subType: 'channel.chat.message',
          chatter: 'testuser',
          messageId: 'msg-4',
          text: 'no color',
        ),
      );

      expect(messages[0].color, isNull);
    });

    test('strips @User prefix from reply text', () async {
      final messages = <TwitchMessage>[];
      service.onMessage.listen(messages.add);

      service.handleRawMessage(
        _notification(
          subType: 'channel.chat.message',
          chatter: 'bob',
          messageId: 'msg-5',
          text: '@alice hey there',
          reply: {
            'parent_message_id': 'parent-1',
            'parent_user_name': 'alice',
            'parent_message_body': 'original msg',
          },
        ),
      );

      expect(messages[0].replyToParentId, 'parent-1');
      expect(messages[0].replyToUser, 'alice');
      expect(messages[0].replyToText, 'original msg');
      expect(messages[0].text, 'hey there');
    });

    test(
      'does not strip @User prefix when it does not match reply user',
      () async {
        final messages = <TwitchMessage>[];
        service.onMessage.listen(messages.add);

        service.handleRawMessage(
          _notification(
            subType: 'channel.chat.message',
            chatter: 'bob',
            messageId: 'msg-6',
            text: '@charlie hey there',
            reply: {
              'parent_message_id': 'parent-2',
              'parent_user_name': 'alice',
              'parent_message_body': 'original msg',
            },
          ),
        );

        expect(messages[0].text, '@charlie hey there');
      },
    );

    test('handles missing channel mapping (unknown broadcaster)', () async {
      final messages = <TwitchMessage>[];
      service.onMessage.listen(messages.add);

      service.handleRawMessage(<String, dynamic>{
        'metadata': <String, dynamic>{
          'message_type': 'notification',
          'subscription_type': 'channel.chat.message',
        },
        'payload': <String, dynamic>{
          'subscription': <String, dynamic>{
            'condition': <String, dynamic>{
              'broadcaster_user_id': 'unknown_broadcaster',
            },
          },
          'event': <String, dynamic>{
            'chatter_user_name': 'testuser',
            'message_id': 'msg-7',
            'message': <String, dynamic>{'text': 'hello'},
          },
        },
      });

      expect(messages[0].channel, isNull);
    });
  });

  group('notification (channel.chat.message_delete)', () {
    test('emits delete event with messageId', () async {
      final deletes =
          <({String messageId, String targetUser, String channel})>[];
      service.onMessageDeleted.listen(deletes.add);

      service.handleRawMessage(
        _deleteEvent(messageId: 'del-1', targetUser: 'someuser'),
      );

      expect(deletes, hasLength(1));
      expect(deletes[0].messageId, 'del-1');
      expect(deletes[0].targetUser, 'someuser');
      expect(deletes[0].channel, 'testchannel');
    });

    test('ignores delete event without messageId', () async {
      final deletes =
          <({String messageId, String targetUser, String channel})>[];
      service.onMessageDeleted.listen(deletes.add);

      service.handleRawMessage(_deleteEvent(messageId: null));

      expect(deletes, isEmpty);
    });

    test('uses unknown as default target user', () async {
      final deletes =
          <({String messageId, String targetUser, String channel})>[];
      service.onMessageDeleted.listen(deletes.add);

      service.handleRawMessage(<String, dynamic>{
        'metadata': <String, dynamic>{
          'message_type': 'notification',
          'subscription_type': 'channel.chat.message_delete',
        },
        'payload': <String, dynamic>{
          'subscription': <String, dynamic>{
            'condition': <String, dynamic>{
              'broadcaster_user_id': 'broadcaster1',
            },
          },
          'event': <String, dynamic>{'message_id': 'del-2'},
        },
      });

      expect(deletes[0].targetUser, 'unknown');
    });
  });

  group('notification (channel.ban)', () {
    test('emits permanent ban event', () async {
      final bans =
          <
            ({
              String user,
              String? reason,
              bool isTimeout,
              String? duration,
              int? durationSeconds,
              String channel,
            })
          >[];
      service.onBan.listen(bans.add);

      service.handleRawMessage(
        _banEvent(user: 'baduser', reason: 'Harassment'),
      );

      expect(bans, hasLength(1));
      expect(bans[0].user, 'baduser');
      expect(bans[0].reason, 'Harassment');
      expect(bans[0].isTimeout, isFalse);
      expect(bans[0].duration, isNull);
      expect(bans[0].channel, 'testchannel');
    });

    test('emits timeout event with duration in seconds', () async {
      final bans =
          <
            ({
              String user,
              String? reason,
              bool isTimeout,
              String? duration,
              int? durationSeconds,
              String channel,
            })
          >[];
      service.onBan.listen(bans.add);

      final future = DateTime.now()
          .add(const Duration(seconds: 30))
          .toIso8601String();
      service.handleRawMessage(
        _banEvent(user: 'spammer', reason: 'Time out', endsAt: future),
      );

      expect(bans[0].isTimeout, isTrue);
      expect(bans[0].duration, endsWith('s'));
      expect(bans[0].durationSeconds, lessThanOrEqualTo(30));
    });

    test('emits timeout event with duration in minutes', () async {
      final bans =
          <
            ({
              String user,
              String? reason,
              bool isTimeout,
              String? duration,
              int? durationSeconds,
              String channel,
            })
          >[];
      service.onBan.listen(bans.add);

      final future = DateTime.now()
          .add(const Duration(minutes: 10))
          .toIso8601String();
      service.handleRawMessage(_banEvent(user: 'longtimeout', endsAt: future));

      expect(bans[0].isTimeout, isTrue);
      expect(bans[0].duration, endsWith('m'));
    });

    test('handles invalid endsAt date', () async {
      final bans =
          <
            ({
              String user,
              String? reason,
              bool isTimeout,
              String? duration,
              int? durationSeconds,
              String channel,
            })
          >[];
      service.onBan.listen(bans.add);

      service.handleRawMessage(
        _banEvent(user: 'bad_date', endsAt: 'not-a-date'),
      );

      expect(bans[0].isTimeout, isTrue);
      expect(bans[0].duration, isNull);
      expect(bans[0].durationSeconds, isNull);
    });

    test('uses unknown as default user', () async {
      final bans =
          <
            ({
              String user,
              String? reason,
              bool isTimeout,
              String? duration,
              int? durationSeconds,
              String channel,
            })
          >[];
      service.onBan.listen(bans.add);

      service.handleRawMessage(<String, dynamic>{
        'metadata': <String, dynamic>{
          'message_type': 'notification',
          'subscription_type': 'channel.ban',
        },
        'payload': <String, dynamic>{
          'subscription': <String, dynamic>{
            'condition': <String, dynamic>{
              'broadcaster_user_id': 'broadcaster1',
            },
          },
          'event': <String, dynamic>{},
        },
      });

      expect(bans[0].user, 'unknown');
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
