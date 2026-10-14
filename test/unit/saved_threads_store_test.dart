import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ermchat/models/twitch_badge.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/archive_store.dart';
import 'package:ermchat/services/saved_threads_store.dart';

final _t0 = DateTime.utc(2026, 10, 1, 12);

TwitchMessage _msg(
  String id,
  String channel, {
  String? rootId,
  int seconds = 0,
  String? text,
}) => TwitchMessage(
  login: 'alice',
  displayName: 'Alice',
  text: text ?? 'hello world $id',
  messageId: id,
  channel: channel,
  replyToParentId: rootId,
  replyThreadRootId: rootId,
  timestamp: _t0.add(Duration(seconds: seconds)),
);

class _ManualTimer implements Timer {
  _ManualTimer(this.callback);

  final void Function() callback;
  bool cancelled = false;
  bool fired = false;

  void fire() {
    fired = true;
    callback();
  }

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled && !fired;

  @override
  int get tick => fired ? 1 : 0;
}

void main() {
  group('SavedThreadsStore', () {
    test('toggle saves and unsaves, matching channels case-insensitively', () {
      final store = SavedThreadsStore();
      final entry = SavedThread.fromMessage(_msg('r1', 'Forsen'), 'r1');
      expect(store.toggle(entry), isTrue);
      expect(store.isSaved('forsen', 'r1'), isTrue);
      expect(store.threads.single.channel, 'forsen');
      expect(store.toggle(entry), isFalse);
      expect(store.isSaved('forsen', 'r1'), isFalse);
      expect(
        store.toggle(SavedThread.fromMessage(_msg('r1', ''), 'r1')),
        isFalse,
        reason: 'empty channel is rejected',
      );
      expect(store.threads, isEmpty);
    });

    test('decode round-trips and drops corrupt rows', () {
      final entry = SavedThread.fromMessage(_msg('r1', 'forsen'), 'r1');
      final good = jsonEncode(entry.toJson());

      final other = SavedThreadsStore()..decode('[$good]');
      expect(other.isSaved('forsen', 'r1'), isTrue);
      expect(other.threads.single.author, 'Alice');

      final inputs = {
        'not json{{{': 0,
        '[$good, 42, {"channel": 7, "rootId": ["x"]}, '
                '{"channel": "", "rootId": ""}]':
            1,
        '[{"channel": "forsen", "rootId": "r1", "savedAt": "not-a-date"}]': 0,
      };
      inputs.forEach((raw, kept) {
        final store = SavedThreadsStore()..decode(raw);
        expect(store.threads, hasLength(kept), reason: raw);
      });
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
  });

  group('SavedThreadsStore in the archive db', () {
    late Directory dir;
    late Directory legacy;
    final open = <ArchiveStore>[];

    setUpAll(sqfliteFfiInit);

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('saved_threads_db');
      legacy = Directory('${dir.path}/saved_threads');
    });

    tearDown(() async {
      for (final db in open) {
        await db.close();
      }
      open.clear();
      await dir.delete(recursive: true);
    });

    String path() => '${dir.path}/archive.db';

    Future<ArchiveStore> openDb() async {
      final db = await ArchiveStore.open(path(), factory: databaseFactoryFfi);
      open.add(db);
      return db;
    }

    // Closing the db is the crash: nothing queued in memory reaches it.
    Future<ArchiveStore> reopen(ArchiveStore db) async {
      await db.close();
      open.remove(db);
      return openDb();
    }

    SavedThreadsStore storeOn(
      ArchiveStore? db, {
      Timer Function(Duration, void Function())? createTimer,
    }) => SavedThreadsStore(
      store: Future.value(db),
      legacyDir: legacy,
      createTimer: createTimer ?? Timer.new,
    );

    Future<int> rows(ArchiveStore db, String channel, String root) async =>
        (await db.threadMessages(channel, root)).length;

    test('saves, appends and reloads the full log', () async {
      final db = await openDb();
      final store = storeOn(db);
      final root = _msg('r1', 'forsen');
      store.toggle(SavedThread.fromMessage(root, 'r1'), [root]);
      store.appendMessage(_msg('c1', 'forsen', rootId: 'r1', seconds: 1));
      await store.flush();

      final other = storeOn(db);
      await other.load();
      expect(other.isSaved('forsen', 'r1'), isTrue);
      final msgs = other.messagesFor('forsen', 'r1');
      expect(msgs.map((m) => m.messageId), [
        'c1',
        'r1',
      ], reason: 'newest first');
      expect(msgs.last.text, 'hello world r1');
    });

    test('appends join one timer and write in one flush', () async {
      final db = await openDb();
      final timers = <_ManualTimer>[];
      final store = storeOn(
        db,
        createTimer: (d, cb) {
          final t = _ManualTimer(cb);
          timers.add(t);
          return t;
        },
      );
      final root = _msg('r1', 'forsen');
      store.toggle(SavedThread.fromMessage(root, 'r1'), [root]);
      await store.flushIo();
      for (var i = 0; i < 5; i++) {
        store.appendMessage(_msg('c$i', 'forsen', rootId: 'r1', seconds: i));
      }
      expect(timers, hasLength(1), reason: 'later changes join the timer');
      expect(timers.single.isActive, isTrue);
      expect(await rows(db, 'forsen', 'r1'), 1, reason: 'nothing written yet');

      timers.single.fire();
      await store.flushIo();
      expect(await rows(db, 'forsen', 'r1'), 6);
    });

    test('a crash before the flush loses only the unflushed rows', () async {
      var db = await openDb();
      final store = storeOn(db);
      final root = _msg('r1', 'forsen');
      store.toggle(SavedThread.fromMessage(root, 'r1'), [root]);
      store.appendMessage(_msg('c1', 'forsen', rootId: 'r1', seconds: 1));
      await store.flush();
      store.appendMessage(_msg('c2', 'forsen', rootId: 'r1', seconds: 2));

      db = await reopen(db);
      final ids = (await db.threadMessages(
        'forsen',
        'r1',
      )).map((r) => r.messageId);
      expect(ids, unorderedEquals(['r1', 'c1']));
    });

    test('remove deletes the thread and its rows', () async {
      final db = await openDb();
      final store = storeOn(db);
      final root = _msg('r1', 'forsen');
      store.toggle(SavedThread.fromMessage(root, 'r1'), [root]);
      store.toggle(SavedThread.fromMessage(_msg('r2', 'forsen'), 'r2'), [
        _msg('r2', 'forsen'),
      ]);
      await store.flushIo();
      expect(store.remove('forsen', 'r1'), isTrue);
      await store.flushIo();

      expect((await db.savedThreads()).map((t) => t.rootId), ['r2']);
      expect(await rows(db, 'forsen', 'r1'), 0);
      expect(await rows(db, 'forsen', 'r2'), 1);
    });

    test('eviction past the cap deletes the evicted rows', () async {
      final db = await openDb();
      final store = storeOn(db);
      for (var i = 0; i < maxSavedThreads + 1; i++) {
        final m = _msg('r$i', 'forsen', seconds: i);
        store.toggle(SavedThread.fromMessage(m, 'r$i', now: m.timestamp), [m]);
      }
      await store.flushIo();
      expect(await db.savedThreads(), hasLength(maxSavedThreads));
      expect(await rows(db, 'forsen', 'r0'), 0);
    });

    test('a save during load survives the load', () async {
      final db = await openDb();
      final seed = storeOn(db);
      final root = _msg('r1', 'forsen');
      seed.toggle(SavedThread.fromMessage(root, 'r1'), [root]);
      seed.toggle(SavedThread.fromMessage(_msg('r9', 'forsen'), 'r9'));
      await seed.flushIo();

      final other = storeOn(db);
      final loading = other.load();
      other.toggle(SavedThread.fromMessage(_msg('r2', 'forsen'), 'r2'));
      await loading;
      await other.flushIo();
      expect(other.keys, {'forsen:r1', 'forsen:r2', 'forsen:r9'});

      final reloaded = storeOn(db);
      await reloaded.load();
      expect(reloaded.keys, {'forsen:r1', 'forsen:r2', 'forsen:r9'});
    });

    test('a large thread decodes off the isolate intact', () async {
      final db = await openDb();
      final store = storeOn(db);
      final log = [
        for (var i = 0; i < 300; i++)
          _msg('m$i', 'forsen', seconds: i, text: 'x' * 300),
      ];
      store.toggle(SavedThread.fromMessage(log.first, 'm0'), log);
      await store.flushIo();

      final other = storeOn(db);
      await other.load();
      final msgs = other.messagesFor('forsen', 'm0');
      expect(msgs, hasLength(300));
      expect(msgs.first.messageId, 'm299');
    });

    group('legacy JSON migration', () {
      File at(String name) => File('${legacy.path}/$name');

      Future<void> writeThread(String name, List<TwitchMessage> log) =>
          at(name).writeAsString(jsonEncode([for (final m in log) m.toJson()]));

      Future<void> writeLegacy() async {
        await legacy.create(recursive: true);
        final entries = [
          for (final id in ['a', 'b', 'c', 'd'])
            SavedThread.fromMessage(
              _msg(id, 'forsen', seconds: 1),
              id,
              now: _t0,
            ),
        ];
        await at(
          'index.json',
        ).writeAsString(jsonEncode([for (final e in entries) e.toJson()]));
        await writeThread('forsen__a.json', [
          _msg('a', 'forsen'),
          _msg('a1', 'forsen', rootId: 'a', seconds: 1),
        ]);
        // Truncated primary with a valid backup.
        await at('forsen__b.json').writeAsString('[{"login": "al');
        await writeThread('forsen__b.json.bak', [_msg('b', 'forsen')]);
        // Unreadable, no backup: the bookmark migrates with an empty log.
        await at('forsen__c.json').writeAsString('garbage');
        await writeThread('forsen__d.json', [_msg('d', 'forsen')]);
      }

      test(
        'imports everything readable once, then deletes the files',
        () async {
          await writeLegacy();
          final db = await openDb();

          final first = storeOn(db);
          await first.load();
          await first.flushIo();
          expect(first.keys, {'forsen:a', 'forsen:b', 'forsen:c', 'forsen:d'});
          expect(first.messagesFor('forsen', 'a'), hasLength(2));
          expect(
            first.messagesFor('forsen', 'b').single.messageId,
            'b',
            reason: 'backup file',
          );
          expect(first.messagesFor('forsen', 'c'), isEmpty);
          expect(legacy.existsSync(), isTrue, reason: 'kept for one launch');

          // Later edits to the files are ignored: the marker makes it a no-op.
          await at('index.json').writeAsString(
            jsonEncode([
              SavedThread.fromMessage(_msg('e', 'forsen'), 'e').toJson(),
            ]),
          );
          final second = storeOn(db);
          await second.load();
          await second.flushIo();
          expect(second.keys, first.keys);
          expect(await rows(db, 'forsen', 'a'), 2);
          expect(legacy.existsSync(), isFalse, reason: 'deleted next launch');

          final third = storeOn(db);
          await third.load();
          expect(third.keys, first.keys);
        },
      );

      test('an unreadable index is kept and never marked done', () async {
        await legacy.create(recursive: true);
        await at('index.json').writeAsString('garbage');
        final db = await openDb();

        final store = storeOn(db);
        await store.load();
        expect(store.threads, isEmpty);
        expect(at('index.json').existsSync(), isTrue);
        expect(await db.hasMeta('saved_threads_json_migrated'), isFalse);
      });

      test('with no database the files still load for the session', () async {
        await writeLegacy();
        final store = storeOn(null);
        await store.load();
        expect(store.keys, hasLength(4));
        expect(store.messagesFor('forsen', 'a'), hasLength(2));
        expect(legacy.existsSync(), isTrue);
      });
    });

    test('a version 1 archive keeps its blocks under the new schema', () async {
      final v1 = path();
      final old = await databaseFactoryFfi.openDatabase(
        v1,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE blocks(id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'channel TEXT NOT NULL, start_ts INTEGER NOT NULL, '
              'end_ts INTEGER NOT NULL, count INTEGER NOT NULL, '
              'data BLOB NOT NULL)',
            );
            // Retention runs on open and reads these.
            await db.execute(
              'CREATE TABLE pins(channel TEXT NOT NULL, '
              'start_ts INTEGER NOT NULL, end_ts INTEGER NOT NULL, '
              'kind TEXT NOT NULL)',
            );
            await db.execute(
              'CREATE TABLE minute_counts(channel TEXT NOT NULL, '
              'minute INTEGER NOT NULL, count INTEGER NOT NULL)',
            );
            await db.insert('blocks', {
              'channel': 'forsen',
              'start_ts': DateTime.now().millisecondsSinceEpoch,
              'end_ts': DateTime.now().millisecondsSinceEpoch,
              'count': 3,
              'data': Uint8List.fromList([1, 2, 3]),
            });
          },
        ),
      );
      await old.close();

      final db = await openDb();
      final blocks = await db.newestBlocks('forsen', 1);
      expect(blocks.single.count, 3);
      expect(blocks.single.data, [1, 2, 3]);
      expect(await db.savedThreads(), isEmpty);

      final store = storeOn(db);
      store.toggle(SavedThread.fromMessage(_msg('r1', 'forsen'), 'r1'));
      await store.flushIo();
      expect(await db.savedThreads(), hasLength(1));
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
