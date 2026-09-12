import 'package:ermchat/chat/channel/channel.dart';
import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:flutter_test/flutter_test.dart';

TwitchMessage _root(String id) => TwitchMessage(
  login: 'alice',
  text: 'root $id',
  messageId: id,
  channel: 'test',
);

TwitchMessage _reply(String id, String rootId) => TwitchMessage(
  login: 'bob',
  text: 'reply $id',
  messageId: id,
  channel: 'test',
  replyToParentId: rootId,
  replyThreadRootId: rootId,
);

TwitchMessage _filler(String id) => TwitchMessage(
  login: 'z',
  text: 'filler $id',
  messageId: id,
  channel: 'test',
);

// Threads has no clock of its own in tests: the Chat now tick stamps
// lastActivity, so activity order follows ingest order.
Chat _tickingChat(DateTime start) {
  var t = start;
  final chat = Chat(now: () => t = t.add(const Duration(seconds: 1)));
  chat.ensure('test');
  return chat;
}

void main() {
  group('Threads.activeThreads', () {
    test('empty when no threads were ever ingested', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      expect(chat.ensure('test').threads.activeThreads(), isEmpty);
      expect(chat.channelFor('missing'), isNull);
    });

    test('sorts newest activity first with reply counts', () {
      final chat = _tickingChat(DateTime(2026, 1, 1));
      addTearDown(chat.dispose);
      final channel = chat.channelFor('test')!;
      ReceiveResult ingest(String id, {String? root}) => channel.receive(
        root == null ? _root(id) : _reply(id, root),
        maxMessages: 100,
        isSelected: true,
        ownLogin: null,
      );
      expect(ingest('r1').inserted, isTrue);
      expect(ingest('c1', root: 'r1').inserted, isTrue);
      expect(ingest('r2').inserted, isTrue);
      expect(ingest('c2', root: 'r2').inserted, isTrue);
      expect(ingest('c2b', root: 'r2').inserted, isTrue);
      expect(ingest('c3', root: 'r1').inserted, isTrue);

      final threads = channel.threads.activeThreads();
      expect(threads.map((t) => t.rootId), ['r1', 'r2']);
      expect(threads.first.replyCount, 2);
      expect(threads.last.replyCount, 2);
      expect(threads.first.root?.messageId, 'r1');
    });

    test('hides threads with a single reply', () {
      final chat = _tickingChat(DateTime(2026, 1, 1));
      addTearDown(chat.dispose);
      final channel = chat.channelFor('test')!;
      expect(
        channel
            .receive(
              _root('r1'),
              maxMessages: 100,
              isSelected: true,
              ownLogin: null,
            )
            .inserted,
        isTrue,
      );
      expect(
        channel
            .receive(
              _reply('c1', 'r1'),
              maxMessages: 100,
              isSelected: true,
              ownLogin: null,
            )
            .inserted,
        isTrue,
      );
      expect(channel.threads.activeThreads(), isEmpty);
      // The thread itself still resolves for the message-menu View thread.
      expect(channel.threads.threadFor('r1'), hasLength(2));
    });

    test('includes orphan threads whose root never arrived', () {
      final chat = _tickingChat(DateTime(2026, 1, 1));
      addTearDown(chat.dispose);
      final channel = chat.channelFor('test')!;
      channel.threads.index([
        _reply('c1', 'ghost'),
        _reply('c2', 'ghost'),
      ], lookupRoot: channel.messages.byId);

      final threads = channel.threads.activeThreads();
      expect(threads, hasLength(1));
      expect(threads.single.rootId, 'ghost');
      expect(threads.single.root, isNull);
      expect(threads.single.replyCount, 2);
    });

    test('standalone messages never become threads', () {
      final chat = _tickingChat(DateTime(2026, 1, 1));
      addTearDown(chat.dispose);
      final channel = chat.channelFor('test')!;
      channel.threads.index([_root('r1')], lookupRoot: channel.messages.byId);
      expect(channel.threads.activeThreads(), isEmpty);
    });

    test('decayed threads with no replies left drop out', () {
      final chat = _tickingChat(DateTime(2026, 1, 1));
      addTearDown(chat.dispose);
      final channel = chat.channelFor('test')!;
      expect(
        channel
            .receive(
              _root('r1'),
              maxMessages: 100,
              isSelected: true,
              ownLogin: null,
            )
            .inserted,
        isTrue,
      );
      final replyA = _reply('c1', 'r1');
      final replyB = _reply('c2', 'r1');
      expect(
        channel
            .receive(replyA, maxMessages: 100, isSelected: true, ownLogin: null)
            .inserted,
        isTrue,
      );
      expect(
        channel
            .receive(replyB, maxMessages: 100, isSelected: true, ownLogin: null)
            .inserted,
        isTrue,
      );
      expect(channel.threads.activeThreads(), hasLength(1));
      channel.threads.decay([replyA, replyB]);
      expect(channel.threads.activeThreads(), isEmpty);
    });

    test('saved threads survive truncation past the window', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      final savedRoot = _root('r1');
      final savedReplyA = _reply('c1', 'r1');
      final savedReplyB = _reply('c2', 'r1');
      final savedReplyC = _reply('c3', 'r1');
      // Newest-first buffer, built oldest-first since add inserts at the top.
      final newestFirst = [
        for (var i = 0; i < 10; i++) _filler('n$i'),
        savedReplyC,
        savedReplyB,
        savedReplyA,
        savedRoot,
        for (var i = 0; i < 10; i++) _filler('o$i'),
      ];
      for (final m in newestFirst.reversed) {
        channel.messages.add(m, maxMessages: 1000);
      }
      channel.threads.index([
        savedRoot,
        savedReplyA,
        savedReplyB,
        savedReplyC,
      ], lookupRoot: channel.messages.byId);
      channel.threads.syncSavedKeys('test', {'test:r1'});
      channel.truncate(5);

      final ids = channel.messages.items.map((m) => m.messageId).toSet();
      expect(ids, contains('r1'));
      expect(ids, contains('c1'));
      expect(ids, contains('c2'));
      expect(ids, contains('c3'));
      expect(ids, isNot(contains('o0')));
      // Saved replies never decay out of the thread map either.
      channel.threads.decay([savedReplyA]);
      expect(
        channel.threads.activeThreads().map((t) => t.rootId),
        contains('r1'),
      );
    });

    test('thread cap never evicts saved entries', () {
      final chat = _tickingChat(DateTime(2026, 1, 1));
      addTearDown(chat.dispose);
      final channel = chat.channelFor('test')!;
      ReceiveResult ingest(TwitchMessage m) => channel.receive(
        m,
        maxMessages: 10000,
        isSelected: true,
        ownLogin: null,
      );
      expect(ingest(_root('r0')).inserted, isTrue);
      expect(ingest(_reply('c0', 'r0')).inserted, isTrue);
      expect(ingest(_reply('d0', 'r0')).inserted, isTrue);
      channel.threads.syncSavedKeys('test', {'test:r0'});
      for (var i = 1; i <= 70; i++) {
        expect(ingest(_root('r$i')).inserted, isTrue);
        expect(ingest(_reply('c$i', 'r$i')).inserted, isTrue);
        expect(ingest(_reply('d$i', 'r$i')).inserted, isTrue);
      }
      final ids = channel.threads.activeThreads().map((t) => t.rootId).toSet();
      expect(ids, contains('r0'));
      expect(ids.length, lessThanOrEqualTo(65));
    });

    test('pinned open thread survives truncation and decay', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      final r = _root('r1'), a = _reply('c1', 'r1'), b = _reply('c2', 'r1');
      final newestFirst = [
        for (var i = 0; i < 10; i++) _filler('n$i'),
        b,
        a,
        r,
        for (var i = 0; i < 10; i++) _filler('o$i'),
      ];
      for (final m in newestFirst.reversed) {
        channel.messages.add(m, maxMessages: 1000);
      }
      channel.threads.index([r, a, b], lookupRoot: channel.messages.byId);
      channel.threads.pin('c1');
      channel.truncate(5);

      final ids = channel.messages.items.map((m) => m.messageId).toSet();
      expect(ids, containsAll(['r1', 'c1', 'c2']));
      // Decay holds while pinned, releases on unpin.
      channel.threads.decay([a, b]);
      expect(
        channel.threads.activeThreads().map((t) => t.rootId),
        contains('r1'),
      );
      channel.threads.clearPinned();
      channel.threads.decay([a, b]);
      expect(channel.threads.activeThreads(), isEmpty);
    });

    test('active threads pin at most 20 members', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      final r = _root('r1');
      final replies = [for (var i = 1; i <= 25; i++) _reply('c$i', 'r1')];
      final newestFirst = [
        replies.last,
        for (var i = 0; i < 4; i++) _filler('n$i'),
        ...replies.reversed.skip(1),
        r,
        for (var i = 0; i < 10; i++) _filler('o$i'),
      ];
      for (final m in newestFirst.reversed) {
        channel.messages.add(m, maxMessages: 1000);
      }
      channel.threads.index([r, ...replies], lookupRoot: channel.messages.byId);
      channel.truncate(5);

      final ids = channel.messages.items.map((m) => m.messageId).toSet();
      expect(ids, contains('c6'));
      expect(ids, contains('c5'));
      expect(ids, isNot(contains('c4')));
      expect(ids, isNot(contains('r1')));
      expect(channel.threads.threadFor('r1')!.first.messageId, 'r1');
    });

    test('pinned open thread survives the thread map cap', () {
      final chat = _tickingChat(DateTime(2026, 1, 1));
      addTearDown(chat.dispose);
      final channel = chat.channelFor('test')!;
      ReceiveResult ingest(TwitchMessage m) => channel.receive(
        m,
        maxMessages: 10000,
        isSelected: true,
        ownLogin: null,
      );
      expect(ingest(_root('r0')).inserted, isTrue);
      expect(ingest(_reply('c0', 'r0')).inserted, isTrue);
      expect(ingest(_reply('d0', 'r0')).inserted, isTrue);
      channel.threads.pin('r0');
      for (var i = 1; i <= 65; i++) {
        expect(ingest(_root('r$i')).inserted, isTrue);
        expect(ingest(_reply('c$i', 'r$i')).inserted, isTrue);
        expect(ingest(_reply('d$i', 'r$i')).inserted, isTrue);
      }
      // 66 threads, 65 unheld over the 64 cap: the pinned oldest survives
      // outside the cap (like saved threads) and r1 falls off.
      expect(channel.threads.threadFor('r0'), isNotNull);
      expect(
        channel.threads.activeThreads().map((t) => t.rootId),
        contains('r0'),
      );
      expect(channel.threads.threadFor('r1'), isNull);
    });
  });
}
