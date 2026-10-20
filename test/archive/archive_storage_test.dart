import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ermchat/archive/archive_block.dart';
import 'package:ermchat/archive/archive_row.dart';
import 'package:ermchat/archive/archive_users.dart';
import 'package:ermchat/color_utils.dart';
import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/models/twitch_badge.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/archive_adapter.dart';
import 'package:ermchat/services/archive_history_source.dart';
import 'package:ermchat/services/archive_reader.dart';
import 'package:ermchat/services/archive_store.dart';
import 'package:ermchat/services/archive_writer.dart';
import 'package:ermchat/util/chat_search.dart';
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
      decode: (blocks, keep) async => decodeBlocks(blocks, keep),
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

  test('user tables load back across id pages after a restart', () async {
    final path = _newPath();
    var store = await _open(path);
    final writer = _writer(store);
    // More chatters than one 5000-id page, with and without display names,
    // colors and extras.
    TwitchMessage msg(int i) => TwitchMessage(
      login: 'user$i',
      displayName: i % 3 == 0 ? 'User$i' : 'user$i',
      text: 'hi $i',
      messageId: _id(i),
      channel: _channel,
      userId: '${5000000 + i}',
      color: i % 4 == 0
          ? null
          : '#00FF${(i % 256).toRadixString(16).padLeft(2, '0')}',
      timestamp: _t0.add(Duration(seconds: i)),
      badges: [
        if (i.isEven) MessageBadge(setId: 'subscriber', versionId: '${i % 12}'),
      ],
    );
    const n = 12000;
    writer.add(_channel, msg(0));
    await writer.settled();
    for (var i = 1; i < n; i++) {
      writer.add(_channel, msg(i));
    }
    await writer.flush();
    await store.close();

    store = await _open(path);
    final rows = await _reader(store).newestRows(_channel, n);
    expect(rows.length, n);
    for (final i in [0, 1, 3, 4999, 5000, 5001, 9999, 11999]) {
      final want = msg(i);
      final got = rows[i];
      expect(
        (got.login, got.displayName, got.userId, got.color),
        (want.login, want.displayName, want.userId, want.color),
        reason: 'row $i read back with the wrong user',
      );
      expect(
        [for (final b in got.badges ?? const <MessageBadge>[]) b.versionId],
        [for (final b in want.badges ?? const <MessageBadge>[]) b.versionId],
      );
    }
    await store.close();
  });

  test('third-party emotes read back as they were stored', () async {
    final path = _newPath();
    var store = await _open(path);
    final writer = _writer(store);
    Emote cat(String code, {double aspect = 1.0}) => Emote(
      id: '01F6',
      code: code,
      meta: SevenTvMeta(baseName: 'catJAM', aspectRatio: aspect),
      scales: {EmoteScale.large: 'https://cdn.7tv.app/emote/01F6/4x.webp'},
      scope: EmoteScope.channel,
      isAnimated: true,
    );
    TwitchMessage msg(
      int i,
      String text,
      List<EmoteToken>? tokens, {
      bool partial = false,
    }) => _msg(i, tsMs: _t0.millisecondsSinceEpoch + i * 1000)
      ..text = text
      ..emoteTokens = tokens
      ..emotesPartial = partial;
    EmoteToken tok(Emote e, int start) => EmoteToken(
      emote: e,
      text: e.code,
      start: start,
      end: start + e.code.length,
    );
    writer.add(
      _channel,
      msg(0, 'catJAM hi catJAM', [
        tok(cat('catJAM', aspect: 1.5), 0),
        tok(cat('catJAM', aspect: 1.5), 10),
      ]),
    );
    // The channel later renamed the alias; both versions stay.
    writer.add(_channel, msg(1, 'vibe', [tok(cat('vibe'), 0)]));
    // Parsed before the catalogs landed: parses again on read.
    writer.add(_channel, msg(2, 'catJAM', const [], partial: true));
    // Parsed, nothing third-party: comes back parsed and empty.
    writer.add(_channel, msg(3, 'hello', const []));
    await writer.flush();
    await store.close();

    // A restart, with no emote catalog anywhere on the read side.
    store = await _open(path);
    final rows = await _reader(store).newestRows(_channel, 10);
    expect(rows, hasLength(4));
    List<(String, int, double, bool)>? shape(TwitchMessage m) => [
      for (final t in m.emoteTokens ?? const <EmoteToken>[])
        (t.emote!.code, t.start, t.emote!.aspectRatio, t.emote!.isAnimated),
    ];
    expect(shape(rows[0]), [
      ('catJAM', 0, 1.5, true),
      ('catJAM', 10, 1.5, true),
    ], reason: 'the emote as it was, without today\'s catalog');
    expect(shape(rows[1]), [('vibe', 0, 1.0, true)]);
    expect(rows[2].emoteTokens, isNull, reason: 'a partial parse re-parses');
    expect(rows[3].emoteTokens, isEmpty);
    await store.close();
  });

  test('a schema 3 archive upgrades and keeps its rows', () async {
    final path = _newPath();
    var store = await _open(path);
    var writer = _writer(store);
    writer.add(_channel, _msg(0));
    await writer.flush();
    await store.close();
    // Back to schema 3: no emote_defs table, no block upkeep flags, no edits.
    final db = await databaseFactoryFfi.openDatabase(path);
    await db.execute('DROP TABLE emote_defs');
    await db.execute('DROP TABLE edits');
    await db.execute('ALTER TABLE blocks DROP COLUMN refs');
    await db.execute('ALTER TABLE blocks DROP COLUMN stripped');
    await db.execute('DROP TABLE vocab');
    await db.execute('ALTER TABLE blocks DROP COLUMN words');
    await db.execute('ALTER TABLE blocks DROP COLUMN senders');
    await db.setVersion(3);
    await db.close();

    store = await _open(path);
    writer = _writer(store);
    writer.add(
      _channel,
      _msg(1)
        ..text = 'catJAM'
        ..emoteTokens = [
          EmoteToken(
            emote: const Emote(
              id: '01F6',
              code: 'catJAM',
              meta: SevenTvMeta(),
              scales: {
                EmoteScale.large: 'https://cdn.7tv.app/emote/01F6/4x.webp',
              },
            ),
            text: 'catJAM',
            start: 0,
            end: 6,
          ),
        ],
    );
    await writer.flush();
    final rows = await _reader(store).newestRows(_channel, 10);
    expect([for (final r in rows) r.messageId], [_id(0), _id(1)]);
    expect(rows[1].emoteTokens?.single.emote?.id, '01F6');
    await store.close();
  });

  test('compaction merges old small blocks and keeps every row', () async {
    // The clock sits two hours after the first rows.
    final store = await _open(
      _newPath(),
      now: () => _t0.add(const Duration(hours: 2)),
    );
    final timers = <_ManualTimer>[];
    final writer = _writer(store, timers: timers);
    var i = 0;
    Future<void> seal(int rows, {Duration at = Duration.zero}) async {
      for (var k = 0; k < rows; k++, i++) {
        writer.add(
          _channel,
          _msg(i, tsMs: _t0.add(at).millisecondsSinceEpoch + i * 1000),
        );
      }
      await writer.settled();
      if (rows < 256) timers.last.fire();
      await writer.settled();
    }

    // Old: 30 quiet seals of 5 rows, a full block, 3 more small ones.
    for (var k = 0; k < 30; k++) {
      await seal(5);
    }
    await seal(256);
    for (var k = 0; k < 3; k++) {
      await seal(5);
    }
    // Recent: small, but under an hour old.
    await seal(5, at: const Duration(minutes: 90));
    Future<List<String?>> ids() async => [
      for (final m in await _reader(store).newestRows(_channel, 10000))
        m.messageId,
    ];
    Future<int> blocks() async =>
        (await store.newestBlocks(_channel, 10000)).length;
    Future<int> bytes() async => [
      for (final b in await store.newestBlocks(_channel, 10000)) b.data.length,
    ].fold<int>(0, (a, b) => a + b);
    final rowsBefore = await ids();
    final bytesBefore = await bytes();
    final minutesBefore = await _reader(
      store,
    ).minuteCounts(_channel, _t0, _t0.add(const Duration(hours: 3)));
    expect(await blocks(), 35);

    // 30 small merge into one (29 gone); the full block stands apart; the
    // 3 after it merge (2 gone); the recent one waits.
    expect(await store.compact(_t0.add(const Duration(hours: 2))), 31);
    expect(await blocks(), 1 + 1 + 1 + 1);
    expect(await ids(), rowsBefore, reason: 'a row moved, went or doubled');
    expect(
      (await _reader(store).minuteCounts(
        _channel,
        _t0,
        _t0.add(const Duration(hours: 3)),
      )).map((m) => (m.minute, m.count)),
      minutesBefore.map((m) => (m.minute, m.count)),
    );
    expect(await bytes(), lessThan(bytesBefore));
    final rows = await _reader(store).newestRows(_channel, 10000);
    expect(rows.first.text, _msg(0).text);
    expect(rows.first.login, 'alice');
    expect(
      await store.compact(_t0.add(const Duration(hours: 2))),
      0,
      reason: 'a second pass finds nothing to merge',
    );
    await store.close();
  });

  group('id stripping', () {
    // 1500 rows in 256-row blocks; the newest reply points at row 10.
    Future<ArchiveStore> fill(String path) async {
      final store = await _open(path);
      final writer = _writer(store);
      writer.add(_channel, _msg(0));
      await writer.settled();
      for (var i = 1; i < 1500; i++) {
        final m = _msg(i);
        if (i == 1499) {
          m
            ..replyToParentId = _id(10)
            ..replyThreadRootId = _id(10);
        }
        writer.add(_channel, m);
      }
      await writer.flush();
      return store;
    }

    Future<List<TwitchMessage>> rows(ArchiveStore store) =>
        _reader(store).newestRows(_channel, 10000);

    test('drops ids past the newest 1000 rows, keeps reply parents', () async {
      final store = await fill(_newPath());
      final before = [
        for (final b in await store.newestBlocks(_channel, 10000))
          b.data.length,
      ].fold<int>(0, (a, b) => a + b);
      // Blocks of 256 from the newest: 220, 256, 256, 256 keep (988 rows
      // newer than the next), so only the oldest block is wholly past 1000.
      expect(
        await store.strip(_t0.add(const Duration(hours: 23))),
        0,
        reason: 'rows from the last day keep their ids',
      );
      expect(await store.strip(), 1);
      final all = await rows(store);
      expect(all, hasLength(1500), reason: 'stripping lost rows');
      for (var i = 0; i < 1500; i++) {
        final want = i < 256 && i != 10 ? null : _id(i);
        expect(all[i].messageId, want, reason: 'row $i');
      }
      expect(all.last.replyToParentId, _id(10));
      final after = [
        for (final b in await store.newestBlocks(_channel, 10000))
          b.data.length,
      ].fold<int>(0, (a, b) => a + b);
      expect(after, lessThan(before));
      expect(await store.strip(), 0, reason: 'stripping runs once per block');
      await store.close();
    });

    test('waits for older blocks\' references before stripping', () async {
      final path = _newPath();
      final store = await fill(path);
      // As sealed before references were recorded. A second connection, so
      // closing it leaves the store's open.
      final db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await db.execute('UPDATE blocks SET refs = 0');
      await db.execute('DELETE FROM ref_ids');
      await db.close();
      expect(await store.strip(), 0, reason: 'a reply parent could be lost');
      expect(await store.backfillRefs(), 6);
      expect(await store.strip(), 1);
      final all = await rows(store);
      expect(
        all[10].messageId,
        _id(10),
        reason: 'the reply parent kept its id',
      );
      expect(all[11].messageId, isNull);
      await store.close();
    });
  });

  group('search', () {
    // Blocks of 4 rows; one word per block says where it is.
    const texts = [
      'catJAM vibing', 'hello chat', 'nothing here', 'more nothing', //
      'gg wp', 'Neuro sama', 'filler', 'filler', //
      'catjam again', 'hello there', 'filler', 'filler', //
      'just filler', 'filler', 'filler', 'filler',
    ];

    Future<(ArchiveStore, ArchiveWriter)> fill(String path) async {
      final store = await _open(path);
      final writer = _writer(store, sealCount: 4);
      for (var i = 0; i < texts.length; i++) {
        writer.add(_channel, _msg(i)..text = texts[i]);
        if (i == 0) await writer.settled();
      }
      await writer.flush();
      return (store, writer);
    }

    List<String> textsOf(List<TwitchMessage> rows) => [
      for (final m in rows) m.text,
    ];

    test(
      'finds substrings of words, newest first, decoding only hits',
      () async {
        final (store, writer) = await fill(_newPath());
        var decoded = 0;
        final reader = ArchiveReader(
          Future.value(store),
          decode: (blocks, keep) async {
            decoded += blocks.length;
            return decodeBlocks(blocks, keep);
          },
          unsealed: writer.unsealed,
        );
        expect(textsOf(await reader.search(_channel, 'CAT')), [
          'catjam again',
          'catJAM vibing',
        ], reason: 'case-insensitive, inside a word, newest first');
        expect(decoded, 2, reason: 'blocks without the word were decoded');
        expect(textsOf(await reader.search(_channel, 'hello th')), [
          'hello there',
        ], reason: 'every word must be present, then the text must match');
        expect(await reader.search(_channel, 'zebra'), isEmpty);
        expect(await reader.search(_channel, '!!'), isEmpty);
        // Paging: the next page starts below the oldest row shown.
        final first = await reader.search(_channel, 'filler', limit: 3);
        expect(first, hasLength(3));
        final next = await reader.search(
          _channel,
          'filler',
          before: first.last.timestamp,
        );
        expect(
          [...first, ...next].map((m) => m.messageId).toSet(),
          hasLength(8),
          reason: 'pages overlapped or skipped a row',
        );
        // Rows still in the writer's tail are found too.
        writer.add(_channel, _msg(100)..text = 'catJAM fresh');
        await writer.settled();
        expect(
          textsOf(await reader.search(_channel, 'catjam')).first,
          'catJAM fresh',
        );
        await store.close();
      },
    );

    test('scopes match text, chatters or both; after pages forward', () async {
      final path = _newPath();
      final store = await _open(path);
      final writer = _writer(store, sealCount: 4);
      // 'neuro' as a word in one row, as a chatter in another.
      for (var i = 0; i < 12; i++) {
        final login = i == 9 ? 'neurofan' : 'alice';
        writer.add(
          _channel,
          _msg(i, login: login)..text = i == 2 ? 'neuro is live' : 'chat $i',
        );
        if (i == 0) await writer.settled();
      }
      await writer.flush();
      final reader = _reader(store);
      Future<List<String>> find(ChatSearchScope scope) async => [
        for (final m in await reader.search(_channel, 'NEURO', scope: scope))
          '${m.login}: ${m.text}',
      ];
      expect(await find(ChatSearchScope.messages), ['alice: neuro is live']);
      expect(await find(ChatSearchScope.chatters), ['neurofan: chat 9']);
      expect(await find(ChatSearchScope.all), [
        'neurofan: chat 9',
        'alice: neuro is live',
      ]);
      // Forward from row 5: the oldest matches first, newest-first order.
      final later = await reader.search(
        _channel,
        'chat',
        after: _msg(5).timestamp,
        limit: 3,
      );
      expect([for (final m in later) m.text], ['chat 7', 'chat 6', 'chat 5']);
      await store.close();
    });

    test('the search source pages through every match once', () async {
      final store = await _open(_newPath());
      final writer = _writer(store, sealCount: 16);
      for (var i = 0; i < 400; i++) {
        writer.add(_channel, _msg(i)..text = i % 3 == 0 ? 'pog $i' : 'chat');
        if (i == 0) await writer.settled();
      }
      await writer.flush();
      final source = ArchiveFindSource.search(
        _channel,
        _reader(store),
        query: 'pog',
        scope: ChatSearchScope.messages,
      );
      final w = HistoryWindow(now: source.now)..reset(await source.newest());
      expect(w.length, 100, reason: 'a page');
      while (w.prepend(await source.older(w[w.first].timestamp)) > 0) {}
      expect(
        [for (var p = w.first; p < w.end; p++) w[p].text],
        [for (var i = 0; i < 400; i += 3) 'pog $i'],
        reason: 'a match lost, repeated or out of order',
      );
      // Forward from the middle reaches the newest match.
      w.reset(await source.around(_msg(150).timestamp));
      while (w.append(await source.newer(w[w.end - 1].timestamp)) > 0) {}
      expect(w[w.end - 1].text, 'pog 399');
      await store.close();
    });

    test('a find across channels keeps the newest matches', () async {
      final store = await _open(_newPath());
      final writer = _writer(store, sealCount: 16);
      final t = _t0.millisecondsSinceEpoch;
      // 'other' posts every 20s, all matches: one block spans 300s.
      // [_channel] posts every second; its recent "meh" blocks pass the
      // index but match nothing, and its matches sit at 150..187s.
      for (var s = 0; s < 300; s++) {
        if (s % 20 == 0) {
          writer.add(
            'other',
            _msg(1000 + s, tsMs: t + s * 1000)..text = 'me $s',
          );
        }
        writer.add(
          _channel,
          _msg(s, tsMs: t + s * 1000)
            ..text = s >= 150 && s <= 187 ? 'me $s' : 'meh',
        );
        if (s == 0) await writer.settled();
      }
      writer.add('other', _msg(1300, tsMs: t + 300 * 1000)..text = 'me 300');
      await writer.flush();
      final found = await _reader(store).find(
        const ArchiveTerms(texts: ['me']),
        (m) => m.text.startsWith('me '),
        limit: 10,
      );
      expect(
        [for (final m in found) m.text],
        [
          for (var s = 300; s >= 200; s -= 20) 'me $s',
          for (var s = 187; s >= 184; s--) 'me $s',
        ],
        reason: 'a newer match in an undecoded block was skipped',
      );
      await store.close();
    });

    test('unindexed blocks are searched, then indexed', () async {
      final path = _newPath();
      final (store, _) = await fill(path);
      final db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await db.execute('UPDATE blocks SET words = NULL');
      await db.close();
      final reader = _reader(store);
      expect(textsOf(await reader.search(_channel, 'neuro')), ['Neuro sama']);
      expect(await store.backfillWords(), 4);
      expect(textsOf(await reader.search(_channel, 'neuro')), ['Neuro sama']);
      await store.close();
    });

    test('the vocabulary keeps its ids across a restart', () async {
      final path = _newPath();
      final (store, _) = await fill(path);
      await store.close();
      final again = await _open(path);
      final writer = _writer(again, sealCount: 4);
      // New words after the restart must not take ids the old ones hold.
      for (var i = 0; i < 4; i++) {
        writer.add(_channel, _msg(200 + i)..text = 'pogchamp $i');
        if (i == 0) await writer.settled();
      }
      await writer.flush();
      final reader = _reader(again);
      expect(textsOf(await reader.search(_channel, 'neuro')), ['Neuro sama']);
      expect(await reader.search(_channel, 'pogchamp'), hasLength(4));
      expect(textsOf(await reader.search(_channel, 'catjam')), [
        'catjam again',
        'catJAM vibing',
      ]);
      await again.close();
    });
  });

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
    final day = DateTime.utc(2026, 8, 6).millisecondsSinceEpoch;
    expect(
      [for (final p in await store.pins(_channel)) p.startTs],
      [day],
      reason: 'a pinned day reads back',
    );
    await store.removePin(
      _channel,
      day,
      DateTime.utc(2026, 8, 6, 23, 59).millisecondsSinceEpoch,
      'day',
    );
    expect(await store.pins(_channel), isEmpty);
    expect(
      await store.prune(now),
      1,
      reason: 'an unpinned day is pruned like any other',
    );
    await put(DateTime.utc(2026, 8, 2), DateTime.utc(2026, 8, 2, 1));
    now = now.add(const Duration(minutes: 30));
    expect(await store.pruneIfDue(), 0, reason: 'at most hourly');
    now = now.add(const Duration(minutes: 31));
    expect(await store.pruneIfDue(), 1);

    final hour = [
      for (final h in [1, 2, 3])
        DateTime.utc(2026, 9, 30, h).millisecondsSinceEpoch,
    ];
    for (final ts in hour) {
      await store.appendBlock(
        channel: 'busy',
        startTs: ts,
        endTs: ts + 1000,
        count: 0,
        data: Uint8List(1000),
        minutes: const {},
      );
    }
    await store.addPin('busy', hour[0], hour[0] + 1000, 'day');
    ArchiveStore.channelCapBytes = 1500;
    addTearDown(() => ArchiveStore.channelCapBytes = null);
    expect(await store.prune(now), 1, reason: 'one block past the cap');
    expect(
      [
        for (final b in await store.blocksAround('busy', hour[1], 10, 10))
          b.startTs,
      ],
      [hour[0], hour[2]],
      reason: 'the newest block and the pinned one stay under a cap',
    );
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
      // Rows sharing a millisecond may come in either order; the rest must
      // be in time order.
      List<int> times(HistoryWindow w) => [
        for (var p = w.first; p < w.end; p++)
          w[p].timestamp.millisecondsSinceEpoch,
      ];
      final sortedTimes = [for (var i = 0; i < 26; i++) ts(i)]..sort();

      final w = HistoryWindow(now: source.now)..reset(await source.newest());
      while (w.prepend(await source.older(w[w.first].timestamp)) > 0) {}
      expect(
        [for (var p = w.first; p < w.end; p++) w[p].messageId]..sort(),
        [...expected]..sort(),
        reason: 'walking older lost or repeated a row',
      );
      expect(times(w), sortedTimes, reason: 'walking older broke time order');

      w.reset(await source.around(_t0));
      while (w.append(await source.newer(w[w.end - 1].timestamp)) > 0) {}
      expect(
        [for (var p = w.first; p < w.end; p++) w[p].messageId]..sort(),
        [...expected]..sort(),
        reason: 'walking newer lost or repeated a row',
      );
      expect(times(w), sortedTimes, reason: 'walking newer broke time order');
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

  group('edits', () {
    test('a pending edit applies on read', () async {
      final store = await _open(_newPath());
      final writer = _writer(store, sealCount: 4);
      for (var i = 0; i < 8; i++) {
        writer.add(_channel, _msg(i));
      }
      await writer.flush();
      await store.addEdits(_channel, [_id(1)], ArchiveEdit.remove);
      await store.addEdits(_channel, [_id(2)], ArchiveEdit.deleted);

      final rows = await _reader(store).newestRows(_channel, 100);
      expect(
        [for (final m in rows) m.messageId],
        [
          for (final i in [0, 2, 3, 4, 5, 6, 7]) _id(i),
        ],
        reason: 'the removed row is gone',
      );
      expect(
        rows.firstWhere((m) => m.messageId == _id(2)).deleted,
        isTrue,
        reason: 'the deleted row keeps its place',
      );
      await store.close();
    });

    test('upkeep bakes pending edits and clears the table', () async {
      final store = await _open(_newPath());
      final writer = _writer(store, sealCount: 4);
      for (var i = 0; i < 8; i++) {
        writer.add(_channel, _msg(i));
      }
      await writer.flush();
      await store.addEdits(_channel, [_id(1)], ArchiveEdit.remove);
      await store.addEdits(_channel, [_id(2)], ArchiveEdit.deleted);
      // An id no block holds must not keep the table alive.
      await store.addEdits(_channel, [_id(99)], ArchiveEdit.deleted);

      final counts = [
        for (final b in await store.newestBlocks(_channel, 100)) b.count,
      ].fold<int>(0, (a, b) => a + b);
      final minutes = await _reader(
        store,
      ).minuteCounts(_channel, _t0, _t0.add(const Duration(hours: 1)));
      final minutesBefore = minutes.fold<int>(0, (n, m) => n + m.count);
      expect(await store.bakeEdits(), 2, reason: 'two ids were in blocks');
      expect(await store.edits(_channel), isEmpty, reason: 'the table cleared');
      expect(
        [
          for (final b in await store.newestBlocks(_channel, 100)) b.count,
        ].fold<int>(0, (a, b) => a + b),
        counts - 1,
        reason: 'the removed row left the block count',
      );
      expect(
        (await _reader(store).minuteCounts(
          _channel,
          _t0,
          _t0.add(const Duration(hours: 1)),
        )).fold<int>(0, (n, m) => n + m.count),
        minutesBefore - 1,
        reason: 'the removed row left its minute bucket',
      );
      // No pending edit remains, so a read shows the baked block itself.
      final rows = await _reader(store).newestRows(_channel, 100);
      expect(rows.any((m) => m.messageId == _id(1)), isFalse);
      expect(rows.firstWhere((m) => m.messageId == _id(2)).deleted, isTrue);
      expect(await store.bakeEdits(), 0, reason: 'nothing left to bake');

      await store.addEdits(_channel, [
        for (var i = 4; i < 8; i++) _id(i),
      ], ArchiveEdit.remove);
      await store.bakeEdits();
      expect(
        await store.newestBlocks(_channel, 100),
        hasLength(1),
        reason: 'a block emptied by edits is deleted',
      );
      await store.close();
    });

    test('baking keeps an edit for an id the writer still holds', () async {
      final store = await _open(_newPath());
      final writer = _writer(store);
      writer.add(_channel, _msg(0));
      await writer.flush();
      await store.addEdits(_channel, [_id(99)], ArchiveEdit.deleted);

      expect(
        await store.bakeEdits(held: (_) => {_id(99)}),
        0,
        reason: 'a held id was baked',
      );
      expect(
        await store.edits(_channel),
        hasLength(1),
        reason: 'a sealing id was cleared',
      );
      expect(await store.bakeEdits(held: (_) => const {}), 0);
      expect(
        await store.edits(_channel),
        isEmpty,
        reason: 'an unheld, absent id must clear',
      );
      await store.close();
    });

    test('an id in a seal still writing is not cleared', () async {
      final store = await _open(_newPath());
      final gate = Completer<void>();
      final writer = ArchiveWriter(
        Future.value(store),
        sealCount: 2,
        encode: (rows) async {
          await gate.future;
          return ArchiveBlock.encode(rows);
        },
      );
      // Warm the tables, then a second row seals both into a block.
      writer.add(_channel, _msg(0));
      await writer.settled();
      writer.add(_channel, _msg(1));
      // Let the seal reach the encoder, so the rows live only in the seal.
      await Future<void>.delayed(Duration.zero);
      await writer.recordEdits(_channel, [_id(1)], ArchiveEdit.deleted);
      expect(
        await store.edits(_channel),
        hasLength(1),
        reason: 'a sealing row must take a store edit',
      );
      await store.bakeEdits(held: writer.heldIds);
      expect(
        await store.edits(_channel),
        hasLength(1),
        reason: 'the edit for a sealing row was cleared before it committed',
      );
      gate.complete();
      await writer.settled();
      await store.close();
    });

    test('an edit on a row still in the tail changes it there', () async {
      final store = await _open(_newPath());
      final writer = _writer(store);
      for (var i = 0; i < 3; i++) {
        writer.add(_channel, _msg(i));
      }
      await writer.settled();
      await writer.recordEdits(_channel, [_id(1)], ArchiveEdit.remove);
      await writer.recordEdits(_channel, [_id(2)], ArchiveEdit.deleted);
      expect(
        [for (final m in writer.unsealed(_channel)) m.messageId],
        [_id(0), _id(2)],
        reason: 'the removed tail row left before any seal',
      );
      expect(writer.unsealed(_channel).last.deleted, isTrue);
      await writer.flush();
      expect(
        await store.edits(_channel),
        isEmpty,
        reason: 'a tail row needs no store edit',
      );
      final rows = await _reader(store).newestRows(_channel, 10);
      expect([for (final m in rows) m.messageId], [_id(0), _id(2)]);
      expect(rows.last.deleted, isTrue);
      await store.close();
    });

    test('a schema 6 archive upgrades and takes edits', () async {
      final path = _newPath();
      var store = await _open(path);
      final writer = _writer(store);
      writer.add(_channel, _msg(0));
      await writer.flush();
      await store.close();
      // Back to schema 6: no edits table.
      final db = await databaseFactoryFfi.openDatabase(path);
      await db.execute('DROP TABLE edits');
      await db.setVersion(6);
      await db.close();

      store = await _open(path);
      await store.addEdits(_channel, [_id(0)], ArchiveEdit.deleted);
      final rows = await _reader(store).newestRows(_channel, 10);
      expect(rows.single.deleted, isTrue, reason: 'the migrated table works');
      await store.close();
    });
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
