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

    test('pinned open thread survives truncation and decay', () {
      final store = tickingStore(DateTime(2026, 1, 1));
      final r = root('r1'), a = reply('c1', 'r1'), b = reply('c2', 'r1');
      TwitchMessage filler(String id) => TwitchMessage(
        login: 'z',
        text: 'filler $id',
        messageId: id,
        channel: 'test',
      );
      store.channelMessages['test'] = [
        for (var i = 0; i < 10; i++) filler('n$i'),
        b,
        a,
        r,
        for (var i = 0; i < 10; i++) filler('o$i'),
      ];
      store.indexMessages('test', [r, a, b]);
      store.pinThread('test', 'c1');
      store.truncateChannel('test', maxMessages: 5);

      final ids = store.channelMessages['test']!
          .map((m) => m.messageId)
          .toSet();
      expect(ids, containsAll(['r1', 'c1', 'c2']));
      // Decay holds while pinned, releases on unpin.
      store.decayEvicted('test', [a, b]);
      expect(store.activeThreads('test').map((t) => t.rootId), contains('r1'));
      store.unpinChannelThreads('test');
      store.decayEvicted('test', [a, b]);
      expect(store.activeThreads('test'), isEmpty);
    });

    test('active threads pin at most 20 members', () {
      final store = tickingStore(DateTime(2026, 1, 1));
      final r = root('r1');
      final replies = [for (var i = 1; i <= 25; i++) reply('c$i', 'r1')];
      TwitchMessage filler(String id) => TwitchMessage(
        login: 'z',
        text: 'filler $id',
        messageId: id,
        channel: 'test',
      );
      store.channelMessages['test'] = [
        replies.last,
        for (var i = 0; i < 4; i++) filler('n$i'),
        ...replies.reversed.skip(1),
        r,
        for (var i = 0; i < 10; i++) filler('o$i'),
      ];
      store.indexMessages('test', [r, ...replies]);
      store.truncateChannel('test', maxMessages: 5);

      final ids = store.channelMessages['test']!
          .map((m) => m.messageId)
          .toSet();
      expect(ids, contains('c6'));
      expect(ids, contains('c5'));
      expect(ids, isNot(contains('c4')));
      expect(ids, isNot(contains('r1')));
      expect(store.threadFor('test', 'r1')!.first.messageId, 'r1');
    });

    test('pinned open thread survives the thread map cap', () {
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
      store.pinThread('test', 'r0');
      for (var i = 1; i <= 65; i++) {
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
      // 66 threads, 65 unheld over the 64 cap: the pinned oldest survives
      // outside the cap (like saved threads) and r1 falls off.
      expect(store.threadFor('test', 'r0'), isNotNull);
      expect(store.activeThreads('test').map((t) => t.rootId), contains('r0'));
      expect(store.threadFor('test', 'r1'), isNull);
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

  group('ChatStore held queue', () {
    HeldMessage held(String id, [String channel = 'test']) => HeldMessage(
      messageId: id,
      channel: channel,
      userLogin: 'spammer',
      text: 'bad text',
      category: 'bullying',
    );

    test('queues newest first and ignores duplicate deliveries', () {
      final store = _store();
      store.addHeldMessage(held('m1'));
      store.addHeldMessage(held('m2'));
      expect(store.heldMessages['test']!.map((m) => m.messageId), ['m2', 'm1']);
      final version = store.heldVersion.value;
      store.addHeldMessage(held('m1'));
      expect(store.heldMessages['test'], hasLength(2));
      expect(store.heldVersion.value, version, reason: 'dup is a no-op');
    });

    test('resolve drops the entry and prunes empty channels', () {
      final store = _store();
      store.addHeldMessage(held('m1'));
      store.addHeldMessage(held('m2'));
      expect(store.resolveHeldMessage('test', 'm1'), isTrue);
      expect(store.heldMessages['test']!.map((m) => m.messageId), ['m2']);
      expect(store.resolveHeldMessage('test', 'm1'), isFalse);
      expect(store.resolveHeldMessage('missing', 'm1'), isFalse);
      expect(store.resolveHeldMessage('test', 'm2'), isTrue);
      expect(store.heldMessages.containsKey('test'), isFalse);
    });

    test('resolved ids re-queue, and the per-channel cap drops oldest', () {
      final store = _store();
      store.addHeldMessage(held('m1'));
      expect(store.resolveHeldMessage('test', 'm1'), isTrue);
      store.addHeldMessage(held('m1'));
      expect(store.heldMessages['test']!.map((m) => m.messageId), [
        'm1',
      ], reason: 're-hold after resolve queues again');
      for (var i = 0; i < ChatStore.maxHeldPerChannel + 10; i++) {
        store.addHeldMessage(held('cap$i'));
      }
      final queue = store.heldMessages['test']!;
      expect(queue, hasLength(ChatStore.maxHeldPerChannel));
      expect(queue.first.messageId, 'cap209');
      expect(queue.last.messageId, 'cap10');
    });

    test('clearAllHeldMessages drops every queue in one bump', () {
      final store = _store();
      store.addHeldMessage(held('m1'));
      store.addHeldMessage(held('m2', 'other'));
      final version = store.heldVersion.value;
      store.clearAllHeldMessages();
      expect(store.heldMessages, isEmpty);
      expect(store.heldVersion.value, version + 1);
      store.clearAllHeldMessages();
      expect(store.heldVersion.value, version + 1, reason: 'no-op is quiet');
    });

    test('clearHeldMessages drops the channel queue, forgetChannel too', () {
      final store = _store();
      store.addHeldMessage(held('m1'));
      store.addHeldMessage(held('m2', 'other'));
      final version = store.heldVersion.value;
      store.clearHeldMessages('missing');
      expect(store.heldVersion.value, version, reason: 'no-op is quiet');
      store.clearHeldMessages('test');
      expect(store.heldMessages.containsKey('test'), isFalse);
      expect(store.heldMessages.containsKey('other'), isTrue);
      store.forgetChannel('other');
      expect(store.heldMessages.containsKey('other'), isFalse);
    });
  });

  group('ChatStore mod feed', () {
    final t0 = DateTime(2026, 1, 1);
    ModActivityEntry activity(
      String action, {
      String channel = 'test',
      String? target,
      String? reason,
      List<String> terms = const [],
    }) => ModActivityEntry(
      at: t0,
      channel: channel,
      action: action,
      moderator: 'moduser',
      target: target,
      reason: reason,
      terms: terms,
    );

    test('logs newest first and caps per channel', () {
      final store = _store();
      store.addModActivity(activity('ban', target: 'a'));
      store.addModActivity(activity('timeout', target: 'b'));
      expect(store.modActivity['test']!.map((e) => e.target), ['b', 'a']);
      for (var i = 0; i < ChatStore.maxActivityPerChannel + 10; i++) {
        store.addModActivity(activity('slow', target: 'u$i'));
      }
      final feed = store.modActivity['test']!;
      expect(feed, hasLength(ChatStore.maxActivityPerChannel));
      expect(feed.first.target, 'u209');
    });

    test('clearModActivity is quiet on missing channels', () {
      final store = _store();
      final version = store.modActivityVersion.value;
      store.clearModActivity('missing');
      expect(store.modActivityVersion.value, version);
      store.addModActivity(activity('ban'));
      store.clearModActivity('test');
      expect(store.modActivity.containsKey('test'), isFalse);
    });

    test('warnings filter case-insensitively per user', () {
      final store = _store();
      store.addWarning(
        WarnEntry(
          at: t0,
          channel: 'test',
          target: 'Spammer',
          moderator: 'moduser',
          reason: 'spam',
        ),
      );
      store.addWarning(
        WarnEntry(
          at: t0,
          channel: 'test',
          target: 'other',
          moderator: 'moduser',
        ),
      );
      final found = store.warningsFor('test', 'spammer');
      expect(found, hasLength(1));
      expect(found.first.reason, 'spam');
      expect(store.warningsFor('test', 'missing'), isEmpty);
      expect(store.warningsFor('missing', 'spammer'), isEmpty);
    });

    test('ban roster puts, queries, and removes case-insensitively', () {
      final store = _store();
      expect(store.banFor('test', 'Spammer'), isNull);
      store.putBan(
        BanEntry(
          at: t0,
          channel: 'test',
          login: 'Spammer',
          moderator: 'moduser',
        ),
      );
      expect(store.banFor('test', 'spammer')!.expiresAt, isNull);
      // A timeout overwrites the ban entry.
      store.putBan(
        BanEntry(
          at: t0,
          channel: 'test',
          login: 'SPAMMER',
          expiresAt: t0.add(const Duration(seconds: 600)),
          moderator: 'moduser',
        ),
      );
      expect(
        store.banFor('test', 'spammer')!.expiresAt,
        t0.add(const Duration(seconds: 600)),
      );
      expect(store.removeBan('test', 'Spammer'), isTrue);
      expect(store.banFor('test', 'spammer'), isNull);
      expect(store.removeBan('test', 'spammer'), isFalse);
      expect(store.removeBan('missing', 'spammer'), isFalse);
    });

    test('forgetChannel clears feed, warnings, and bans in one bump', () {
      final store = _store();
      store.addModActivity(activity('ban'));
      store.addWarning(
        WarnEntry(
          at: t0,
          channel: 'test',
          target: 'spammer',
          moderator: 'moduser',
        ),
      );
      store.putBan(
        BanEntry(
          at: t0,
          channel: 'test',
          login: 'spammer',
          moderator: 'moduser',
        ),
      );
      store.noteSuspicious(
        SuspiciousInfo(
          at: t0,
          channel: 'test',
          login: 'spammer',
          status: 'monitored',
        ),
      );
      final version = store.modActivityVersion.value;
      store.forgetChannel('test');
      expect(store.modActivity.containsKey('test'), isFalse);
      expect(store.channelWarnings.containsKey('test'), isFalse);
      expect(store.channelBans.containsKey('test'), isFalse);
      expect(store.suspiciousUsers.containsKey('test'), isFalse);
      expect(store.modActivityVersion.value, version + 1);
    });

    test('suspicious sightings upsert, query, and clear', () {
      final store = _store();
      expect(store.suspiciousFor('test', 'spammer'), isNull);
      store.noteSuspicious(
        SuspiciousInfo(
          at: t0,
          channel: 'test',
          login: 'Spammer',
          status: 'restricted',
          types: const ['manually_added'],
          banEvasion: 'possible',
          sharedBanChannelIds: const ['111'],
        ),
      );
      final seen = store.suspiciousFor('test', 'spammer')!;
      expect(seen.status, 'restricted');
      expect(seen.sharedBanChannelIds, ['111']);
      expect(store.removeSuspicious('test', 'SPAMMER'), isTrue);
      expect(store.suspiciousFor('test', 'spammer'), isNull);
      expect(store.removeSuspicious('test', 'spammer'), isFalse);
    });

    test('touchInbox bumps the inbox version', () {
      final store = _store();
      final version = store.modInboxVersion.value;
      store.touchInbox();
      expect(store.modInboxVersion.value, version + 1);
    });

    test('formatModActivity renders each action', () {
      ModActivityEntry entry(
        String action, {
        String? target = 'spammer',
        String? reason,
        int? duration,
        List<String> terms = const [],
      }) => ModActivityEntry(
        at: t0,
        channel: 'test',
        action: action,
        moderator: 'moduser',
        target: target,
        reason: reason,
        durationSeconds: duration,
        terms: terms,
      );
      for (final (action, expected) in [
        ('ban', 'moduser banned spammer.'),
        ('untimeout', 'moduser unbanned spammer.'),
        ('delete', 'moduser deleted a message from spammer.'),
        ('clear', 'moduser cleared the chat.'),
        ('mod', 'moduser modded spammer.'),
        ('unvip', 'moduser removed spammer as a VIP.'),
        ('warn_ack', 'spammer acknowledged a warning.'),
        ('slow', 'moduser enabled slow mode.'),
        ('followersoff', 'moduser disabled followers-only mode.'),
        ('uniquechat', 'moduser enabled unique chat.'),
        ('raid', 'moduser started a raid.'),
        ('shield_on', 'moduser enabled Shield Mode.'),
        ('shoutout', 'moduser shouted out spammer.'),
        ('automod_settings', 'moduser updated AutoMod settings.'),
      ]) {
        expect(formatModActivity(entry(action)), expected, reason: action);
      }
      expect(
        formatModActivity(entry('timeout', duration: 90)),
        'moduser timed out spammer for 1m 30s.',
      );
      expect(
        formatModActivity(entry('warn', reason: 'spam')),
        'moduser warned spammer: "spam".',
      );
      expect(
        formatModActivity(entry('deny_unban_request', reason: 'too soon')),
        'moduser denied spammer\'s unban request: "too soon".',
      );
      expect(
        formatModActivity(entry('deny_unban_request', reason: 'too soon')),
        'moduser denied spammer\'s unban request: "too soon".',
      );
      expect(
        formatModActivity(entry('suspicious_flag', reason: 'restricted')),
        'moduser flagged spammer: "restricted".',
      );
      expect(
        formatModActivity(
          entry('remove_blocked_term', target: null, terms: ['a', 'b']),
        ),
        'moduser removed 2 blocked terms.',
      );
      expect(
        formatModActivity(entry('some_future_action', target: null)),
        'moduser did some future action.',
      );
    });
  });
}
