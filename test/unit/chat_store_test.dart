import 'package:flutter_test/flutter_test.dart';
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
}
