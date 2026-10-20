import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../archive/archive_block.dart';
import '../archive/archive_io.dart';
import '../archive/archive_row.dart';
import '../archive/archive_users.dart';
import '../archive/archive_words.dart';
import '../util/log.dart';

/// One sealed block as stored: metadata plus the packed `ArchiveBlock` bytes.
class StoredBlock {
  const StoredBlock({
    required this.key,
    required this.startTs,
    required this.endTs,
    required this.count,
    required this.data,
  });

  /// Stable row id; the handle for `blockAt`.
  final int key;
  final int startTs;
  final int endTs;
  final int count;
  final Uint8List data;
}

/// A saved thread's bookmark row.
class StoredThread {
  const StoredThread({
    required this.channel,
    required this.rootId,
    required this.login,
    required this.author,
    required this.preview,
    required this.savedAtMs,
  });

  final String channel;
  final String rootId;
  final String login;
  final String author;
  final String preview;
  final int savedAtMs;
}

/// One encoded message of a saved thread.
class StoredThreadMessage {
  const StoredThreadMessage({
    required this.channel,
    required this.rootId,
    required this.messageId,
    required this.ts,
    required this.data,
  });

  final String channel;
  final String rootId;
  final String messageId;
  final int ts;
  final Uint8List data;
}

class _ChannelTables {
  _ChannelTables(this.tables)
    : whoSaved = tables.nextWho,
      lookSaved = tables.nextLook,
      stateSaved = tables.nextState;

  final UserTables tables;
  int whoSaved;
  int lookSaved;
  int stateSaved;
}

/// SQLite persistence for the history archive: sealed blocks, per-channel
/// user tables, minute counts, pins, and retention. Pure storage; encoding
/// and decoding happen in the writer and reader.
///
/// User tables are rows keyed by (channel, id) and only appended, in the same
/// transaction as the block that first references them, so a crash never
/// leaves a block pointing at an unsaved user. Statements avoid UPSERT and
/// row values so old platform SQLite builds work.
class ArchiveStore {
  ArchiveStore._(this._db, this._now);

  static const int schemaVersion = 9;
  static const Duration defaultRetention = Duration(days: 30);

  /// How long chat stays before pruning. The History settings set it, and
  /// the history views read it for the range they offer.
  static Duration retention = defaultRetention;

  /// Block bytes one channel may keep, or null for no cap. Pruning deletes
  /// a channel's oldest blocks past it. The History settings set it.
  static int? channelCapBytes;
  static const Duration pruneEvery = Duration(hours: 1);

  final Database _db;
  final DateTime Function() _now;
  final Map<String, Future<_ChannelTables>> _tables = {};
  DateTime? _lastPrune;

  /// Opens (creating if needed) the archive at [path] and prunes once.
  static Future<ArchiveStore> open(
    String path, {
    DatabaseFactory? factory,
    DateTime Function()? now,
  }) async {
    final db = await (factory ?? databaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA auto_vacuum=INCREMENTAL');
          await db.rawQuery('PRAGMA journal_mode=WAL');
          await db.execute('PRAGMA synchronous=NORMAL');
          await db.rawQuery('PRAGMA journal_size_limit=$_walLimit');
        },
        onCreate: (db, version) => _create(db),
        // Version 9 records when moderation happened, for VOD replay.
        onUpgrade: (db, from, to) async {
          if (from < 9) {
            await db.execute('ALTER TABLE moderation ADD COLUMN at_ts INTEGER');
          }
        },
      ),
    );
    final store = ArchiveStore._(db, now ?? DateTime.now);
    await store.pruneIfDue();
    return store;
  }

  static Future<void> _create(Database db) async {
    const statements = [
      '''CREATE TABLE blocks(
           id INTEGER PRIMARY KEY AUTOINCREMENT,
           channel TEXT NOT NULL,
           start_ts INTEGER NOT NULL,
           end_ts INTEGER NOT NULL,
           count INTEGER NOT NULL,
           data BLOB NOT NULL)''',
      'CREATE INDEX blocks_by_start ON blocks(channel, start_ts, id)',
      'CREATE INDEX blocks_by_end ON blocks(channel, end_ts)',
      '''CREATE TABLE users(
           channel TEXT NOT NULL, id INTEGER NOT NULL,
           user_id TEXT NOT NULL, login TEXT NOT NULL, display_name TEXT,
           PRIMARY KEY(channel, id)) WITHOUT ROWID''',
      '''CREATE TABLE looks(
           channel TEXT NOT NULL, id INTEGER NOT NULL,
           color TEXT, badges TEXT NOT NULL, extra TEXT,
           PRIMARY KEY(channel, id)) WITHOUT ROWID''',
      '''CREATE TABLE user_states(
           channel TEXT NOT NULL, id INTEGER NOT NULL,
           who INTEGER NOT NULL, look INTEGER NOT NULL,
           PRIMARY KEY(channel, id)) WITHOUT ROWID''',
      '''CREATE TABLE ref_ids(
           channel TEXT NOT NULL, message_id TEXT NOT NULL,
           PRIMARY KEY(channel, message_id)) WITHOUT ROWID''',
      '''CREATE TABLE streams(
           stream_id TEXT PRIMARY KEY,
           channel TEXT NOT NULL,
           started_at INTEGER NOT NULL,
           ended_at INTEGER,
           title TEXT, game TEXT, vod_id TEXT)''',
      'CREATE INDEX streams_by_channel ON streams(channel, started_at)',
      '''CREATE TABLE minute_counts(
           channel TEXT NOT NULL, minute INTEGER NOT NULL,
           count INTEGER NOT NULL,
           PRIMARY KEY(channel, minute)) WITHOUT ROWID''',
      '''CREATE TABLE pins(
           channel TEXT NOT NULL,
           start_ts INTEGER NOT NULL, end_ts INTEGER NOT NULL,
           kind TEXT NOT NULL,
           PRIMARY KEY(channel, start_ts, end_ts, kind))''',
    ];
    for (final sql in statements) {
      await db.execute(sql);
    }
    await _createThreads(db);
    await _createModeration(db);
    await _createEmoteDefs(db);
    await _addBlockFlags(db);
    await _createSearchIndex(db);
    await _createEdits(db);
    await _addUpkeepColumns(db);
  }

  /// Per block: the user states its rows name (`states`), so pruning the user
  /// tables reads small lists. Per reply root: the time of the newest reply
  /// to it (`ts`), so the reference ages out with that reply.
  static Future<void> _addUpkeepColumns(Database db) async {
    await db.execute('ALTER TABLE blocks ADD COLUMN states BLOB');
    await db.execute(
      'ALTER TABLE ref_ids ADD COLUMN ts INTEGER NOT NULL DEFAULT 0',
    );
  }

  /// Saved threads live in their own tables, so block retention never
  /// touches them. One row per message keeps an append a small insert.
  static Future<void> _createThreads(Database db) async {
    const statements = [
      '''CREATE TABLE saved_threads(
           channel TEXT NOT NULL, root_id TEXT NOT NULL,
           login TEXT NOT NULL, author TEXT NOT NULL, preview TEXT NOT NULL,
           saved_at INTEGER NOT NULL,
           PRIMARY KEY(channel, root_id)) WITHOUT ROWID''',
      '''CREATE TABLE thread_messages(
           channel TEXT NOT NULL, root_id TEXT NOT NULL,
           message_id TEXT NOT NULL, ts INTEGER NOT NULL, data BLOB NOT NULL,
           PRIMARY KEY(channel, root_id, message_id)) WITHOUT ROWID''',
    ];
    for (final sql in statements) {
      await db.execute(sql);
    }
  }

  /// Deletes that land after their rows sealed. Blocks never change, so a
  /// read applies these on decode; the table stays empty for channels
  /// without late moderation. A null login clears every chatter.
  static Future<void> _createModeration(Database db) async {
    await db.execute('''CREATE TABLE moderation(
           channel TEXT NOT NULL, login TEXT,
           from_ts INTEGER NOT NULL, to_ts INTEGER NOT NULL, at_ts INTEGER)''');
    await db.execute(
      'CREATE INDEX moderation_by_end ON moderation(channel, to_ts)',
    );
  }

  /// Third-party emotes as they were when first archived, so history shows
  /// an emote after its set drops or renames it. Written once per key
  /// ([ArchiveToken.key]) and never pruned: a channel uses thousands at most.
  static Future<void> _createEmoteDefs(Database db) =>
      db.execute('''CREATE TABLE emote_defs(
         channel TEXT NOT NULL, key TEXT NOT NULL, json TEXT NOT NULL,
         PRIMARY KEY(channel, key)) WITHOUT ROWID''');

  /// Per block: `refs` once its reply parent and root ids are in `ref_ids`
  /// (at seal), and `stripped` once its message ids are gone ([strip]).
  static Future<void> _addBlockFlags(Database db) async {
    await db.execute(
      'ALTER TABLE blocks ADD COLUMN refs INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE blocks ADD COLUMN stripped INTEGER NOT NULL DEFAULT 0',
    );
  }

  /// The search index: a vocabulary shared by every channel, stored as
  /// deflated runs of new words (`first` is the id of a run's first word),
  /// and per block the ids of the words it holds (`blocks.words`) and of the
  /// users who wrote in it (`blocks.senders`, `users` ids), both null until
  /// indexed.
  static Future<void> _createSearchIndex(Database db) async {
    await db.execute(
      'CREATE TABLE vocab(first INTEGER PRIMARY KEY, words BLOB NOT NULL)',
    );
    await db.execute('ALTER TABLE blocks ADD COLUMN words BLOB');
    await db.execute('ALTER TABLE blocks ADD COLUMN senders BLOB');
  }

  /// Edits for rows already sealed, keyed by channel and message id: `remove`
  /// drops the row, `deleted` sets its deleted flag. A read applies them on
  /// decode; upkeep bakes them into the blocks and clears them.
  static Future<void> _createEdits(Database db) =>
      db.execute('''CREATE TABLE edits(
         channel TEXT NOT NULL, message_id TEXT NOT NULL, kind TEXT NOT NULL,
         PRIMARY KEY(channel, message_id)) WITHOUT ROWID''');

  /// Stored definitions of [keys] in [channel], as JSON by key. Missing keys
  /// are left out.
  Future<Map<String, String>> emoteDefs(
    String channel,
    Iterable<String> keys,
  ) async {
    final all = keys.toList();
    final out = <String, String>{};
    // SQLite caps bound parameters; stay well under it.
    for (var i = 0; i < all.length; i += 500) {
      final part = all.sublist(i, i + 500 > all.length ? all.length : i + 500);
      final r = await _db.rawQuery(
        'SELECT key, json FROM emote_defs WHERE channel = ? AND key IN '
        '(${List.filled(part.length, '?').join(', ')})',
        [channel, ...part],
      );
      for (final row in r) {
        out[row['key']! as String] = row['json']! as String;
      }
    }
    return out;
  }

  Future<void> close() async {
    await _compacting;
    await _db.close();
  }

  /// Journal mode, exposed so tests can assert WAL.
  Future<String> journalMode() async {
    final rows = await _db.rawQuery('PRAGMA journal_mode');
    return '${rows.first.values.first}'.toLowerCase();
  }

  // ---- User tables ---------------------------------------------------------

  /// The channel's interned user tables, loaded once. The writer interns into
  /// the returned object and the reader resolves row user ids against it.
  Future<UserTables> tables(String channel) async {
    final future = _tables.putIfAbsent(channel, () => _loadTables(channel));
    try {
      return (await future).tables;
    } catch (_) {
      _tables.remove(channel);
      rethrow;
    }
  }

  /// Reads the three tables as a few joined strings and parses them on a
  /// background isolate. A busy channel keeps tens of thousands of chatters;
  /// row by row, decoding the query results alone stalls the UI isolate for
  /// seconds at startup.
  Future<_ChannelTables> _loadTables(String channel) async {
    final users = await _joined(
      channel,
      'users',
      "id || char(31) || user_id || char(31) || login || char(31) || "
          "ifnull(display_name, '') || char(31) || (display_name IS NULL)",
    );
    final looks = await _joined(
      channel,
      'looks',
      "id || char(31) || ifnull(color, '') || char(31) || (color IS NULL) || "
          "char(31) || badges || char(31) || ifnull(extra, '')",
    );
    final states = await _joined(
      channel,
      'user_states',
      'id || char(31) || who || char(31) || look',
    );
    return _ChannelTables(
      await Isolate.run(() => parseJoinedTables(users, looks, states)),
    );
  }

  /// [expr] for every row of a per-channel [table], fields split by char 31
  /// and rows by char 30, one string per range of ids. Ranges keep each
  /// string far below Android's 2 MB cursor window.
  Future<List<String>> _joined(
    String channel,
    String table,
    String expr,
  ) async {
    const page = 5000;
    final top = await _db.rawQuery(
      'SELECT max(id) AS top FROM $table WHERE channel = ?',
      [channel],
    );
    final max = top.first['top'] as int?;
    final out = <String>[];
    for (var from = 0; max != null && from <= max; from += page) {
      final r = await _db.rawQuery(
        'SELECT group_concat($expr, char(30)) AS g FROM $table '
        'WHERE channel = ? AND id >= ? AND id < ?',
        [channel, from, from + page],
      );
      if (r.first['g'] case final String g) out.add(g);
    }
    return out;
  }

  // ---- Writes --------------------------------------------------------------

  /// Stores one sealed block, any user rows not yet saved for [channel], and
  /// the per-minute counts, in one transaction. [minutes] maps epoch minute to
  /// the number of rows the block adds, [refs] each reply root to its newest
  /// reply's time, and [states] the user states the rows name.
  Future<void> appendBlock({
    required String channel,
    required int startTs,
    required int endTs,
    required int count,
    required Uint8List data,
    required Map<int, int> minutes,
    Map<String, String> emoteDefs = const {},
    Map<String, int> refs = const {},
    Set<String>? words,
    Set<int>? senders,
    Set<int>? states,
  }) => _withVocab((v) async {
    await tables(channel);
    final saved = await _tables[channel]!;
    final t = saved.tables;
    final whoTo = t.nextWho;
    final lookTo = t.nextLook;
    final stateTo = t.nextState;
    final first = v.length;
    final ids = words == null ? null : v.assign(words);
    try {
      await _db.transaction((txn) async {
        final b = txn.batch();
        if (v.length > first) {
          b.insert('vocab', {
            'first': first,
            'words': encodeVocabChunk(v.words.sublist(first)),
          });
        }
        for (var i = saved.whoSaved; i < whoTo; i++) {
          final w = t.whos[i];
          if (w == null) continue;
          b.insert('users', {
            'channel': channel,
            'id': i,
            'user_id': w.userId,
            'login': w.login,
            'display_name': w.displayName,
          });
        }
        for (var i = saved.lookSaved; i < lookTo; i++) {
          final l = t.looks[i];
          if (l == null) continue;
          b.insert('looks', {
            'channel': channel,
            'id': i,
            'color': l.color,
            'badges': l.badges,
            'extra': l.extra.isEmpty
                ? null
                : jsonEncode([
                    for (final (k, v) in l.extra) [k, v],
                  ]),
          });
        }
        for (var i = saved.stateSaved; i < stateTo; i++) {
          final s = t.states[i];
          if (s == null) continue;
          b.insert('user_states', {
            'channel': channel,
            'id': i,
            'who': s.who,
            'look': s.look,
          });
        }
        b.insert('blocks', {
          'channel': channel,
          'start_ts': startTs,
          'end_ts': endTs,
          'count': count,
          'data': data,
          'refs': 1,
          'words': ids == null ? null : encodeWordList(ids),
          'senders': senders == null ? null : encodeWordList(senders),
          'states': states == null ? null : encodeWordList(states),
        });
        _putRefs(b, channel, refs);
        for (final e in emoteDefs.entries) {
          b.insert('emote_defs', {
            'channel': channel,
            'key': e.key,
            'json': e.value,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        for (final e in minutes.entries) {
          b.rawInsert(
            'INSERT OR IGNORE INTO minute_counts(channel, minute, count) VALUES(?, ?, 0)',
            [channel, e.key],
          );
          b.rawUpdate(
            'UPDATE minute_counts SET count = count + ? WHERE channel = ? AND minute = ?',
            [e.value, channel, e.key],
          );
        }
        await b.commit(noResult: true);
      });
    } catch (_) {
      v.truncate(first);
      rethrow;
    }
    saved.whoSaved = whoTo;
    saved.lookSaved = lookTo;
    saved.stateSaved = stateTo;
    final span = _maxSpan[channel];
    if (span != null && endTs - startTs > span) {
      _maxSpan[channel] = endTs - startTs;
    }
  });

  /// Records reply roots with the time of their newest reply.
  static void _putRefs(Batch b, String channel, Map<String, int> refs) {
    for (final MapEntry(key: id, value: ts) in refs.entries) {
      b.rawInsert(
        'INSERT OR IGNORE INTO ref_ids(channel, message_id, ts) VALUES(?, ?, ?)',
        [channel, id, ts],
      );
      b.rawUpdate(
        'UPDATE ref_ids SET ts = ? WHERE channel = ? AND message_id = ? '
        'AND ts < ?',
        [ts, channel, id, ts],
      );
    }
  }

  // ---- Search index --------------------------------------------------------

  Future<_Vocab>? _vocab;
  Future<void> _vocabLock = Future.value();

  /// Runs [body] with the vocabulary, one at a time, so word ids are handed
  /// out once and a failed write takes back its new words.
  Future<T> _withVocab<T>(Future<T> Function(_Vocab v) body) {
    final run = _vocabLock.then(
      (_) async => body(await (_vocab ??= _loadVocab())),
    );
    _vocabLock = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<_Vocab> _loadVocab() async {
    final r = await _db.rawQuery(
      'SELECT first, words FROM vocab ORDER BY first',
    );
    return _vocabOffIsolate([
      for (final row in r) (row['first']! as int, row['words']! as Uint8List),
    ]);
  }

  static Future<_Vocab> _vocabOffIsolate(List<(int, Uint8List)> chunks) =>
      Isolate.run(() => _Vocab.fromChunks(chunks));

  /// Indexes blocks sealed before the index existed, or merged since, and
  /// lists their user states. Returns blocks indexed.
  Future<int> backfillWords() async {
    var done = 0;
    while (true) {
      final r = await _db.rawQuery(
        'SELECT id, channel, data FROM blocks '
        'WHERE words IS NULL OR senders IS NULL OR states IS NULL LIMIT 64',
      );
      if (r.isEmpty) return done;
      final found = await _wordsOffIsolate([
        for (final row in r) row['data']! as Uint8List,
      ]);
      // Rows name user states; the index keeps who wrote.
      final senders = <Uint8List>[];
      for (var i = 0; i < r.length; i++) {
        final t = await tables(r[i]['channel']! as String);
        senders.add(
          encodeWordList({
            for (final s in found[i].states)
              if (t.states[s] case final st?) st.who,
          }),
        );
      }
      await _withVocab((v) async {
        final first = v.length;
        final lists = [
          for (final f in found) encodeWordList(v.assign(f.words)),
        ];
        try {
          await _db.transaction((txn) async {
            final b = txn.batch();
            if (v.length > first) {
              b.insert('vocab', {
                'first': first,
                'words': encodeVocabChunk(v.words.sublist(first)),
              });
            }
            for (var i = 0; i < r.length; i++) {
              b.rawUpdate(
                'UPDATE blocks SET words = ?, senders = ?, states = ? '
                'WHERE id = ?',
                [
                  lists[i],
                  senders[i],
                  encodeWordList(found[i].all),
                  r[i]['id'],
                ],
              );
            }
            await b.commit(noResult: true);
          });
        } catch (_) {
          v.truncate(first);
          rethrow;
        }
      });
      done += r.length;
    }
  }

  static Future<List<({Set<String> words, Set<int> states, Set<int> all})>>
  _wordsOffIsolate(List<Uint8List> blocks) =>
      Isolate.run(() => blockWords(blocks));

  /// Vocabulary ids of every word containing each of [tokens].
  Future<List<Set<int>>> wordIds(List<String> tokens) async {
    final (joined, starts) = (await (_vocab ??= _loadVocab())).joined();
    return _containingOffIsolate(joined, starts, tokens);
  }

  static Future<List<Set<int>>> _containingOffIsolate(
    String joined,
    Int32List starts,
    List<String> tokens,
  ) => Isolate.run(() => wordsContaining(joined, starts, tokens));

  /// Blocks of [channels] that may hold a match: for one entry of [words],
  /// every set has an id in the block, or one of the channel's [senders]
  /// wrote in it. Blocks not yet indexed always qualify. Ending at or before
  /// [beforeTs] and at or after [afterTs], with each block's time span
  /// (epoch ms).
  Future<List<({String channel, int id, int start, int end})>> searchBlocks(
    List<String> channels, {
    List<List<Set<int>>>? words,
    Map<String, Set<int>> senders = const {},
    int? beforeTs,
    int? afterTs,
  }) async {
    if (channels.isEmpty || words == null && senders.isEmpty) return const [];
    final where = [
      'channel IN (${List.filled(channels.length, '?').join(', ')})',
      if (beforeTs != null) 'start_ts <= $beforeTs',
      if (afterTs != null) 'end_ts >= $afterTs',
    ].join(' AND ');
    final r = await _db.rawQuery(
      'SELECT channel, id, start_ts, end_ts, words, senders FROM blocks '
      'WHERE $where',
      channels,
    );
    final hit = await _matchOffIsolate(
      [for (final row in r) row['words'] as Uint8List?],
      [for (final row in r) row['senders'] as Uint8List?],
      words,
      [for (final row in r) senders[row['channel']]],
    );
    return [
      for (var i = 0; i < r.length; i++)
        if (hit[i])
          (
            channel: r[i]['channel']! as String,
            id: r[i]['id']! as int,
            start: r[i]['start_ts']! as int,
            end: r[i]['end_ts']! as int,
          ),
    ];
  }

  static Future<List<bool>> _matchOffIsolate(
    List<Uint8List?> words,
    List<Uint8List?> senders,
    List<List<Set<int>>>? wantWords,
    List<Set<int>?> wantSenders,
  ) => Isolate.run(() => matchBlocks(words, senders, wantWords, wantSenders));

  /// Channels with archived blocks.
  Future<List<String>> channels() async => [
    for (final r in await _db.rawQuery('SELECT DISTINCT channel FROM blocks'))
      r['channel']! as String,
  ];

  /// Blocks by key, in the order given; missing keys are skipped.
  Future<List<StoredBlock>> blocksByKey(List<int> keys) async {
    if (keys.isEmpty) return const [];
    final r = await _db.rawQuery(
      'SELECT $_cols FROM blocks WHERE id IN '
      '(${List.filled(keys.length, '?').join(', ')})',
      keys,
    );
    final byKey = {for (final row in r) row['id']! as int: _block(row)};
    return [for (final k in keys) ?byKey[k]];
  }

  /// Keeps [startTs]..[endTs] (epoch ms, inclusive) out of retention pruning.
  Future<void> addPin(String channel, int startTs, int endTs, String kind) =>
      _db.insert('pins', {
        'channel': channel,
        'start_ts': startTs,
        'end_ts': endTs,
        'kind': kind,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

  /// Releases the [kind] pins that start within [startTs] to [endTs], so
  /// retention covers them again. A day kept in another time zone has other
  /// bounds but still starts inside the day it shows on.
  Future<void> removePin(String channel, int startTs, int endTs, String kind) =>
      _db.delete(
        'pins',
        where: 'channel = ? AND kind = ? AND start_ts BETWEEN ? AND ?',
        whereArgs: [channel, kind, startTs, endTs],
      );

  /// The pins of [channel], as (start, end, kind).
  Future<List<({int startTs, int endTs, String kind})>> pins(
    String channel,
  ) async {
    final r = await _db.rawQuery(
      'SELECT start_ts, end_ts, kind FROM pins WHERE channel = ?',
      [channel],
    );
    return [
      for (final row in r)
        (
          startTs: row['start_ts']! as int,
          endTs: row['end_ts']! as int,
          kind: row['kind']! as String,
        ),
    ];
  }

  /// Remembers the video on demand of the broadcast [id].
  Future<void> setVod(String id, String vodId) => _db.rawUpdate(
    'UPDATE streams SET vod_id = ? WHERE stream_id = ?',
    [vodId, id],
  );

  /// Records a broadcast seen live. A later call for the same [id] only
  /// clears its end, since Helix listing it live means it has not ended.
  /// Returns whether anything changed.
  Future<bool> putStream({
    required String channel,
    required String id,
    required int startedTs,
    String? title,
    String? game,
  }) async {
    final held = await _db.rawQuery(
      'SELECT ended_at FROM streams WHERE stream_id = ?',
      [id],
    );
    if (held.isNotEmpty) {
      if (held.first['ended_at'] == null) return false;
      await _db.rawUpdate(
        'UPDATE streams SET ended_at = NULL WHERE stream_id = ?',
        [id],
      );
      return true;
    }
    await _db.insert('streams', {
      'stream_id': id,
      'channel': channel,
      'started_at': startedTs,
      'title': title,
      'game': game,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return true;
  }

  /// Sets the end of the broadcast [id] (epoch ms).
  Future<void> endStream(String id, int endedTs) => _db.rawUpdate(
    'UPDATE streams SET ended_at = ? WHERE stream_id = ?',
    [endedTs, id],
  );

  /// Marks rows by [login] (every chatter when null) from [fromTs] to
  /// [toTs] (epoch ms, inclusive) deleted.
  Future<void> addModeration(
    String channel,
    String? login,
    int fromTs,
    int toTs, {
    int? atTs,
  }) async {
    await _db.insert('moderation', {
      'channel': channel,
      'login': login,
      'from_ts': fromTs,
      'to_ts': toTs,
      'at_ts': atTs,
    });
    _moderated[channel] = Future.value(true);
  }

  /// Records an edit of every id in [messageIds] in one transaction.
  Future<void> addEdits(
    String channel,
    Iterable<String> messageIds,
    ArchiveEdit edit,
  ) async {
    final ids = messageIds.toList();
    if (ids.isEmpty) return;
    await _db.transaction((txn) async {
      final b = txn.batch();
      for (final id in ids) {
        b.insert('edits', {
          'channel': channel,
          'message_id': id,
          'kind': edit.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await b.commit(noResult: true);
    });
    _edited[channel] = Future.value(true);
  }

  // ---- Reads ---------------------------------------------------------------

  /// Channels known to have moderation rows, so decoding a clean channel
  /// never queries the table.
  final Map<String, Future<bool>> _moderated = {};

  /// Channels known to have pending edits, so decoding a clean channel never
  /// queries the table.
  final Map<String, Future<bool>> _edited = {};

  /// Pending edits of [channel] by message id.
  Future<Map<String, ArchiveEdit>> edits(String channel) async {
    final any = await (_edited[channel] ??= _db
        .rawQuery('SELECT 1 FROM edits WHERE channel = ? LIMIT 1', [channel])
        .then((r) => r.isNotEmpty));
    if (!any) return const {};
    final r = await _db.rawQuery(
      'SELECT message_id, kind FROM edits WHERE channel = ?',
      [channel],
    );
    return {
      for (final row in r)
        row['message_id']! as String: ArchiveEdit.values.byName(
          row['kind']! as String,
        ),
    };
  }

  /// Moderation ranges of [channel] overlapping [fromTs]..[toTs].
  Future<List<({String? login, int fromTs, int toTs, int? atTs})>> moderation(
    String channel,
    int fromTs,
    int toTs,
  ) async {
    final any = await (_moderated[channel] ??= _db
        .rawQuery('SELECT 1 FROM moderation WHERE channel = ? LIMIT 1', [
          channel,
        ])
        .then((r) => r.isNotEmpty));
    if (!any) return const [];
    final r = await _db.rawQuery(
      'SELECT login, from_ts, to_ts, at_ts FROM moderation '
      'WHERE channel = ? AND to_ts >= ? AND from_ts <= ?',
      [channel, fromTs, toTs],
    );
    return [
      for (final row in r)
        (
          login: row['login'] as String?,
          fromTs: row['from_ts']! as int,
          toTs: row['to_ts']! as int,
          atTs: row['at_ts'] as int?,
        ),
    ];
  }

  static StoredBlock _block(Map<String, Object?> r) => StoredBlock(
    key: r['id']! as int,
    startTs: r['start_ts']! as int,
    endTs: r['end_ts']! as int,
    count: r['count']! as int,
    data: r['data']! as Uint8List,
  );

  static const _cols = 'id, start_ts, end_ts, count, data';

  /// The newest blocks holding at least [rows] rows, newest first, plus one
  /// spare block because block time ranges can overlap.
  Future<List<StoredBlock>> newestBlocks(String channel, int rows) async {
    final heads = await _db.rawQuery(
      'SELECT id, count FROM blocks WHERE channel = ? '
      'ORDER BY start_ts DESC, id DESC LIMIT ?',
      [channel, rows < 1 ? 1 : rows],
    );
    final ids = <int>[];
    var have = 0;
    for (final h in heads) {
      ids.add(h['id']! as int);
      have += h['count']! as int;
      if (have >= rows) {
        break;
      }
    }
    if (have >= rows && ids.length < heads.length) {
      ids.add(heads[ids.length]['id']! as int);
    }
    if (ids.isEmpty) {
      return const [];
    }
    final found = await _db.rawQuery(
      'SELECT $_cols FROM blocks WHERE id IN (${ids.join(',')})',
    );
    final byId = {for (final r in found) r['id']! as int: _block(r)};
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// Up to [before] blocks older than the anchor, the anchor, and up to
  /// [after] newer, oldest first. The anchor is the last block starting at or
  /// before [timeMs], or the first block when [timeMs] precedes them all.
  Future<List<StoredBlock>> blocksAround(
    String channel,
    int timeMs,
    int before,
    int after,
  ) async {
    var anchor = await _db.rawQuery(
      'SELECT $_cols FROM blocks WHERE channel = ? AND start_ts <= ? '
      'ORDER BY start_ts DESC, id DESC LIMIT 1',
      [channel, timeMs],
    );
    if (anchor.isEmpty) {
      anchor = await _db.rawQuery(
        'SELECT $_cols FROM blocks WHERE channel = ? '
        'ORDER BY start_ts, id LIMIT 1',
        [channel],
      );
    }
    if (anchor.isEmpty) {
      return const [];
    }
    final a = _block(anchor.first);
    final older = before <= 0
        ? const <Map<String, Object?>>[]
        : await _db.rawQuery(
            'SELECT $_cols FROM blocks WHERE channel = ? AND '
            '(start_ts < ? OR (start_ts = ? AND id < ?)) '
            'ORDER BY start_ts DESC, id DESC LIMIT ?',
            [channel, a.startTs, a.startTs, a.key, before],
          );
    final newer = after <= 0
        ? const <Map<String, Object?>>[]
        : await _db.rawQuery(
            'SELECT $_cols FROM blocks WHERE channel = ? AND '
            '(start_ts > ? OR (start_ts = ? AND id > ?)) '
            'ORDER BY start_ts, id LIMIT ?',
            [channel, a.startTs, a.startTs, a.key, after],
          );
    return [...older.reversed.map(_block), a, ...newer.map(_block)];
  }

  /// Widest block per channel (end minus start, ms), so a lookup for blocks
  /// spanning a time can stay on the start index. Never shrinks; a stale
  /// value only widens the scan.
  final Map<String, int> _maxSpan = {};

  Future<int> _spanOf(String channel) async {
    final known = _maxSpan[channel];
    if (known != null) return known;
    final r = await _db.rawQuery(
      'SELECT MAX(end_ts - start_ts) AS span FROM blocks WHERE channel = ?',
      [channel],
    );
    return _maxSpan[channel] = (r.first['span'] as int?) ?? 0;
  }

  /// Every block holding rows at [timeMs], up to [before] blocks ending
  /// earlier and up to [after] starting later, oldest first. Block time
  /// ranges can overlap, so a block left out may still hold rows near the
  /// ones returned: only rows after [floorTs] and before [ceilTs] are
  /// complete. A null bound means nothing lies beyond it.
  Future<({List<StoredBlock> blocks, int? floorTs, int? ceilTs})> blocksNear(
    String channel,
    int timeMs,
    int before,
    int after,
  ) async {
    final span = await _spanOf(channel);
    final spanning = await _db.rawQuery(
      'SELECT $_cols FROM blocks WHERE channel = ? AND start_ts >= ? '
      'AND start_ts <= ? AND end_ts >= ?',
      [channel, timeMs - span, timeMs, timeMs],
    );
    // Equal bounds would cut every row of the last block taken, so blocks
    // sharing the edge value join the take.
    Future<(List<Map<String, Object?>>, int?)> side(
      String where,
      String order,
      String edge,
      int n,
    ) async {
      if (n <= 0) return (const <Map<String, Object?>>[], null);
      final rows = await _db.rawQuery(
        'SELECT $_cols FROM blocks WHERE channel = ? AND $where '
        'ORDER BY $order LIMIT ?',
        [channel, timeMs, n + 8],
      );
      var take = rows.length < n ? rows.length : n;
      while (take < rows.length && rows[take][edge] == rows[take - 1][edge]) {
        take++;
      }
      return (
        rows.sublist(0, take),
        take < rows.length ? rows[take][edge] as int : null,
      );
    }

    final (older, floor) = await side(
      'end_ts < ?',
      'end_ts DESC, id DESC',
      'end_ts',
      before,
    );
    final (newer, ceil) = await side(
      'start_ts > ?',
      'start_ts, id',
      'start_ts',
      after,
    );
    final blocks = [
      ...older.reversed.map(_block),
      ...spanning.map(_block),
      ...newer.map(_block),
    ];
    // A block ending before [timeMs] may sit beyond the floor; with no older
    // block taken, everything older is unread.
    return (
      blocks: blocks,
      floorTs: before > 0 ? floor : (blocks.isEmpty ? null : timeMs - 1),
      ceilTs: after > 0 ? ceil : (blocks.isEmpty ? null : timeMs + 1),
    );
  }

  Future<StoredBlock?> blockAt(String channel, int key) async {
    final r = await _db.rawQuery(
      'SELECT $_cols FROM blocks WHERE channel = ? AND id = ?',
      [channel, key],
    );
    return r.isEmpty ? null : _block(r.first);
  }

  /// Row counts for epoch minutes in [fromMinute]..[toMinute], summed per
  /// [per] minutes; each entry's minute starts its group.
  Future<List<({int minute, int count})>> minuteCounts(
    String channel,
    int fromMinute,
    int toMinute, {
    int per = 1,
  }) async {
    final r = await _db.rawQuery(
      'SELECT minute / ? * ? AS minute, SUM(count) AS count FROM minute_counts '
      'WHERE channel = ? AND minute >= ? AND minute <= ? '
      'GROUP BY minute / ? ORDER BY minute',
      [per, per, channel, fromMinute, toMinute, per],
    );
    return [
      for (final row in r)
        (minute: row['minute']! as int, count: row['count']! as int),
    ];
  }

  /// Broadcasts of [channel] still live or ended at or after [fromTs],
  /// oldest first. A live one has a null end.
  Future<
    List<
      ({
        String id,
        int startedTs,
        int? endedTs,
        String? title,
        String? game,
        String? vodId,
      })
    >
  >
  streams(String channel, int fromTs) async {
    final r = await _db.rawQuery(
      'SELECT stream_id, started_at, ended_at, title, game, vod_id FROM streams '
      'WHERE channel = ? AND (ended_at IS NULL OR ended_at >= ?) '
      'ORDER BY started_at',
      [channel, fromTs],
    );
    return [
      for (final row in r)
        (
          id: row['stream_id']! as String,
          startedTs: row['started_at']! as int,
          endedTs: row['ended_at'] as int?,
          title: row['title'] as String?,
          game: row['game'] as String?,
          vodId: row['vod_id'] as String?,
        ),
    ];
  }

  // ---- Saved threads -------------------------------------------------------

  /// All saved thread bookmarks, newest saved first.
  Future<List<StoredThread>> savedThreads() async {
    final r = await _db.rawQuery(
      'SELECT channel, root_id, login, author, preview, saved_at '
      'FROM saved_threads ORDER BY saved_at DESC, channel, root_id',
    );
    return [
      for (final row in r)
        StoredThread(
          channel: row['channel']! as String,
          rootId: row['root_id']! as String,
          login: row['login']! as String,
          author: row['author']! as String,
          preview: row['preview']! as String,
          savedAtMs: row['saved_at']! as int,
        ),
    ];
  }

  /// Message rows of one thread, newest first.
  Future<List<StoredThreadMessage>> threadMessages(
    String channel,
    String rootId,
  ) async {
    final r = await _db.rawQuery(
      'SELECT message_id, ts, data FROM thread_messages '
      'WHERE channel = ? AND root_id = ? ORDER BY ts DESC',
      [channel, rootId],
    );
    return [
      for (final row in r)
        StoredThreadMessage(
          channel: channel,
          rootId: rootId,
          messageId: row['message_id']! as String,
          ts: row['ts']! as int,
          data: row['data']! as Uint8List,
        ),
    ];
  }

  /// Saves [thread] with exactly [messages], replacing any earlier rows, in
  /// one transaction. Threads in [evict] are deleted in the same one.
  Future<void> putThread(
    StoredThread thread,
    List<StoredThreadMessage> messages, {
    Iterable<(String, String)> evict = const [],
  }) => _db.transaction((txn) async {
    final b = txn.batch();
    for (final (channel, rootId) in evict) {
      _deleteThread(b, channel, rootId);
    }
    _deleteThread(b, thread.channel, thread.rootId);
    _insertThread(b, thread, ConflictAlgorithm.replace);
    for (final m in messages) {
      _insertMessage(b, m);
    }
    await b.commit(noResult: true);
  });

  /// Deletes a thread's bookmark and all its message rows.
  Future<void> deleteThread(String channel, String rootId) =>
      _db.transaction((txn) async {
        final b = txn.batch();
        _deleteThread(b, channel, rootId);
        await b.commit(noResult: true);
      });

  /// Inserts new message rows in one transaction; an existing id is kept.
  Future<void> appendThreadMessages(List<StoredThreadMessage> rows) =>
      _db.transaction((txn) async {
        final b = txn.batch();
        for (final m in rows) {
          _insertMessage(b, m);
        }
        await b.commit(noResult: true);
      });

  static void _deleteThread(Batch b, String channel, String rootId) {
    final args = [channel, rootId];
    b.rawDelete(
      'DELETE FROM thread_messages WHERE channel = ? AND root_id = ?',
      args,
    );
    b.rawDelete(
      'DELETE FROM saved_threads WHERE channel = ? AND root_id = ?',
      args,
    );
  }

  static void _insertThread(Batch b, StoredThread t, ConflictAlgorithm c) =>
      b.insert('saved_threads', {
        'channel': t.channel,
        'root_id': t.rootId,
        'login': t.login,
        'author': t.author,
        'preview': t.preview,
        'saved_at': t.savedAtMs,
      }, conflictAlgorithm: c);

  static void _insertMessage(Batch b, StoredThreadMessage m) =>
      b.insert('thread_messages', {
        'channel': m.channel,
        'root_id': m.rootId,
        'message_id': m.messageId,
        'ts': m.ts,
        'data': m.data,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

  // ---- Retention -----------------------------------------------------------

  /// The writer's uncommitted message ids and the user states its unsealed
  /// rows name, per channel, so upkeep never clears an edit or drops a user
  /// a seal still needs. [ArchiveWriter] sets them as the store opens, before
  /// it takes any row.
  Set<String> Function(String channel)? heldEdits;
  Set<int> Function(String channel)? heldStates;

  /// Prunes when none ran in the last [pruneEvery]. Returns blocks deleted.
  Future<int> pruneIfDue() async {
    final now = _now();
    final last = _lastPrune;
    if (last != null && now.difference(last) < pruneEvery) {
      return 0;
    }
    _lastPrune = now;
    final deleted = await prune(now);
    // A long gap leaves seconds of merging; nothing waits on it.
    _compacting ??= _upkeep(now)
        .then<void>(
          (_) {},
          onError: (Object e) {
            logDebug('[ArchiveStore] upkeep failed: $e');
          },
        )
        .whenComplete(() => _compacting = null);
    return deleted;
  }

  Future<void>? _compacting;

  /// Background upkeep after a prune: merge small blocks, bake pending edits,
  /// strip ids, index, drop users and words nothing names, then hand free
  /// pages back.
  Future<void> _upkeep(DateTime now) async {
    await compact(now);
    await bakeEdits();
    await strip(now);
    await backfillWords();
    await pruneUsers();
    await pruneVocab();
    await reclaimSpace();
  }

  /// Drops user states no block names and no row in [held] (the writer's
  /// unsealed rows, [heldStates] by default) uses, then the whos and looks left unused. Runs under
  /// the write lock, so no block lands between the scan and the drop. A
  /// channel with blocks not yet listed waits. Returns states dropped.
  Future<int> pruneUsers({Set<int> Function(String channel)? held}) =>
      _withVocab((_) async {
        var dropped = 0;
        final channels = await _db.rawQuery(
          'SELECT DISTINCT channel FROM user_states',
        );
        for (final c in channels) {
          final channel = c['channel']! as String;
          final r = await _db.rawQuery(
            'SELECT states FROM blocks WHERE channel = ?',
            [channel],
          );
          if (r.any((row) => row['states'] == null)) continue;
          final live = await _statesOffIsolate([
            for (final row in r) row['states']! as Uint8List,
          ]);
          final t = await tables(channel);
          // Read now, after the last await: the writer may have registered
          // or taken rows since the call.
          live.addAll((held ?? heldStates)?.call(channel) ?? const {});
          final dead = t.prune(live);
          if (dead.states.isEmpty) continue;
          dropped += dead.states.length;
          await _db.transaction((txn) async {
            final b = txn.batch();
            for (final (table, ids) in [
              ('user_states', dead.states),
              ('users', dead.whos),
              ('looks', dead.looks),
            ]) {
              for (var i = 0; i < ids.length; i += 500) {
                final part = ids.skip(i).take(500);
                b.rawDelete(
                  'DELETE FROM $table WHERE channel = ? AND id IN '
                  '(${part.join(',')})',
                  [channel],
                );
              }
            }
            await b.commit(noResult: true);
          });
        }
        return dropped;
      });

  static Future<Set<int>> _statesOffIsolate(List<Uint8List> lists) =>
      Isolate.run(() => {for (final l in lists) ...decodeWordList(l)});

  /// Vocabulary size at the last check of how much of it blocks still use.
  int? _vocabChecked;

  /// Rebuilds the vocabulary from the words blocks still hold once pruned
  /// blocks leave most of it unused, renumbering every block's list in one
  /// transaction. Checks again after the vocabulary grows by a quarter.
  /// Returns words dropped.
  Future<int> pruneVocab() => _withVocab((v) async {
    final checked = _vocabChecked;
    if (v.length < 1000) return 0;
    if (checked != null && v.length < checked * 5 ~/ 4) return 0;
    _vocabChecked = v.length;
    final r = await _db.rawQuery(
      'SELECT id, words FROM blocks WHERE words IS NOT NULL',
    );
    final lists = [for (final row in r) row['words']! as Uint8List];
    final used = await _usedOffIsolate(lists);
    if (used.length * 2 > v.length) return 0;
    final remapped = await _renumberOffIsolate(lists, used);
    final words = [for (final id in used) v.words[id]];
    await _db.transaction((txn) async {
      final b = txn.batch();
      b.delete('vocab');
      for (var i = 0; i < words.length; i += _vocabChunk) {
        b.insert('vocab', {
          'first': i,
          'words': encodeVocabChunk(
            words.sublist(i, min(i + _vocabChunk, words.length)),
          ),
        });
      }
      for (var i = 0; i < r.length; i++) {
        b.rawUpdate('UPDATE blocks SET words = ? WHERE id = ?', [
          remapped[i],
          r[i]['id'],
        ]);
      }
      await b.commit(noResult: true);
    });
    final dropped = v.length - words.length;
    v.replaceWith(words);
    _vocabChecked = words.length;
    return dropped;
  });

  static Future<List<int>> _usedOffIsolate(List<Uint8List> lists) =>
      Isolate.run(() => usedWords(lists));

  static Future<List<Uint8List?>> _renumberOffIsolate(
    List<Uint8List> lists,
    List<int> used,
  ) => Isolate.run(() => renumberWords(lists, used));

  /// Words per vocabulary row a rebuild writes, so a row stays far below
  /// Android's 2 MB cursor window.
  static const int _vocabChunk = 20000;

  /// Write-ahead log bytes kept after a checkpoint.
  static const int _walLimit = 4 * 1024 * 1024;

  /// Hands free pages back to the file system once they pass a quarter of
  /// the file or 8 MB, or always with [all]. Returns bytes freed.
  Future<int> reclaimSpace({bool all = false}) async {
    Future<int> pragma(String name) async =>
        (await _db.rawQuery('PRAGMA $name')).first.values.first as int? ?? 0;
    final pageSize = await pragma('page_size');
    final free = await pragma('freelist_count');
    final pages = await pragma('page_count');
    if (free == 0) return 0;
    if (!all && free * 4 < pages && free * pageSize < 8 * 1024 * 1024) {
      return 0;
    }
    await _db.rawQuery('PRAGMA incremental_vacuum');
    await _db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    return free * pageSize;
  }

  /// Message ids kept per channel, newest first. Robotty's fetch (800) and
  /// the live buffer dedup by id, and replies and mod actions need them;
  /// past this only reply roots and parents keep theirs.
  static const int keepIdRows = 1000;

  /// Rows this recent keep their ids past [keepIdRows], so a reply can reach
  /// back through a day's stream, up to [keepIdMaxRows] per channel (about
  /// 15 bytes each).
  static const Duration keepIdAge = Duration(hours: 24);
  static const int keepIdMaxRows = 100000;

  /// Drops message ids from blocks wholly past the newest [keepIdRows] rows
  /// of their channel and older than [keepIdAge] (or past [keepIdMaxRows]),
  /// keeping every id a reply references. A channel with references not yet
  /// recorded waits. Returns blocks stripped.
  Future<int> strip([DateTime? now]) async {
    final recent = (now ?? _now()).subtract(keepIdAge).millisecondsSinceEpoch;
    var stripped = 0;
    final channels = await _db.rawQuery(
      'SELECT channel, MIN(refs) AS r FROM blocks GROUP BY channel',
    );
    for (final c in channels) {
      if (c['r'] != 1) continue;
      final channel = c['channel']! as String;
      final blocks = await _db.rawQuery(
        'SELECT id, count, stripped, end_ts FROM blocks WHERE channel = ? '
        'ORDER BY end_ts DESC, id DESC',
        [channel],
      );
      final targets = <int>[];
      var newer = 0;
      for (final b in blocks) {
        final young = (b['end_ts']! as int) >= recent;
        if (newer >= keepIdRows &&
            (!young || newer >= keepIdMaxRows) &&
            b['stripped'] == 0) {
          targets.add(b['id']! as int);
        }
        newer += b['count']! as int;
      }
      if (targets.isEmpty) continue;
      final keep = {
        for (final r in await _db.rawQuery(
          'SELECT message_id FROM ref_ids WHERE channel = ?',
          [channel],
        ))
          r['message_id']! as String,
      };
      for (var i = 0; i < targets.length; i += 64) {
        final part = targets.sublist(
          i,
          i + 64 > targets.length ? targets.length : i + 64,
        );
        final r = await _db.rawQuery(
          'SELECT id, data FROM blocks WHERE id IN '
          '(${List.filled(part.length, '?').join(', ')})',
          part,
        );
        final out = await _stripOffIsolate([
          for (final row in r) row['data']! as Uint8List,
        ], keep);
        await _db.transaction((txn) async {
          final b = txn.batch();
          for (var k = 0; k < r.length; k++) {
            final data = out[k];
            if (data == null) continue;
            b.rawUpdate(
              'UPDATE blocks SET data = ?, stripped = 1 '
              'WHERE id = ? AND stripped = 0',
              [data, r[k]['id']],
            );
            stripped++;
          }
          await b.commit(noResult: true);
        });
      }
    }
    return stripped;
  }

  /// Applies pending edits to the blocks that still hold message ids
  /// (`stripped = 0`), then clears them. Ids no block holds were stripped or
  /// never sealed, so they are cleared too, unless a reply keeps the id alive
  /// in a stripped block or the writer still holds it in [held] ([heldEdits]
  /// by default). Returns edits baked.
  Future<int> bakeEdits({Set<String> Function(String channel)? held}) async {
    var baked = 0;
    final channels = await _db.rawQuery('SELECT DISTINCT channel FROM edits');
    for (final c in channels) {
      final channel = c['channel']! as String;
      final pending = await edits(channel);
      if (pending.isEmpty) continue;
      final blocks = await _db.rawQuery(
        'SELECT id, data, count FROM blocks WHERE channel = ? AND stripped = 0',
        [channel],
      );
      final applied = <String>{};
      final removedMinutes = <int, int>{};
      if (blocks.isNotEmpty) {
        final results = await _bakeOffIsolate([
          for (final b in blocks) b['data']! as Uint8List,
        ], pending);
        await _db.transaction((txn) async {
          final b = txn.batch();
          for (var i = 0; i < blocks.length; i++) {
            final r = results[i];
            applied.addAll(r.applied);
            var removed = 0;
            for (final e in r.removedMinutes.entries) {
              removed += e.value;
              removedMinutes.update(
                e.key,
                (n) => n + e.value,
                ifAbsent: () => e.value,
              );
            }
            if (r.data == null) continue;
            // A block left with no rows goes, so paging never lands on it.
            if (removed >= (blocks[i]['count']! as int)) {
              b.rawDelete('DELETE FROM blocks WHERE id = ?', [blocks[i]['id']]);
              continue;
            }
            // The removed rows' words and users go with them on the next
            // index pass.
            b.rawUpdate(
              'UPDATE blocks SET data = ?, count = count - ?, words = NULL, '
              'senders = NULL, states = NULL WHERE id = ?',
              [r.data, removed, blocks[i]['id']],
            );
          }
          // A removed row leaves the block and its minute bucket, so the
          // activity rail stays exact.
          for (final e in removedMinutes.entries) {
            b.rawUpdate(
              'UPDATE minute_counts SET count = count - ? '
              'WHERE channel = ? AND minute = ?',
              [e.value, channel, e.key],
            );
          }
          // Matching the kind keeps an edit that replaced this one mid-bake.
          for (final id in applied) {
            b.rawDelete(
              'DELETE FROM edits WHERE channel = ? AND message_id = ? '
              'AND kind = ?',
              [channel, id, pending[id]!.name],
            );
          }
          await b.commit(noResult: true);
        });
        baked += applied.length;
      }
      // Reply parents keep their id in a stripped block, and a seal still
      // writing may yet store the row, so an edit for one stays pending
      // rather than being dropped as gone.
      final keep = (held ?? heldEdits)?.call(channel) ?? const <String>{};
      final refs = {
        for (final r in await _db.rawQuery(
          'SELECT message_id FROM ref_ids WHERE channel = ?',
          [channel],
        ))
          r['message_id']! as String,
      };
      for (final id in pending.keys) {
        if (applied.contains(id) || refs.contains(id) || keep.contains(id)) {
          continue;
        }
        await _db.delete(
          'edits',
          where: 'channel = ? AND message_id = ? AND kind = ?',
          whereArgs: [channel, id, pending[id]!.name],
        );
      }
    }
    return baked;
  }

  static Future<
    List<({Uint8List? data, Set<String> applied, Map<int, int> removedMinutes})>
  >
  _bakeOffIsolate(List<Uint8List> blocks, Map<String, ArchiveEdit> edits) =>
      Isolate.run(() => bakeBlocks(blocks, edits));

  static Future<List<Uint8List?>> _stripOffIsolate(
    List<Uint8List> blocks,
    Set<String> keep,
  ) => Isolate.run(() => stripBlocks(blocks, keep));

  /// Blocks this old or older may merge; newer ones are still the writer's
  /// recent past and stay as sealed.
  static const Duration compactAfter = Duration(hours: 1);

  /// Rows a merged block holds at most, the writer's seal size.
  static const int compactRows = 256;

  // Static, so the isolate's closure captures only the blocks, not the store.
  static Future<List<Uint8List?>> _mergeOffIsolate(
    List<List<Uint8List>> data,
  ) => Isolate.run(() => mergeBlocks(data));

  /// Merges runs of small blocks into blocks of up to [compactRows]. The 30 s
  /// seal leaves quiet channels with blocks of a handful of rows, which
  /// compress poorly and cost a table row each. Only blocks next to each
  /// other in time order merge, so no merged block overlaps a full one.
  /// Rows, their order within the run, and every count keep. Returns blocks
  /// merged away.
  Future<int> compact(DateTime now) async {
    final before = now.toUtc().subtract(compactAfter).millisecondsSinceEpoch;
    final groups = <List<int>>[];
    final channels = await _db.rawQuery('SELECT DISTINCT channel FROM blocks');
    for (final c in channels) {
      final blocks = await _db.rawQuery(
        'SELECT id, count FROM blocks WHERE channel = ? AND end_ts < ? '
        'ORDER BY start_ts, id',
        [c['channel'], before],
      );
      var run = <int>[];
      var rows = 0;
      void close() {
        if (run.length > 1) groups.add(run);
        run = [];
        rows = 0;
      }

      for (final b in blocks) {
        final n = b['count']! as int;
        if (n >= compactRows) {
          close();
          continue;
        }
        if (rows + n > compactRows) close();
        run.add(b['id']! as int);
        rows += n;
      }
      close();
    }
    if (groups.isEmpty) return 0;
    final data = <List<Uint8List>>[];
    for (final g in groups) {
      final r = await _db.rawQuery(
        'SELECT id, data FROM blocks WHERE id IN '
        '(${List.filled(g.length, '?').join(', ')})',
        g,
      );
      final byId = {for (final row in r) row['id']! as int: row['data']!};
      // A pruned block shortens the run; the transaction below rejects it.
      data.add([
        for (final id in g)
          if (byId[id] != null) byId[id]! as Uint8List,
      ]);
    }
    final merged = await _mergeOffIsolate(data);
    var removed = 0;
    for (var i = 0; i < groups.length; i++) {
      final m = merged[i];
      if (m == null) continue;
      final g = groups[i];
      final marks = List.filled(g.length, '?').join(', ');
      final ok = await _db.transaction((txn) async {
        final span = await txn.rawQuery(
          'SELECT channel, MIN(start_ts) AS s, MAX(end_ts) AS e, '
          'SUM(count) AS n, COUNT(*) AS k, MIN(refs) AS r, '
          'MIN(stripped) AS x FROM blocks WHERE id IN ($marks)',
          g,
        );
        final row = span.first;
        // A block gone since the scan (a prune) leaves the run alone.
        if (row['k'] != g.length) return false;
        await txn.rawDelete('DELETE FROM blocks WHERE id IN ($marks)', g);
        await txn.insert('blocks', {
          'channel': row['channel'],
          'start_ts': row['s'],
          'end_ts': row['e'],
          'count': row['n'],
          'data': m,
          // A merge keeps the least done of its sources' upkeep.
          'refs': row['r'],
          'stripped': row['x'],
        });
        _maxSpan.remove(row['channel']);
        return true;
      });
      if (ok) removed += g.length - 1;
    }
    return removed;
  }

  /// A broadcast still open with no chat stored for this long was left
  /// while live (the channel parted, so no poll saw it end).
  static const Duration staleLive = Duration(days: 1);

  /// SQL true when a kept day overlaps the `blocks` row.
  static const _pinnedBlock =
      'SELECT 1 FROM pins p WHERE p.channel = blocks.channel '
      'AND p.start_ts <= blocks.end_ts AND p.end_ts >= blocks.start_ts';

  /// Bytes of chat that kept days hold.
  Future<int> keptBytes() async {
    final rows = await _db.rawQuery(
      'SELECT COALESCE(SUM(length(data)), 0) AS n FROM blocks '
      'WHERE EXISTS ($_pinnedBlock)',
    );
    return (rows.first['n'] as num).toInt();
  }

  /// Deletes blocks, minute counts, moderation, reply roots and ended
  /// broadcasts older than [retention] relative to [now], then each
  /// channel's oldest blocks past [channelCapBytes]. Pinned ranges stay
  /// and do not count toward the cap.
  /// Broadcasts left open past [staleLive] end at their channel's last
  /// stored row; a poll that sees one live opens it again. Returns blocks
  /// deleted.
  Future<int> prune(DateTime now) async {
    final cutoff = now.toUtc().subtract(retention).millisecondsSinceEpoch;
    final stale = now.toUtc().subtract(staleLive).millisecondsSinceEpoch;
    final cap = channelCapBytes;
    return _db.transaction((txn) async {
      var deleted = await txn.rawDelete(
        'DELETE FROM blocks WHERE end_ts < ? AND NOT EXISTS ($_pinnedBlock)',
        [cutoff],
      );
      await txn.rawDelete(
        'DELETE FROM minute_counts WHERE minute < ? AND NOT EXISTS ('
        'SELECT 1 FROM pins p WHERE p.channel = minute_counts.channel '
        'AND p.start_ts <= minute_counts.minute * 60000 + 59999 '
        'AND p.end_ts >= minute_counts.minute * 60000)',
        [cutoff ~/ 60000],
      );
      await txn.rawDelete(
        'DELETE FROM streams WHERE ended_at < ? AND NOT EXISTS ('
        'SELECT 1 FROM pins p WHERE p.channel = streams.channel '
        'AND p.start_ts <= streams.ended_at AND p.end_ts >= streams.started_at)',
        [cutoff],
      );
      await txn.rawDelete(
        'DELETE FROM moderation WHERE to_ts < ? AND NOT EXISTS ('
        'SELECT 1 FROM pins p WHERE p.channel = moderation.channel '
        'AND p.start_ts <= moderation.to_ts AND p.end_ts >= moderation.from_ts)',
        [cutoff],
      );
      await txn.rawDelete(
        'DELETE FROM ref_ids WHERE ts < ? AND NOT EXISTS ('
        'SELECT 1 FROM pins p WHERE p.channel = ref_ids.channel '
        'AND p.start_ts <= ref_ids.ts AND p.end_ts >= ref_ids.ts)',
        [cutoff],
      );
      await txn.rawUpdate(
        'UPDATE streams SET ended_at = max(started_at, ifnull(('
        'SELECT max(end_ts) FROM blocks b WHERE b.channel = streams.channel'
        '), started_at)) WHERE ended_at IS NULL AND started_at < ? '
        'AND NOT EXISTS (SELECT 1 FROM blocks b '
        'WHERE b.channel = streams.channel AND b.end_ts >= ?)',
        [stale, stale],
      );
      if (cap == null) return deleted;
      // Kept days are the user's own and never count toward the cap.
      final over = await txn.rawQuery(
        'SELECT channel FROM blocks WHERE NOT EXISTS ($_pinnedBlock) '
        'GROUP BY channel HAVING SUM(length(data)) > ?',
        [cap],
      );
      for (final row in over) {
        final channel = row['channel'] as String;
        final blocks = await txn.rawQuery(
          'SELECT id, length(data) AS size FROM blocks '
          'WHERE channel = ? AND NOT EXISTS ($_pinnedBlock) '
          'ORDER BY end_ts DESC',
          [channel],
        );
        var kept = 0;
        final drop = <int>[];
        for (final b in blocks) {
          kept += b['size'] as int;
          if (kept > cap) drop.add(b['id'] as int);
        }
        for (var i = 0; i < drop.length; i += 500) {
          final ids = drop.skip(i).take(500);
          deleted += await txn.rawDelete(
            'DELETE FROM blocks WHERE id IN (${ids.join(',')})',
          );
        }
        // The rail shows no activity older than the rows that remain, kept
        // days aside.
        await txn.rawDelete(
          'DELETE FROM minute_counts WHERE channel = ? AND minute < ('
          'SELECT min(start_ts) / 60000 FROM blocks WHERE channel = ? '
          'AND NOT EXISTS ($_pinnedBlock)'
          ') AND NOT EXISTS (SELECT 1 FROM pins p WHERE p.channel = ? '
          'AND p.start_ts <= minute_counts.minute * 60000 + 59999 '
          'AND p.end_ts >= minute_counts.minute * 60000)',
          [channel, channel, channel],
        );
      }
      return deleted;
    });
  }
}

/// Rebuilds the user tables from joined table strings, each entry at its
/// saved id.
UserTables parseJoinedTables(
  List<String> users,
  List<String> looks,
  List<String> states,
) {
  Iterable<List<String>> rows(List<String> joined) => [
    for (final g in joined)
      for (final row in g.split('\u001e')) row.split('\u001f'),
  ];

  final t = UserTables();
  for (final r in rows(users)) {
    t.putWho(
      int.parse(r[0]),
      Who(userId: r[1], login: r[2], displayName: r[4] == '1' ? null : r[3]),
    );
  }
  for (final r in rows(looks)) {
    final extra = r[4];
    t.putLook(
      int.parse(r[0]),
      Look(
        color: r[2] == '1' ? null : r[1],
        badges: r[3],
        extra: extra.isEmpty
            ? const []
            : [
                for (final pair in jsonDecode(extra) as List)
                  ((pair as List)[0] as String, pair[1] as String),
              ],
      ),
    );
  }
  for (final r in rows(states)) {
    t.putState(int.parse(r[0]), int.parse(r[1]), int.parse(r[2]));
  }
  return t;
}

/// Each group of packed blocks merged into one block in the given order, or
/// null for a group with a block that fails to decode.
List<Uint8List?> mergeBlocks(List<List<Uint8List>> groups) => [
  for (final g in groups)
    () {
      try {
        return ArchiveBlock.encode([
          for (final b in g) ...ArchiveBlock.decode(b),
        ]);
      } on ArchiveFormatException {
        return null;
      }
    }(),
];

/// The thread root each reply in [rows] answers (its parent when the root is
/// missing), with the time of the newest reply to it. Roots keep their ids
/// so archived threads still group; a reply carries its parent's name and
/// text itself.
Map<String, int> replyRoots(Iterable<ArchiveRow> rows) {
  final out = <String, int>{};
  for (final r in rows) {
    final root = r.threadRootId ?? r.replyParentId;
    if (root == null) continue;
    final ts = r.timestampMs;
    if ((out[root] ?? -1) < ts) out[root] = ts;
  }
  return out;
}

/// Each block re-packed without message ids outside [keep] and without
/// shared-chat source ids, or null for a damaged one.
List<Uint8List?> stripBlocks(List<Uint8List> blocks, Set<String> keep) => [
  for (final b in blocks)
    () {
      try {
        return ArchiveBlock.encode([
          for (final r in ArchiveBlock.decode(b))
            r.withoutIds(keep: keep.contains(r.messageId)),
        ]);
      } on ArchiveFormatException {
        return null;
      }
    }(),
];

/// Each block re-packed with [edits] applied: rows to remove are dropped, rows
/// to delete get the flag. Returns the new bytes (null when unchanged or
/// damaged), the edit ids the block matched, and removed rows per epoch minute.
List<({Uint8List? data, Set<String> applied, Map<int, int> removedMinutes})>
bakeBlocks(List<Uint8List> blocks, Map<String, ArchiveEdit> edits) => [
  for (final b in blocks)
    () {
      try {
        final rows = <ArchiveRow>[];
        final applied = <String>{};
        final removedMinutes = <int, int>{};
        for (final r in ArchiveBlock.decode(b)) {
          final id = r.messageId;
          final edit = id == null ? null : edits[id];
          if (edit == null) {
            rows.add(r);
          } else if (edit == ArchiveEdit.remove) {
            applied.add(id!);
            final minute = r.timestampMs ~/ 60000;
            removedMinutes.update(minute, (n) => n + 1, ifAbsent: () => 1);
          } else {
            applied.add(id!);
            rows.add(r.asDeleted());
          }
        }
        if (applied.isEmpty) {
          return (
            data: null,
            applied: applied,
            removedMinutes: const <int, int>{},
          );
        }
        return (
          data: ArchiveBlock.encode(rows),
          applied: applied,
          removedMinutes: removedMinutes,
        );
      } on ArchiveFormatException {
        return (
          data: null,
          applied: <String>{},
          removedMinutes: const <int, int>{},
        );
      }
    }(),
];

/// The search vocabulary in memory: words in id order and their ids.
class _Vocab {
  _Vocab();

  /// Rebuilds from stored runs. A run that overlaps one before it skips the
  /// overlap; a gap pads with empty words, so ids stay where they were.
  factory _Vocab.fromChunks(List<(int, Uint8List)> chunks) {
    final v = _Vocab();
    for (final (first, data) in chunks) {
      while (v.words.length < first) {
        v.words.add('');
      }
      final run = decodeVocabChunk(data);
      for (var i = v.words.length - first; i < run.length; i++) {
        v.ids[run[i]] = v.words.length;
        v.words.add(run[i]);
      }
    }
    return v;
  }

  final List<String> words = [];
  final Map<String, int> ids = {};

  int get length => words.length;

  /// Ids of [ws], adding the new ones.
  List<int> assign(Iterable<String> ws) => [
    for (final w in ws)
      ids.putIfAbsent(w, () {
        words.add(w);
        return words.length - 1;
      }),
  ];

  /// Swaps in [replacement], ids by position.
  void replaceWith(List<String> replacement) {
    words
      ..clear()
      ..addAll(replacement);
    ids
      ..clear()
      ..addAll({for (var i = 0; i < words.length; i++) words[i]: i});
    _joined = null;
  }

  /// Drops words from id [length] on, after a write that added them failed.
  void truncate(int length) {
    for (var i = length; i < words.length; i++) {
      ids.remove(words[i]);
    }
    words.length = length;
    _joined = null;
  }

  // Every word joined by newlines with each word's offset: one flat string
  // and one typed list cross to an isolate cheaply. Rebuilt when words
  // change.
  String? _joined;
  Int32List _starts = Int32List(0);

  /// [words] as a newline-joined string and each word's offset in it.
  (String, Int32List) joined() {
    var joined = _joined;
    if (joined == null || _starts.length != words.length) {
      joined = _joined = words.join('\n');
      _starts = Int32List(words.length);
      var at = 0;
      for (var i = 0; i < words.length; i++) {
        _starts[i] = at;
        at += words[i].length + 1;
      }
    }
    return (joined, _starts);
  }
}

/// Per token (none holding a newline), the ids of the words in [joined]
/// (see [_Vocab.joined]) that contain it.
List<Set<int>> wordsContaining(
  String joined,
  Int32List starts,
  List<String> tokens,
) => [
  for (final t in tokens)
    () {
      final out = <int>{};
      var p = joined.indexOf(t);
      while (p >= 0) {
        // The word holding offset p: the last start at or before it.
        var lo = 0;
        var hi = starts.length;
        while (hi - lo > 1) {
          final mid = (lo + hi) >> 1;
          if (starts[mid] <= p) {
            lo = mid;
          } else {
            hi = mid;
          }
        }
        out.add(lo);
        if (lo + 1 >= starts.length) break;
        p = joined.indexOf(t, starts[lo + 1]);
      }
      return out;
    }(),
];

/// Every word id the packed [lists] hold, ascending. A damaged list holds
/// none.
List<int> usedWords(List<Uint8List> lists) {
  final used = <int>{};
  for (final l in lists) {
    try {
      used.addAll(decodeWordList(l));
    } on ArchiveFormatException {
      continue;
    }
  }
  return used.toList()..sort();
}

/// [lists] with each id replaced by its index in [used] (ascending). A
/// damaged list comes back null, so indexing builds it again.
List<Uint8List?> renumberWords(List<Uint8List> lists, List<int> used) {
  final to = {for (var i = 0; i < used.length; i++) used[i]: i};
  return [
    for (final l in lists)
      () {
        try {
          return encodeWordList([for (final id in decodeWordList(l)) to[id]!]);
        } on ArchiveFormatException {
          return null;
        }
      }(),
  ];
}

/// Each block's distinct search words, the user states that wrote it, and
/// every user state its rows name; empty for a damaged one.
List<({Set<String> words, Set<int> states, Set<int> all})> blockWords(
  List<Uint8List> blocks,
) => [
  for (final b in blocks)
    () {
      try {
        final words = <String>{};
        final states = <int>{};
        final all = <int>{};
        for (final r in ArchiveBlock.decode(b)) {
          all.add(r.user);
          if (r.isSystem) continue;
          words.addAll(searchWords(r.text));
          states.add(r.user);
        }
        return (words: words, states: states, all: all);
      } on ArchiveFormatException {
        return (words: <String>{}, states: <int>{}, all: <int>{});
      }
    }(),
];

/// Whether each block may hold a match (see [ArchiveStore.searchBlocks]);
/// [wantSenders] is per block. A missing or damaged list matches, so
/// unindexed blocks are searched.
List<bool> matchBlocks(
  List<Uint8List?> words,
  List<Uint8List?> senders,
  List<List<Set<int>>>? wantWords,
  List<Set<int>?> wantSenders,
) {
  bool has(Uint8List? list, bool Function(Set<int> ids) test) {
    if (list == null) return true;
    try {
      return test(decodeWordList(list).toSet());
    } on ArchiveFormatException {
      return true;
    }
  }

  return [
    for (var i = 0; i < words.length; i++)
      (wantWords != null &&
              has(
                words[i],
                (ids) => wantWords.any(
                  (all) => all.every((s) => s.any(ids.contains)),
                ),
              )) ||
          (wantSenders[i] != null &&
              has(senders[i], (ids) => wantSenders[i]!.any(ids.contains))),
  ];
}
