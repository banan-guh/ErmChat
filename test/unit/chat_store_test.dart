import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/highlight_state.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/chat_store.dart';

ChatStore _store() => ChatStore(
  channels: ['test'],
  channelMessages: {},
  messageKeys: {},
  chatStatus: {},
  channelsWithUnread: {},
  channelsWithUnreadMentions: {},
  unreadMentionsPerChannel: {},
  historyLoaded: {},
  channelsEmotesResolved: {},
  channelUserIds: {},
  lastSentWireText: {},
);

void main() {
  group('ChatStore.upsertSystemMessage', () {
    test('inserts when the id is new, updates in place afterwards', () {
      final store = _store();
      expect(
        store.upsertSystemMessage(
          'test',
          'Joining · position 12 · ~14s',
          messageId: 'join_wait_test',
        ),
        isTrue,
      );
      expect(
        store.upsertSystemMessage(
          'test',
          'Joining · position 12 · ~13s',
          messageId: 'join_wait_test',
        ),
        isTrue,
      );

      final msgs = store.channelMessages['test']!;
      expect(msgs, hasLength(1), reason: 'ticks update, never stack');
      expect(msgs.first.text, 'Joining · position 12 · ~13s');
      expect(msgs.first.messageId, 'join_wait_test');
    });

    test('identical text is a no-op', () {
      final store = _store();
      store.upsertSystemMessage('test', 'same', messageId: 'id1');
      expect(
        store.upsertSystemMessage('test', 'same', messageId: 'id1'),
        isFalse,
      );
    });

    test('removeSystemMessage drops only the matching row', () {
      final store = _store();
      store.addSystemMessage('test', 'Connected');
      store.upsertSystemMessage('test', 'Joining', messageId: 'wait');

      expect(store.removeSystemMessage('test', 'wait'), isTrue);
      final texts = store.channelMessages['test']!.map((m) => m.text).toList();
      expect(texts, ['Connected']);
      expect(store.removeSystemMessage('test', 'wait'), isFalse);
      expect(store.removeSystemMessage('missing-channel', 'wait'), isFalse);
    });
  });

  group('ChatStore.addSystemMessage', () {
    test('inserts at the top of the buffer', () {
      final store = _store();
      expect(store.addSystemMessage('test', 'Connected'), isTrue);
      expect(store.addSystemMessage('test', 'hello'), isTrue);

      final msgs = store.channelMessages['test']!;
      expect(msgs.first.text, 'hello');
      expect(msgs.last.text, 'Connected');
      expect(msgs.first.isSystem, isTrue);
      expect(msgs.first.messageId, startsWith('sys_'));
    });

    test('second Connected becomes Reconnected', () {
      final store = _store();
      store.addSystemMessage('test', 'Connected');
      store.addSystemMessage('test', 'Disconnected');
      store.addSystemMessage('test', 'Connected');

      final texts = store.channelMessages['test']!.map((m) => m.text).toList();
      expect(texts, contains('Reconnected'));
    });

    test('Reconnected folds transient markers and dedups itself', () {
      final store = _store();
      store.addSystemMessage('test', 'Disconnected');
      store.addSystemMessage('test', 'Chat reconnecting...');
      expect(store.addSystemMessage('test', 'Reconnected'), isTrue);

      final texts = store.channelMessages['test']!.map((m) => m.text).toList();
      expect(texts, ['Reconnected']);

      // The second socket reporting recovery must not stack a line.
      expect(store.addSystemMessage('test', 'Reconnected'), isFalse);
      expect(store.channelMessages['test']!, hasLength(1));
    });

    test('reconnecting marker suppressed while Disconnected present', () {
      final store = _store();
      store.addSystemMessage('test', 'Disconnected');
      expect(store.addSystemMessage('test', 'Chat reconnecting...'), isFalse);
      expect(store.channelMessages['test']!.map((m) => m.text), [
        'Disconnected',
      ]);
    });

    test('system message without accent has null accent', () {
      final store = _store();
      store.addSystemMessage('test', 'Announcement');
      final msg = store.channelMessages['test']!.first;
      expect(msg.isSystem, isTrue);
      expect(msg.systemAccent, isNull);
    });

    test('messageId dedup skips a repeat insert and returns false', () {
      final store = _store();
      expect(
        store.addSystemMessage(
          'test',
          'ronni subscribed!',
          messageId: 'n1:label',
        ),
        isTrue,
      );
      expect(store.channelMessages['test']!.first.messageId, 'n1:label');

      expect(
        store.addSystemMessage(
          'test',
          'ronni subscribed!',
          messageId: 'n1:label',
        ),
        isFalse,
        reason: 'the same notice event must not stack a second label',
      );
      expect(store.channelMessages['test'], hasLength(1));
    });

    test('label id never collides with the child message id', () {
      final store = _store();
      expect(
        store.addSystemMessage('test', 'Announcement', messageId: 'n1:label'),
        isTrue,
      );
      expect(
        store.ingestMessage(
          TwitchMessage(
            login: 'mm2pl',
            text: 'hello',
            messageId: 'n1',
            channel: 'test',
          ),
          maxMessages: 10,
        ),
        isTrue,
        reason: 'the child chat message owns the raw id and must coexist',
      );
      expect(store.channelMessages['test'], hasLength(2));
    });

    test('distinct ids with identical text both insert', () {
      final store = _store();
      expect(
        store.addSystemMessage('test', 'Announcement', messageId: 'n1:label'),
        isTrue,
      );
      expect(
        store.addSystemMessage('test', 'Announcement', messageId: 'n2:label'),
        isTrue,
      );
      expect(store.channelMessages['test'], hasLength(2));
    });
  });

  group('ChatStore.ingestMessage', () {
    TwitchMessage live(String id, {String login = 'alice'}) => TwitchMessage(
      login: login,
      text: 'hello',
      messageId: id,
      channel: 'test',
    );
    test('duplicate returns false and skips signals', () {
      final store = _store();
      expect(store.ingestMessage(live('m1'), maxMessages: 10), isTrue);

      final events = <ChatStoreEvent>[];
      final sub = store.events.listen(events.add);
      expect(store.ingestMessage(live('m1'), maxMessages: 10), isFalse);
      sub.cancel();

      expect(store.channelMessages['test'], hasLength(1));
      expect(store.messageCountNotifier('test').value, 1);
      expect(events, isEmpty);
    });

    test('insert bumps messageCountNotifier and emits newContent', () {
      final store = _store();
      final events = <ChatStoreEvent>[];
      final sub = store.events.listen(events.add);

      expect(store.ingestMessage(live('m1'), maxMessages: 10), isTrue);
      sub.cancel();

      expect(store.channelMessages['test']!.first.messageId, 'm1');
      expect(store.messageCountNotifier('test').value, 1);
      expect(events.single.signal, ChatStoreSignal.newContent);
      expect(events.single.channel, 'test');
    });

    test(
      'mention highlight bumps unread bookkeeping and mirrors into mentions',
      () {
        final store = _store();
        final msg = live('m1')
          ..highlight = const HighlightState(types: {HighlightType.username});

        expect(
          store.ingestMessage(
            msg,
            maxMessages: 10,
            selectedChannel: 'other',
            mentionsChannel: '@mentions',
          ),
          isTrue,
        );
        expect(store.unreadMentions, 1);
        expect(store.mentionsBump.value, 1);
        expect(store.channelsWithUnreadMentions, contains('test'));
        expect(store.unreadMentionsPerChannel['test'], 1);
        expect(store.channelMessages['@mentions']!.single.messageId, 'm1');
      },
    );

    test(
      'mention in the selected channel skips counters but still mirrors',
      () {
        final store = _store();
        final msg = live('m1')
          ..highlight = const HighlightState(types: {HighlightType.reply});

        expect(
          store.ingestMessage(
            msg,
            maxMessages: 10,
            selectedChannel: 'test',
            mentionsChannel: '@mentions',
          ),
          isTrue,
        );
        expect(store.unreadMentions, 0);
        expect(store.mentionsBump.value, 0);
        expect(store.unreadMentionsPerChannel, isEmpty);
        expect(store.channelMessages['@mentions'], hasLength(1));
      },
    );
  });

  group('ChatStore.mirrorMentions', () {
    TwitchMessage mention(String id, DateTime ts, {String channel = 'test'}) =>
        TwitchMessage(
          login: 'alice',
          text: 'hi',
          messageId: id,
          channel: channel,
          timestamp: ts,
        );

    test('sorts a mixed batch newest-first across midnight', () {
      final store = _store();
      // History spanning midnight arrives with wall-clock-looking order
      // flips; the buffer must stay ordered by real timestamps.
      final beforeMidnight = mention('m1', DateTime(2026, 8, 22, 23, 59, 59));
      final afterMidnight = mention('m2', DateTime(2026, 8, 23, 0, 0, 1));

      store.mirrorMentions('@mentions', [
        beforeMidnight,
        afterMidnight,
      ], maxMessages: 10);

      expect(store.channelMessages['@mentions']!.map((m) => m.messageId), [
        'm2',
        'm1',
      ]);
    });

    test('caller iteration order never leaks into the buffer', () {
      final store = _store();
      final msgs = [
        for (var i = 0; i < 5; i++)
          mention('m$i', DateTime(2026, 8, 20, 12, 0, i)),
      ];

      // Newest-first input (as channel buffers are stored) must yield the
      // same result as oldest-first input.
      store.mirrorMentions('@mentions', msgs, maxMessages: 10);
      expect(store.channelMessages['@mentions']!.map((m) => m.messageId), [
        'm4',
        'm3',
        'm2',
        'm1',
        'm0',
      ]);

      final other = _store();
      other.mirrorMentions(
        '@mentions',
        msgs.reversed.toList(),
        maxMessages: 10,
      );
      expect(other.channelMessages['@mentions']!.map((m) => m.messageId), [
        'm4',
        'm3',
        'm2',
        'm1',
        'm0',
      ]);
    });

    test('dedupes against the buffer and within the batch', () {
      final store = _store();
      final t = DateTime(2026, 8, 21, 10);
      store.mirrorMentions('@mentions', [mention('m1', t)], maxMessages: 10);
      store.mirrorMentions('@mentions', [
        mention('m2', t.add(const Duration(minutes: 1))),
        mention('m1', t),
      ], maxMessages: 10);

      expect(store.channelMessages['@mentions']!.map((m) => m.messageId), [
        'm2',
        'm1',
      ]);
    });

    test('caps the buffer keeping the newest messages', () {
      final store = _store();
      final msgs = [
        for (var i = 0; i < 6; i++)
          mention('m$i', DateTime(2026, 8, 20, 12, i)),
      ];

      store.mirrorMentions('@mentions', msgs, maxMessages: 4);

      expect(store.channelMessages['@mentions']!.map((m) => m.messageId), [
        'm5',
        'm4',
        'm3',
        'm2',
      ]);
    });
  });
}
