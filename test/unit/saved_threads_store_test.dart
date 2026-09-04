import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ermchat/models/twitch_badge.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/saved_threads_store.dart';

TwitchMessage _msg(String id, String channel, {String? rootId}) =>
    TwitchMessage(
      login: 'alice',
      displayName: 'Alice',
      text: 'hello world $id',
      messageId: id,
      channel: channel,
      replyToParentId: rootId,
      replyThreadRootId: rootId,
    );

void main() {
  group('SavedThreadsStore', () {
    test('toggle saves then unsaves', () {
      final store = SavedThreadsStore();
      final entry = SavedThread.fromMessage(_msg('r1', 'forsen'), 'r1');
      expect(store.toggle(entry), isTrue);
      expect(store.isSaved('forsen', 'r1'), isTrue);
      expect(store.toggle(entry), isFalse);
      expect(store.isSaved('forsen', 'r1'), isFalse);
    });

    test('channel matching is case-insensitive', () {
      final store = SavedThreadsStore();
      store.toggle(SavedThread.fromMessage(_msg('r1', 'Forsen'), 'r1'));
      expect(store.isSaved('forsen', 'r1'), isTrue);
      expect(store.threads.single.channel, 'forsen');
    });

    test('round-trips through JSON, dropping corrupt rows', () {
      final store = SavedThreadsStore();
      store.toggle(SavedThread.fromMessage(_msg('r1', 'forsen'), 'r1'));
      final raw = store.encode();

      final other = SavedThreadsStore();
      other.decode(raw);
      expect(other.isSaved('forsen', 'r1'), isTrue);
      expect(other.threads.single.author, 'Alice');

      final bad = SavedThreadsStore();
      bad.decode('not json{{{');
      expect(bad.threads, isEmpty);
    });

    test('caps at 50, evicting the oldest', () {
      final store = SavedThreadsStore();
      for (var i = 0; i < 55; i++) {
        store.toggle(SavedThread.fromMessage(_msg('r$i', 'forsen'), 'r$i'));
      }
      expect(store.threads, hasLength(maxSavedThreads));
      expect(store.isSaved('forsen', 'r0'), isFalse);
      expect(store.isSaved('forsen', 'r54'), isTrue);
    });

    test('rejects entries with an empty channel or root id', () {
      final store = SavedThreadsStore();
      expect(
        store.toggle(SavedThread.fromMessage(_msg('r1', ''), 'r1')),
        isFalse,
      );
      expect(store.threads, isEmpty);
    });

    test('keeps valid rows when sibling rows are corrupt', () {
      final good = SavedThread.fromMessage(_msg('r1', 'forsen'), 'r1').toJson();
      final raw =
          '[${jsonEncode(good)}, 42, {"channel": 7, "rootId": ["x"]}, {"channel": "", "rootId": ""}]';
      final mixed = SavedThreadsStore();
      mixed.decode(raw);
      expect(mixed.threads, hasLength(1));
      expect(mixed.isSaved('forsen', 'r1'), isTrue);
    });

    test('drops rows with a bad savedAt instead of freezing at epoch', () {
      final mixed = SavedThreadsStore();
      mixed.decode(
        '[{"channel": "forsen", "rootId": "r1", "savedAt": "not-a-date"}]',
      );
      expect(mixed.threads, isEmpty);
    });

    test('saves the full log and appends live replies', () {
      final store = SavedThreadsStore();
      final root = _msg('r1', 'forsen');
      final reply = _msg('c1', 'forsen', rootId: 'r1');
      expect(
        store.toggle(SavedThread.fromMessage(root, 'r1'), [reply, root]),
        isTrue,
      );
      expect(store.messagesFor('forsen', 'r1'), hasLength(2));
      expect(store.appendMessage(_msg('c2', 'forsen', rootId: 'r1')), isTrue);
      expect(store.messagesFor('forsen', 'r1'), hasLength(3));
      // Duplicates and foreign threads are ignored.
      expect(store.appendMessage(_msg('c2', 'forsen', rootId: 'r1')), isFalse);
      expect(store.appendMessage(_msg('x', 'other')), isFalse);
    });

    test('persists the full log to disk and reloads it', () async {
      final dir = await Directory.systemTemp.createTemp('saved_threads');
      try {
        final store = SavedThreadsStore()..overrideDirectory(dir);
        final root = _msg('r1', 'forsen');
        store.toggle(SavedThread.fromMessage(root, 'r1'), [root]);
        store.appendMessage(_msg('c1', 'forsen', rootId: 'r1'));
        await store.flush();

        final other = SavedThreadsStore()..overrideDirectory(dir);
        await other.load();
        expect(other.isSaved('forsen', 'r1'), isTrue);
        final msgs = other.messagesFor('forsen', 'r1');
        expect(msgs.map((m) => m.messageId), containsAll(['r1', 'c1']));
        expect(msgs.first.text, contains('hello world'));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('TwitchMessage JSON', () {
    test('round-trips render fields', () {
      final msg = TwitchMessage(
        login: 'alice',
        displayName: 'Alice',
        text: 'hi Kappa',
        color: '#FF0000',
        messageId: 'm1',
        channel: 'forsen',
        replyToParentId: 'p1',
        replyThreadRootId: 'r1',
        emotePositions: const [
          EmotePosition(
            emoteId: '25',
            startIndex: 3,
            endIndex: 7,
            emoteCode: 'Kappa',
          ),
        ],
        badges: const [MessageBadge(setId: 'vip', versionId: '1')],
      );
      final back = TwitchMessage.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(msg.toJson())) as Map),
      );
      expect(back.login, 'alice');
      expect(back.text, 'hi Kappa');
      expect(back.messageId, 'm1');
      expect(back.replyThreadRootId, 'r1');
      expect(back.emotePositions?.single.emoteCode, 'Kappa');
      expect(back.badges?.single.setId, 'vip');
    });
  });
}
