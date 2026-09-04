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
    test(
      'inserts when the id is new, updates in place afterwards and treats identical text as a no-op',
      () {
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

        expect(
          store.upsertSystemMessage('test', 'same', messageId: 'id1'),
          isTrue,
        );
        expect(
          store.upsertSystemMessage('test', 'same', messageId: 'id1'),
          isFalse,
          reason: 'identical text is a no-op',
        );
      },
    );

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

    test(
      'Reconnected folds transient markers, dedups itself and suppresses the reconnecting marker while Disconnected is present',
      () {
        final store = _store();
        store.addSystemMessage('test', 'Disconnected');
        store.addSystemMessage('test', 'Chat reconnecting...');
        expect(store.addSystemMessage('test', 'Reconnected'), isTrue);

        final texts = store.channelMessages['test']!
            .map((m) => m.text)
            .toList();
        expect(texts, ['Reconnected']);

        // The second socket reporting recovery must not stack a line.
        expect(store.addSystemMessage('test', 'Reconnected'), isFalse);
        expect(store.channelMessages['test']!, hasLength(1));

        final suppressed = _store();
        suppressed.addSystemMessage('test', 'Disconnected');
        expect(
          suppressed.addSystemMessage('test', 'Chat reconnecting...'),
          isFalse,
        );
        expect(suppressed.channelMessages['test']!.map((m) => m.text), [
          'Disconnected',
        ]);
      },
    );

    test(
      'messageId dedup skips a repeat insert while distinct ids with identical text both insert',
      () {
        final table = [
          ('repeat id is skipped', 'n1:label', 'n1:label', false, 1),
          ('distinct id inserts', 'n1:label', 'n2:label', true, 2),
        ];
        for (final (label, firstId, secondId, secondResult, count) in table) {
          final store = _store();
          expect(
            store.addSystemMessage(
              'test',
              'ronni subscribed!',
              messageId: firstId,
            ),
            isTrue,
            reason: label,
          );
          expect(
            store.addSystemMessage(
              'test',
              'ronni subscribed!',
              messageId: secondId,
            ),
            secondResult ? isTrue : isFalse,
            reason: label,
          );
          expect(
            store.channelMessages['test'],
            hasLength(count),
            reason: label,
          );
        }
      },
    );

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
  });

  group('ChatStore.ingestMessage', () {
    TwitchMessage live(String id, {String login = 'alice'}) => TwitchMessage(
      login: login,
      text: 'hello',
      messageId: id,
      channel: 'test',
    );
    test('inserts and duplicate signals share one notifier contract', () {
      final store = _store();
      final events = <ChatStoreEvent>[];
      final sub = store.events.listen(events.add);
      expect(store.ingestMessage(live('m1'), maxMessages: 10), isTrue);
      expect(store.channelMessages['test']!.first.messageId, 'm1');
      expect(store.messageCountNotifier('test').value, 1);
      expect(events.single.signal, ChatStoreSignal.newContent);
      expect(events.single.channel, 'test');
      sub.cancel();

      final dupEvents = <ChatStoreEvent>[];
      final dupSub = store.events.listen(dupEvents.add);
      expect(store.ingestMessage(live('m1'), maxMessages: 10), isFalse);
      dupSub.cancel();
      expect(store.channelMessages['test'], hasLength(1));
      expect(store.messageCountNotifier('test').value, 1);
      expect(dupEvents, isEmpty);
    });

    for (final (name, highlight, selected, unread, bump) in [
      (
        'mention highlight bumps unread bookkeeping and mirrors into mentions',
        const HighlightState(types: {HighlightType.username}),
        'other',
        1,
        1,
      ),
      (
        'mention in the selected channel skips counters but still mirrors',
        const HighlightState(types: {HighlightType.reply}),
        'test',
        0,
        0,
      ),
    ]) {
      test(name, () {
        final store = _store();
        final msg = live('m1')..highlight = highlight;

        expect(
          store.ingestMessage(
            msg,
            maxMessages: 10,
            selectedChannel: selected,
            mentionsChannel: '@mentions',
          ),
          isTrue,
        );
        expect(store.unreadMentions, unread);
        expect(store.mentionsBump.value, bump);
        expect(store.channelMessages['@mentions'], hasLength(1));
        expect(store.channelMessages['@mentions']!.single.messageId, 'm1');
      });
    }
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

    test(
      'mirror ordering stays newest-first across midnight and caller iteration order',
      () {
        final cases = [
          (
            'sorts a mixed batch newest-first across midnight',
            [
              mention('m1', DateTime(2026, 8, 22, 23, 59, 59)),
              mention('m2', DateTime(2026, 8, 23, 0, 0, 1)),
            ],
            ['m2', 'm1'],
          ),
          (
            'caller iteration order never leaks into the buffer',
            [
              for (var i = 0; i < 5; i++)
                mention('m$i', DateTime(2026, 8, 20, 12, 0, i)),
            ],
            ['m4', 'm3', 'm2', 'm1', 'm0'],
          ),
        ];
        for (final (label, input, expected) in cases) {
          final store = _store();
          store.mirrorMentions('@mentions', input, maxMessages: 10);
          expect(
            store.channelMessages['@mentions']!.map((m) => m.messageId),
            expected,
            reason: label,
          );
          final other = _store();
          other.mirrorMentions(
            '@mentions',
            input.reversed.toList(),
            maxMessages: 10,
          );
          expect(
            other.channelMessages['@mentions']!.map((m) => m.messageId),
            expected,
            reason: '$label reversed',
          );
        }
      },
    );

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

  group('ChatStore.activeThreads', () {
    ChatStore tickingStore(DateTime start) {
      var t = start;
      return ChatStore(
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
        now: () => t = t.add(const Duration(seconds: 1)),
      );
    }

    TwitchMessage root(String id) => TwitchMessage(
      login: 'alice',
      text: 'root $id',
      messageId: id,
      channel: 'test',
    );

    TwitchMessage reply(String id, String rootId) => TwitchMessage(
      login: 'bob',
      text: 'reply $id',
      messageId: id,
      channel: 'test',
      replyToParentId: rootId,
      replyThreadRootId: rootId,
    );

    test('empty when no threads were ever ingested', () {
      expect(_store().activeThreads('test'), isEmpty);
      expect(_store().activeThreads('missing'), isEmpty);
    });

    test('sorts newest activity first with reply counts', () {
      final store = tickingStore(DateTime(2026, 1, 1));
      expect(store.ingestMessage(root('r1'), maxMessages: 100), isTrue);
      expect(store.ingestMessage(reply('c1', 'r1'), maxMessages: 100), isTrue);
      expect(store.ingestMessage(root('r2'), maxMessages: 100), isTrue);
      expect(store.ingestMessage(reply('c2', 'r2'), maxMessages: 100), isTrue);
      expect(store.ingestMessage(reply('c2b', 'r2'), maxMessages: 100), isTrue);
      expect(store.ingestMessage(reply('c3', 'r1'), maxMessages: 100), isTrue);

      final threads = store.activeThreads('test');
      expect(threads.map((t) => t.rootId), ['r1', 'r2']);
      expect(threads.first.replyCount, 2);
      expect(threads.last.replyCount, 2);
      expect(threads.first.root?.messageId, 'r1');
    });

    test('hides threads with a single reply', () {
      final store = tickingStore(DateTime(2026, 1, 1));
      expect(store.ingestMessage(root('r1'), maxMessages: 100), isTrue);
      expect(store.ingestMessage(reply('c1', 'r1'), maxMessages: 100), isTrue);
      expect(store.activeThreads('test'), isEmpty);
      // The thread itself still resolves for the message-menu View thread.
      expect(store.threadFor('test', 'r1'), hasLength(2));
    });

    test('includes orphan threads whose root never arrived', () {
      final store = tickingStore(DateTime(2026, 1, 1));
      store.indexMessages('test', [reply('c1', 'ghost'), reply('c2', 'ghost')]);

      final threads = store.activeThreads('test');
      expect(threads, hasLength(1));
      expect(threads.single.rootId, 'ghost');
      expect(threads.single.root, isNull);
      expect(threads.single.replyCount, 2);
    });

    test('standalone messages never become threads', () {
      final store = tickingStore(DateTime(2026, 1, 1));
      store.indexMessages('test', [root('r1')]);
      expect(store.activeThreads('test'), isEmpty);
    });

    test('decayed threads with no replies left drop out', () {
      final store = tickingStore(DateTime(2026, 1, 1));
      expect(store.ingestMessage(root('r1'), maxMessages: 100), isTrue);
      final replyA = reply('c1', 'r1');
      final replyB = reply('c2', 'r1');
      expect(store.ingestMessage(replyA, maxMessages: 100), isTrue);
      expect(store.ingestMessage(replyB, maxMessages: 100), isTrue);
      expect(store.activeThreads('test'), hasLength(1));
      store.decayEvicted('test', [replyA, replyB]);
      expect(store.activeThreads('test'), isEmpty);
    });

    test('saved threads survive truncation past the window', () {
      final store = tickingStore(DateTime(2026, 1, 1));
      final savedRoot = root('r1');
      final savedReplyA = reply('c1', 'r1');
      final savedReplyB = reply('c2', 'r1');
      final savedReplyC = reply('c3', 'r1');
      TwitchMessage filler(String id) => TwitchMessage(
        login: 'z',
        text: 'filler $id',
        messageId: id,
        channel: 'test',
      );
      store.channelMessages['test'] = [
        for (var i = 0; i < 10; i++) filler('n$i'),
        savedReplyC,
        savedReplyB,
        savedReplyA,
        savedRoot,
        for (var i = 0; i < 10; i++) filler('o$i'),
      ];
      store.indexMessages('test', [
        savedRoot,
        savedReplyA,
        savedReplyB,
        savedReplyC,
      ]);
      store.savedThreadKeys.add('test:r1');
      store.truncateChannel('test', maxMessages: 5);

      final ids = store.channelMessages['test']!
          .map((m) => m.messageId)
          .toSet();
      expect(ids, contains('r1'));
      expect(ids, contains('c1'));
      expect(ids, contains('c2'));
      expect(ids, contains('c3'));
      expect(ids, isNot(contains('o0')));
      // Saved replies never decay out of the thread map either.
      store.decayEvicted('test', [savedReplyA]);
      expect(store.activeThreads('test').map((t) => t.rootId), contains('r1'));
    });

    test('thread cap never evicts saved entries', () {
      final store = tickingStore(DateTime(2026, 1, 1));
      expect(store.ingestMessage(root('r0'), maxMessages: 10000), isTrue);
      expect(
        store.ingestMessage(reply('c0', 'r0'), maxMessages: 10000),
        isTrue,
      );
      expect(
        store.ingestMessage(reply('d0', 'r0'), maxMessages: 10000),
        isTrue,
      );
      store.savedThreadKeys.add('test:r0');
      for (var i = 1; i <= 70; i++) {
        expect(store.ingestMessage(root('r$i'), maxMessages: 10000), isTrue);
        expect(
          store.ingestMessage(reply('c$i', 'r$i'), maxMessages: 10000),
          isTrue,
        );
        expect(
          store.ingestMessage(reply('d$i', 'r$i'), maxMessages: 10000),
          isTrue,
        );
      }
      final ids = store.activeThreads('test').map((t) => t.rootId).toSet();
      expect(ids, contains('r0'));
      expect(ids.length, lessThanOrEqualTo(65));
    });
  });

  group('ChatStore.recentMessagesFromUser', () {
    TwitchMessage msg(String login, String text) =>
        TwitchMessage(login: login, text: text, channel: 'test');

    test('returns newest-first matches, skips system rows', () {
      final store = _store();
      store.channelMessages['test'] = [
        msg('bob', 'new'),
        msg('alice', 'skip me'),
        TwitchMessage(login: '', text: 'sys', isSystem: true, channel: 'test'),
        msg('bob', 'old'),
      ];
      final out = store.recentMessagesFromUser('test', 'bob');
      expect(out.map((m) => m.text), ['new', 'old']);
    });

    test('matches case-insensitively and honors limit', () {
      final store = _store();
      store.channelMessages['test'] = [
        msg('bob', 'c'),
        msg('BOB', 'b'),
        msg('bob', 'a'),
      ];
      expect(
        store
            .recentMessagesFromUser('test', 'BoB', limit: 2)
            .map((m) => m.text),
        ['c', 'b'],
      );
    });

    test('empty for unknown channel, blank login, or non-positive limit', () {
      final store = _store();
      store.channelMessages['test'] = [msg('bob', 'hi')];
      expect(store.recentMessagesFromUser('test', 'missing'), isEmpty);
      expect(store.recentMessagesFromUser('missing', 'bob'), isEmpty);
      expect(store.recentMessagesFromUser('test', ''), isEmpty);
      expect(store.recentMessagesFromUser('test', 'bob', limit: 0), isEmpty);
    });

    test('default limit keeps the 50 newest', () {
      final store = _store();
      store.channelMessages['test'] = [
        for (var i = 60; i >= 1; i--) msg('bob', 'm$i'),
      ];
      final out = store.recentMessagesFromUser('test', 'bob');
      expect(out, hasLength(50));
      expect(out.first.text, 'm60');
      expect(out.last.text, 'm11');
    });
  });
}
