import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/services/seven_tv_event_client.dart';

Map<String, dynamic> _hello({int heartbeatInterval = 30000}) => {
      'op': 1,
      'd': {'heartbeat_interval': heartbeatInterval},
    };

Map<String, dynamic> _emoteSetUpdate({
  required String emoteSetId,
  List<Map<String, dynamic>>? pushed,
  List<Map<String, dynamic>>? pulled,
  List<Map<String, dynamic>>? updated,
  String? actor,
}) => {
  'op': 0,
  'd': {
    'type': 'emote_set.update',
    'id': emoteSetId,
    // ignore: use_null_aware_elements
    'body': <String, dynamic>{
      // ignore: use_null_aware_elements
      if (pushed != null) 'pushed': pushed,
      // ignore: use_null_aware_elements
      if (pulled != null) 'pulled': pulled,
      // ignore: use_null_aware_elements
      if (updated != null) 'updated': updated,
      if (actor != null)
        'actor': {'display_name': actor},
    },
  },
};

Map<String, dynamic> _userUpdate({
  required String userId,
  required String newEmoteSetId,
  required String oldEmoteSetId,
  int connectionIndex = 0,
  String? actor,
}) => {
  'op': 0,
  'd': {
    'type': 'user.update',
    'id': userId,
    'body': {
      'connection_index': connectionIndex,
      'change_map': {
        'fields': [
          {'key': 'emote_set_id', 'value': newEmoteSetId, 'old_value': oldEmoteSetId},
        ],
      },
      if (actor != null)
        'actor': {'display_name': actor},
    },
  },
};

void main() {
  late SevenTvEventClient client;
  late List<SevenTvEmoteUpdateEvent> emoteEvents;
  late List<SevenTvUserUpdate> userEvents;
  late List<SevenTvEventStatus> statusEvents;

  setUp(() {
    client = SevenTvEventClient();
    emoteEvents = [];
    userEvents = [];
    statusEvents = [];
    client.onEmoteSetUpdate.listen((e) => emoteEvents.add(e));
    client.onUserUpdate.listen((e) => userEvents.add(e));
    client.onStatus.listen((e) => statusEvents.add(e));
  });

  tearDown(() {
    client.dispose();
  });

  group('subscription queueing', () {
    test('subscribeEmoteSet does not trigger stream events before Hello', () {
      client.subscribeEmoteSet('set1');
      expect(emoteEvents, isEmpty);
      expect(userEvents, isEmpty);
    });

    test('subscribeUser does not trigger stream events before Hello', () {
      client.subscribeUser('user1');
      expect(emoteEvents, isEmpty);
      expect(userEvents, isEmpty);
    });

    test('Hello emits connected status', () {
      client.handleRawMessage(_hello());
      expect(statusEvents, hasLength(1));
      expect(statusEvents.first, SevenTvEventStatus.connected);
    });
  });

  group('dispatch events', () {
    setUp(() {
      client.handleRawMessage(_hello());
      emoteEvents.clear();
      userEvents.clear();
      statusEvents.clear();
    });

    test('emote_set.update parses added emote', () {
      client.handleRawMessage(
        _emoteSetUpdate(
          emoteSetId: 'set123',
          pushed: [
            {'value': {'id': 'abc', 'name': 'KEKW'}},
          ],
          actor: 'streamer',
        ),
      );

      expect(emoteEvents, hasLength(1));
      expect(emoteEvents[0].emoteSetId, 'set123');
      expect(emoteEvents[0].added, hasLength(1));
      expect(emoteEvents[0].added[0].id, 'abc');
      expect(emoteEvents[0].added[0].name, 'KEKW');
      expect(emoteEvents[0].added[0].raw['id'], 'abc');
      expect(emoteEvents[0].actor, 'streamer');
      expect(emoteEvents[0].removed, isEmpty);
      expect(emoteEvents[0].renamed, isEmpty);
    });

    test('emote_set.update parses removed emote', () {
      client.handleRawMessage(
        _emoteSetUpdate(
          emoteSetId: 'set123',
          pulled: [
            {'old_value': {'id': 'xyz', 'name': 'PogU'}},
          ],
        ),
      );

      expect(emoteEvents, hasLength(1));
      expect(emoteEvents[0].added, isEmpty);
      expect(emoteEvents[0].removed, hasLength(1));
      expect(emoteEvents[0].removed[0].id, 'xyz');
      expect(emoteEvents[0].removed[0].name, 'PogU');
      expect(emoteEvents[0].renamed, isEmpty);
    });

    test('emote_set.update parses renamed emote', () {
      client.handleRawMessage(
        _emoteSetUpdate(
          emoteSetId: 'set123',
          updated: [
            {
              'value': {'id': 'def', 'name': 'NewName'},
              'old_value': {'id': 'def', 'name': 'OldName'},
            },
          ],
        ),
      );

      expect(emoteEvents, hasLength(1));
      expect(emoteEvents[0].added, isEmpty);
      expect(emoteEvents[0].removed, isEmpty);
      expect(emoteEvents[0].renamed, hasLength(1));
      expect(emoteEvents[0].renamed[0].id, 'def');
      expect(emoteEvents[0].renamed[0].newName, 'NewName');
      expect(emoteEvents[0].renamed[0].oldName, 'OldName');
    });

    test('emote_set.update handles multiple changes at once', () {
      client.handleRawMessage(
        _emoteSetUpdate(
          emoteSetId: 'set123',
          pushed: [
            {'value': {'id': 'a1', 'name': 'Emote1'}},
            {'value': {'id': 'a2', 'name': 'Emote2'}},
          ],
          pulled: [
            {'old_value': {'id': 'r1', 'name': 'Removed1'}},
          ],
          updated: [
            {
              'value': {'id': 'u1', 'name': 'RenamedNew'},
              'old_value': {'id': 'u1', 'name': 'RenamedOld'},
            },
          ],
          actor: 'mod',
        ),
      );

      expect(emoteEvents, hasLength(1));
      final event = emoteEvents[0];
      expect(event.emoteSetId, 'set123');
      expect(event.added, hasLength(2));
      expect(event.removed, hasLength(1));
      expect(event.renamed, hasLength(1));
      expect(event.actor, 'mod');
    });

    test('emote_set.update handles empty body gracefully', () {
      client.handleRawMessage({
        'op': 0,
        'd': {'type': 'emote_set.update', 'id': 'set123'},
      });

      expect(emoteEvents, hasLength(1));
      expect(emoteEvents[0].added, isEmpty);
      expect(emoteEvents[0].removed, isEmpty);
      expect(emoteEvents[0].renamed, isEmpty);
      expect(emoteEvents[0].actor, isNull);
    });

    test('user.update parses emote set switch', () {
      client.handleRawMessage(
        _userUpdate(
          userId: 'user123',
          newEmoteSetId: 'newset',
          oldEmoteSetId: 'oldset',
          connectionIndex: 0,
          actor: 'streamer',
        ),
      );

      expect(userEvents, hasLength(1));
      expect(userEvents[0].userId, 'user123');
      expect(userEvents[0].newEmoteSetId, 'newset');
      expect(userEvents[0].oldEmoteSetId, 'oldset');
      expect(userEvents[0].connectionIndex, 0);
      expect(userEvents[0].actor, 'streamer');
    });

    test('user.update handles missing actor', () {
      client.handleRawMessage(
        _userUpdate(
          userId: 'user456',
          newEmoteSetId: 'setA',
          oldEmoteSetId: 'setB',
        ),
      );

      expect(userEvents, hasLength(1));
      expect(userEvents[0].actor, isNull);
    });

    test('user.update ignores non-emote_set_id fields', () {
      client.handleRawMessage({
        'op': 0,
        'd': {
          'type': 'user.update',
          'id': 'user789',
          'body': {
            'connection_index': 0,
            'change_map': {
              'fields': [
                {'key': 'other_field', 'value': 'foo', 'old_value': 'bar'},
              ],
            },
          },
        },
      });

      expect(userEvents, isEmpty);
    });

    test('user.update ignores empty new emote set id', () {
      client.handleRawMessage({
        'op': 0,
        'd': {
          'type': 'user.update',
          'id': 'userx',
          'body': {
            'change_map': {
              'fields': [
                {'key': 'emote_set_id', 'value': '', 'old_value': 'old'},
              ],
            },
          },
        },
      });

      expect(userEvents, isEmpty);
    });
  });

  group('status events', () {
    test('Hello sets connected status', () {
      client.handleRawMessage(_hello());
      expect(statusEvents, hasLength(1));
      expect(statusEvents.first, SevenTvEventStatus.connected);
    });

    test('emitDisconnected sets disconnected status', () {
      client.emitDisconnected();
      expect(statusEvents, hasLength(1));
      expect(statusEvents.first, SevenTvEventStatus.disconnected);
    });

    test('handleRawMessage ignores unknown op codes gracefully', () {
      client.handleRawMessage({'op': 99, 'd': {}});
      expect(emoteEvents, isEmpty);
      expect(userEvents, isEmpty);
      expect(statusEvents, isEmpty);
    });
  });

  group('unsubscribe', () {
    setUp(() {
      client.handleRawMessage(_hello());
    });

    test('unsubscribeEmoteSet does not affect event streams', () {
      client.subscribeEmoteSet('setX');
      client.unsubscribeEmoteSet('setX');
      expect(emoteEvents, isEmpty);
    });

    test('unsubscribeUser does not affect event streams', () {
      client.subscribeUser('userX');
      client.unsubscribeUser('userX');
      expect(userEvents, isEmpty);
    });
  });

  group('heartbeat', () {
    test('op 2 heartbeat does not emit any events', () {
      client.handleRawMessage(_hello());
      statusEvents.clear();

      client.handleRawMessage({'op': 2, 'd': {'count': 1}});

      expect(emoteEvents, isEmpty);
      expect(userEvents, isEmpty);
      expect(statusEvents, isEmpty);
    });
  });

  group('op 4 reconnect request', () {
    test('op 4 message is handled gracefully', () {
      client.handleRawMessage({'op': 4, 'd': {}});
      expect(emoteEvents, isEmpty);
      expect(userEvents, isEmpty);
    });
  });

  group('op 5 and op 7 ignored', () {
    setUp(() {
      client.handleRawMessage(_hello());
      emoteEvents.clear();
      userEvents.clear();
      statusEvents.clear();
    });

    test('ack message (op 5) is ignored', () {
      client.handleRawMessage({'op': 5, 'd': {}});
      expect(emoteEvents, isEmpty);
      expect(userEvents, isEmpty);
      expect(statusEvents, isEmpty);
    });

    test('end of stream message (op 7) is ignored', () {
      client.handleRawMessage({'op': 7, 'd': {}});
      expect(emoteEvents, isEmpty);
      expect(userEvents, isEmpty);
      expect(statusEvents, isEmpty);
    });
  });

  group('dispose', () {
    test('onEmoteSetUpdate stream completes after dispose', () async {
      final events = <SevenTvEmoteUpdateEvent>[];
      final sub = client.onEmoteSetUpdate.listen(events.add);

      client.handleRawMessage(_hello());
      client.handleRawMessage(
        _emoteSetUpdate(
          emoteSetId: 's1',
          pushed: [
            {'value': {'id': 'e1', 'name': 'Test'}},
          ],
        ),
      );

      expect(events, hasLength(1));

      client.dispose();

      expect(
        () => client.handleRawMessage(_emoteSetUpdate(emoteSetId: 's2')),
        returnsNormally,
      );

      await sub.cancel();
    });
  });
}
