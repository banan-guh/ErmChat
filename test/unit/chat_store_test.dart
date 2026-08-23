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

    test('accent color survives the insert', () {
      final store = _store();
      store.addSystemMessage('test', 'Announcement');
      final msg = store.channelMessages['test']!.first;
      expect(msg.isSystem, isTrue);
      expect(msg.systemAccent, isNull);
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
}
