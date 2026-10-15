import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ermchat/archive/archive_block.dart';
import 'package:ermchat/archive/archive_users.dart';
import 'package:ermchat/color_utils.dart';
import 'package:ermchat/models/twitch_badge.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/archive_adapter.dart';
import 'package:ermchat/services/archive_history_source.dart';
import 'package:ermchat/services/archive_reader.dart';
import 'package:ermchat/services/archive_store.dart';
import 'package:ermchat/services/archive_writer.dart';
import 'package:ermchat/util/history_window.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _channel = 'somechannel';
final _t0 = DateTime.utc(2026, 10, 1, 12);

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

String _id(int i) =>
    '${i.toRadixString(16).padLeft(8, '0')}-0b7d-4c55-9a10-6d2e8f4b7a01';

TwitchMessage _msg(int i, {String login = 'alice', int? tsMs}) => TwitchMessage(
  login: login,
  text: 'message number $i',
  messageId: _id(i),
  channel: _channel,
  userId: '${1000 + login.length}',
  color: '#FF4500',
  timestamp: tsMs == null
      ? _t0.add(Duration(seconds: i))
      : DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true),
);

late Directory _dir;
int _dbCount = 0;

String _newPath() => '${_dir.path}/archive_${_dbCount++}.db';

Future<ArchiveStore> _open(String path, {DateTime Function()? now}) =>
    ArchiveStore.open(path, factory: databaseFactoryFfi, now: now);

ArchiveWriter _writer(
  ArchiveStore store, {
  int sealCount = 256,
  List<_ManualTimer>? timers,
}) => ArchiveWriter(
  Future.value(store),
  sealCount: sealCount,
  createTimer: (d, cb) {
    final t = _ManualTimer(cb);
    timers?.add(t);
    return t;
  },
  encode: (rows) async => ArchiveBlock.encode(rows),
);

ArchiveReader _reader(ArchiveStore store, {ArchiveWriter? writer}) =>
    ArchiveReader(
      Future.value(store),
      decode: (blocks) async => decodeBlocks(blocks),
      unsealed: writer?.unsealed ?? (_) => const [],
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    _dir = Directory.systemTemp.createTempSync('archive_test_');
  });

  tearDownAll(() => _dir.deleteSync(recursive: true));

  test('adapter round trips a realistic message set', () {
    final set = <TwitchMessage>[
      TwitchMessage(
        login: 'alice',
        displayName: 'Alice',
        text: 'hello Kappa world LUL',
        messageId: _id(1),
        channel: _channel,
        userId: '4242',
        color: '#1E90FF',
        timestamp: _t0,
        badges: const [
          MessageBadge(setId: 'subscriber', versionId: '12'),
          MessageBadge(setId: 'premium', versionId: '1'),
        ],
        isFirstMessage: true,
        msgId: 'highlighted-message',
        emotePositions: const [
          EmotePosition(
            emoteId: '25',
            startIndex: 6,
            endIndex: 11,
            emoteCode: 'Kappa',
          ),
          EmotePosition(
            emoteId: '425618',
            startIndex: 18,
            endIndex: 21,
            emoteCode: 'LUL',
          ),
        ],
      ),
      TwitchMessage(
        login: 'bob',
        text: 'agreed',
        messageId: _id(2),
        channel: _channel,
        userId: '77',
        color: '#008000',
        timestamp: _t0.add(const Duration(seconds: 1)),
        replyToParentId: _id(1),
        replyToUser: 'Alice',
        replyToText: 'hello Kappa world LUL',
        replyThreadRootId: _id(1),
      ),
      TwitchMessage(
        login: 'carol',
        text: 'waves',
        isAction: true,
        deleted: true,
        bitsAmount: 100,
        pinnedPaidAmount: '5.00',
        customRewardId: _id(9),
        sourceBroadcasterId: '555',
        sourceMessageId: _id(8),
        messageId: _id(3),
        channel: _channel,
        timestamp: _t0.add(const Duration(seconds: 2)),
        gifAttachments: const [
          GifAttachment(
            gifId: 'g1',
            url: 'https://media.example/g1.gif',
            startIndex: 0,
            endIndex: 5,
          ),
        ],
      ),
      TwitchMessage(
        login: 'twitch',
        text: 'dave subscribed for 5 months',
        isSystem: true,
        systemAccent: const Color(0xFF9146FF),
        channel: _channel,
        timestamp: _t0.add(const Duration(seconds: 3)),
      ),
      TwitchMessage(
        login: 'erin',
        text: 'redeemed Hydrate',
        isSystem: true,
        redemptionImageUrl: 'https://static.example/hydrate.png',
        redemptionPoints: 500,
        isBackfill: true,
        isHistory: true,
        isBanNotice: false,
        channel: _channel,
        timestamp: _t0.add(const Duration(seconds: 4)),
      ),
    ];
    final adapter = ArchiveAdapter(UserTables());
    final rows = [for (final m in set) adapter.toRow(m)];
    final decoded = ArchiveBlock.decode(ArchiveBlock.encode(rows));
    for (var i = 0; i < set.length; i++) {
      final back = adapter.fromRow(decoded[i], _channel);
      expect(back.toJson(), set[i].toJson(), reason: 'message $i');
    }
    expect(
      adapter.users.whos.length,
      set.length,
      reason: 'one who per distinct user',
    );
    expect(
      adapter.fromRow(decoded[0], _channel, asHistory: true).isHistory,
      true,
    );
  });

  test('writer seals on count', () async {
    final store = await _open(_newPath());
    final writer = _writer(store);
    for (var i = 0; i < 255; i++) {
      writer.add(_channel, _msg(i));
    }
    await writer.settled();
    expect(
      await store.newestBlocks(_channel, 1000),
      isEmpty,
      reason: '255 rows stay in the tail',
    );
    writer.add(_channel, _msg(255));
    await writer.settled();
    final blocks = await store.newestBlocks(_channel, 1000);
    expect(blocks.single.count, 256);
    final minutes = await _reader(
      store,
    ).minuteCounts(_channel, _t0, _t0.add(const Duration(hours: 1)));
    expect(minutes.fold<int>(0, (n, m) => n + m.count), 256);
    await store.close();
  });

  test(
    'writer seals on time and restarts the timer for the next tail',
    () async {
      final store = await _open(_newPath());
      final timers = <_ManualTimer>[];
      final writer = _writer(store, timers: timers);
      for (var i = 0; i < 3; i++) {
        writer.add(_channel, _msg(i));
      }
      await writer.settled();
      expect(timers.length, 1, reason: 'one timer per tail, not per message');
      expect(await store.newestBlocks(_channel, 10), isEmpty);
      timers.single.fire();
      await writer.settled();
      expect((await store.newestBlocks(_channel, 10)).single.count, 3);
      writer.add(_channel, _msg(3));
      await writer.settled();
      expect(timers.length, 2, reason: 'a new tail arms a new timer');
      await store.close();
    },
  );

  test(
    'a kill loses only the unsealed tail and sealed blocks survive',
    () async {
      final path = _newPath();
      var store = await _open(path);
      expect(await store.journalMode(), 'wal');
      var writer = _writer(store);
      for (var i = 0; i < 300; i++) {
        writer.add(_channel, _msg(i, login: i.isEven ? 'alice' : 'bobby'));
      }
      await writer.settled();
      // Kill: no flush, no dispose, the 44-row tail is gone.
      await store.close();

      store = await _open(path);
      final rows = await _reader(store).newestRows(_channel, 1000);
      expect(rows.length, 256, reason: 'only the sealed block remains');
      expect(
        [for (final r in rows) r.messageId],
        [for (var i = 0; i < 256; i++) _id(i)],
      );
      expect(
        rows[1].login,
        'bobby',
        reason: 'user rows survived with the block',
      );

      writer = _writer(store);
      writer.add(_channel, _msg(1000, login: 'carol'));
      await writer.flush();
      final all = await _reader(store).newestRows(_channel, 1000);
      expect(all.length, 257);
      expect(
        all.last.login,
        'carol',
        reason: 'new users continue the saved table ids',
      );
      expect(all[255].login, 'bobby');
      await store.close();
    },
  );

  test('a message id is stored once, also across a restart', () async {
    final path = _newPath();
    var store = await _open(path);
    var writer = _writer(store, sealCount: 4);
    for (final i in [1, 2, 2, 3, 1, 4]) {
      writer.add(_channel, _msg(i));
    }
    await writer.flush();
    expect((await _reader(store).newestRows(_channel, 100)).length, 4);

    writer = _writer(store, sealCount: 4);
    writer.add(_channel, _msg(3));
    writer.add(_channel, _msg(5));
    await writer.flush();
    final ids = [
      for (final m in await _reader(store).newestRows(_channel, 100))
        m.messageId,
    ];
    expect(ids, [
      for (final i in [1, 2, 3, 4, 5]) _id(i),
    ], reason: 'robotty repeat of 3');
    await store.close();
  });

  test('retention keeps pinned ranges and recent blocks', () async {
    var now = DateTime.utc(2026, 10, 1);
    final store = await _open(_newPath(), now: () => now);
    final data = ArchiveBlock.encode(const []);
    Future<void> put(DateTime start, DateTime end) => store.appendBlock(
      channel: _channel,
      startTs: start.millisecondsSinceEpoch,
      endTs: end.millisecondsSinceEpoch,
      count: 0,
      data: data,
      minutes: {start.millisecondsSinceEpoch ~/ 60000: 1},
    );
    await put(DateTime.utc(2026, 8, 1), DateTime.utc(2026, 8, 1, 1));
    await put(DateTime.utc(2026, 8, 5), DateTime.utc(2026, 8, 5, 1));
    await put(DateTime.utc(2026, 8, 5, 22), DateTime.utc(2026, 8, 6, 2));
    await put(DateTime.utc(2026, 9, 25), DateTime.utc(2026, 9, 25, 1));
    await store.addPin(
      _channel,
      DateTime.utc(2026, 8, 6).millisecondsSinceEpoch,
      DateTime.utc(2026, 8, 6, 23, 59).millisecondsSinceEpoch,
      'day',
    );

    now = DateTime.utc(2026, 10, 1);
    expect(await store.prune(now), 2);
    final left = await store.blocksAround(
      _channel,
      DateTime.utc(2026, 9, 25).millisecondsSinceEpoch,
      10,
      10,
    );
    expect(
      [
        for (final b in left)
          DateTime.fromMillisecondsSinceEpoch(b.startTs, isUtc: true),
      ],
      [DateTime.utc(2026, 8, 5, 22), DateTime.utc(2026, 9, 25)],
      reason: 'the block overlapping the pinned day survives',
    );
    await store.putStream(
      channel: _channel,
      id: 'old',
      startedTs: DateTime.utc(2026, 8, 1).millisecondsSinceEpoch,
    );
    await store.endStream(
      'old',
      DateTime.utc(2026, 8, 1, 3).millisecondsSinceEpoch,
    );
    await store.putStream(
      channel: _channel,
      id: 'live',
      startedTs: DateTime.utc(2026, 8, 1).millisecondsSinceEpoch,
    );
    await store.prune(now);
    expect(
      [for (final s in await store.streams(_channel, 0)) s.id],
      ['live'],
      reason: 'an ended broadcast past retention goes, a live one stays',
    );
    await store.endStream('live', now.millisecondsSinceEpoch);
    expect(
      await store.putStream(channel: _channel, id: 'live', startedTs: 0),
      isTrue,
      reason: 'a reopen is a change open pages must reload for',
    );
    expect(
      (await store.streams(_channel, 0)).single.endedTs,
      isNull,
      reason: 'an ended id seen live again reopens',
    );
    expect(
      await store.putStream(channel: _channel, id: 'live', startedTs: 0),
      isFalse,
      reason: 'a poll of a live stream changes nothing',
    );
    await put(DateTime.utc(2026, 8, 2), DateTime.utc(2026, 8, 2, 1));
    now = now.add(const Duration(minutes: 30));
    expect(await store.pruneIfDue(), 0, reason: 'at most hourly');
    now = now.add(const Duration(minutes: 31));
    expect(await store.pruneIfDue(), 1);
    await store.close();
  });

  test('reader returns rows in order across blocks and skips damage', () async {
    final store = await _open(_newPath());
    final writer = _writer(store, sealCount: 4);
    for (var i = 0; i < 10; i++) {
      // Row 5 arrives with an older timestamp than row 4.
      writer.add(
        _channel,
        _msg(i, tsMs: _t0.millisecondsSinceEpoch + (i == 5 ? 3500 : i * 1000)),
      );
    }
    await writer.flush();
    final reader = _reader(store);

    final newest = await reader.newestRows(_channel, 7);
    expect(
      [for (final m in newest) m.messageId],
      [
        for (final i in [3, 5, 4, 6, 7, 8, 9]) _id(i),
      ],
      reason: 'timestamp order across blocks, 5 sorts before 4',
    );
    expect(newest.every((m) => m.isHistory), true);

    final around = await reader.blocksAround(
      _channel,
      _t0.add(const Duration(seconds: 5)),
      before: 1,
      after: 1,
    );
    expect(around.length, 3);
    expect([for (final b in around) b.rows.length], [4, 4, 2]);
    expect(around[1].rows.first.messageId, _id(5));
    final one = await reader.blockAt(_channel, around[2].key);
    expect(one!.rows.map((m) => m.messageId), [_id(8), _id(9)]);
    expect(await reader.blockAt(_channel, 99999), isNull);

    await store.appendBlock(
      channel: _channel,
      startTs: _t0.millisecondsSinceEpoch + 20000,
      endTs: _t0.millisecondsSinceEpoch + 21000,
      count: 2,
      data: Uint8List.fromList([1, 2, 3]),
      minutes: const {},
    );
    final all = await reader.blocksAround(_channel, _t0, before: 0, after: 10);
    expect(all.length, 3, reason: 'the damaged block is skipped');
    await store.close();
  });

  test(
    'paging the archive both ways yields every row once, in order',
    () async {
      final store = await _open(_newPath());
      final writer = _writer(store, sealCount: 5);
      // Rows 10-12 share one millisecond and straddle a block seam; row 21
      // arrives late with an older timestamp, so two blocks overlap in time.
      int ts(int i) =>
          _t0.millisecondsSinceEpoch +
          (i >= 10 && i <= 12 ? 10000 : (i == 21 ? 14500 : i * 1000));
      for (var i = 0; i < 23; i++) {
        writer.add(_channel, _msg(i, tsMs: ts(i)));
      }
      await writer.flush();
      // Rows 23-25 stay in the writer's tail, not yet in any block.
      for (var i = 23; i < 26; i++) {
        writer.add(_channel, _msg(i, tsMs: ts(i)));
      }
      await writer.settled();
      final source = ArchiveHistorySource(
        _channel,
        _reader(store, writer: writer),
        now: () => _t0.add(const Duration(hours: 1)),
      );
      final expected = [
        for (final i in [
          for (var i = 0; i < 26; i++) i,
        ]..sort((a, b) => ts(a).compareTo(ts(b))))
          _id(i),
      ];

      final w = HistoryWindow(now: source.now)..reset(await source.newest());
      while (w.prepend(await source.older(w[w.first].timestamp)) > 0) {}
      expect(
        [for (var p = w.first; p < w.end; p++) w[p].messageId]..sort(),
        [...expected]..sort(),
        reason: 'walking older lost or repeated a row',
      );

      w.reset(await source.around(_t0));
      while (w.append(await source.newer(w[w.end - 1].timestamp)) > 0) {}
      expect(
        [for (var p = w.first; p < w.end; p++) w[p].messageId]..sort(),
        [...expected]..sort(),
        reason: 'walking newer lost or repeated a row',
      );
      await store.close();
    },
  );

  test('moderation after a seal shows on read, scoped to its rows', () async {
    final store = await _open(_newPath());
    final writer = _writer(store, sealCount: 4);
    for (var i = 0; i < 8; i++) {
      writer.add(_channel, _msg(i, login: i.isEven ? 'troll' : 'alice'));
    }
    await writer.flush();
    // A ban covering rows 0-5 and a single delete of alice's row 7.
    await store.addModeration(
      _channel,
      'troll',
      _t0.millisecondsSinceEpoch,
      _t0.add(const Duration(seconds: 5)).millisecondsSinceEpoch,
    );
    await store.addModeration(
      _channel,
      'alice',
      _t0.add(const Duration(seconds: 7)).millisecondsSinceEpoch,
      _t0.add(const Duration(seconds: 7)).millisecondsSinceEpoch,
    );
    final rows = await _reader(
      store,
    ).rowsNear(_channel, _t0, before: 0, after: 4);
    expect(
      [
        for (final m in rows)
          if (m.deleted) m.text.split(' ').last,
      ],
      ['0', '2', '4', '7'],
      reason: 'row 6 is after the ban; alice rows 1-5 were never deleted',
    );
    await store.close();
  });

  test('block encode, write and read timings', () async {
    final store = await _open(_newPath());
    final writer = ArchiveWriter(Future.value(store));
    final reader = ArchiveReader(Future.value(store));
    final rows = Stopwatch()..start();
    for (var i = 0; i < 256; i++) {
      writer.add(_channel, _msg(i, login: 'user${i % 40}'));
    }
    await writer.flush();
    final write = rows.elapsedMilliseconds;
    rows.reset();
    final read = await reader.newestRows(_channel, 256);
    final readMs = rows.elapsedMilliseconds;
    expect(read.length, 256);
    // ignore: avoid_print
    print(
      '256 rows: seal (isolate encode + write) ${write}ms, read ${readMs}ms',
    );
    await store.close();
  });
}
