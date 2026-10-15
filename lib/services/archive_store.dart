import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../archive/archive_users.dart';

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
    : whoSaved = tables.whos.length,
      lookSaved = tables.looks.length,
      stateSaved = tables.states.length;

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

  static const int schemaVersion = 3;
  static const Duration retention = Duration(days: 30);
  static const Duration pruneEvery = Duration(hours: 1);

  final Database _db;
  final DateTime Function() _now;
  final Map<String, Future<_ChannelTables>> _tables = {};
  DateTime? _lastPrune;

  /// Opens (creating or migrating) the archive at [path] and prunes once.
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
          await db.rawQuery('PRAGMA journal_mode=WAL');
          await db.execute('PRAGMA synchronous=NORMAL');
        },
        onCreate: (db, version) => _create(db),
        onUpgrade: migrate,
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
           from_ts INTEGER NOT NULL, to_ts INTEGER NOT NULL)''');
    await db.execute(
      'CREATE INDEX moderation_by_end ON moderation(channel, to_ts)',
    );
  }

  /// Schema upgrade hook: add one `if (from < n)` step per version bump.
  /// Version 1 data is never touched; each step only adds tables.
  static Future<void> migrate(Database db, int from, int to) async {
    if (from < 2) {
      await _createThreads(db);
    }
    if (from < 3) {
      await _createModeration(db);
    }
  }

  Future<void> close() => _db.close();

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

  Future<_ChannelTables> _loadTables(String channel) async {
    final t = UserTables();
    await _pages('users', 'user_id, login, display_name', channel, (r) {
      t.internWho(
        Who(
          userId: r['user_id']! as String,
          login: r['login']! as String,
          displayName: r['display_name'] as String?,
        ),
      );
    });
    await _pages('looks', 'color, badges, extra', channel, (r) {
      final extra = r['extra'] as String?;
      t.internLook(
        Look(
          color: r['color'] as String?,
          badges: r['badges']! as String,
          extra: extra == null
              ? const []
              : [
                  for (final pair in jsonDecode(extra) as List)
                    ((pair as List)[0] as String, pair[1] as String),
                ],
        ),
      );
    });
    await _pages('user_states', 'who, look', channel, (r) {
      t.internState(r['who']! as int, r['look']! as int);
    });
    return _ChannelTables(t);
  }

  /// Rows of a per-channel [table] in id order, read in pages: a busy channel
  /// keeps tens of thousands of chatters, and one result that size stalls the
  /// UI isolate while it decodes.
  Future<void> _pages(
    String table,
    String cols,
    String channel,
    void Function(Map<String, Object?> row) each,
  ) async {
    const page = 2000;
    var after = -1;
    while (true) {
      final rows = await _db.rawQuery(
        'SELECT id, $cols FROM $table WHERE channel = ? AND id > ? '
        'ORDER BY id LIMIT $page',
        [channel, after],
      );
      rows.forEach(each);
      if (rows.length < page) return;
      after = rows.last['id']! as int;
    }
  }

  // ---- Writes --------------------------------------------------------------

  /// Stores one sealed block, any user rows not yet saved for [channel], and
  /// the per-minute counts, in one transaction. [minutes] maps epoch minute to
  /// the number of rows the block adds.
  Future<void> appendBlock({
    required String channel,
    required int startTs,
    required int endTs,
    required int count,
    required Uint8List data,
    required Map<int, int> minutes,
  }) async {
    await tables(channel);
    final saved = await _tables[channel]!;
    final t = saved.tables;
    final whoTo = t.whos.length;
    final lookTo = t.looks.length;
    final stateTo = t.states.length;
    await _db.transaction((txn) async {
      final b = txn.batch();
      for (var i = saved.whoSaved; i < whoTo; i++) {
        final w = t.whos[i];
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
        b.insert('user_states', {
          'channel': channel,
          'id': i,
          'who': t.states[i].who,
          'look': t.states[i].look,
        });
      }
      b.insert('blocks', {
        'channel': channel,
        'start_ts': startTs,
        'end_ts': endTs,
        'count': count,
        'data': data,
      });
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
    saved.whoSaved = whoTo;
    saved.lookSaved = lookTo;
    saved.stateSaved = stateTo;
    final span = _maxSpan[channel];
    if (span != null && endTs - startTs > span) {
      _maxSpan[channel] = endTs - startTs;
    }
  }

  /// Keeps [startTs]..[endTs] (epoch ms, inclusive) out of retention pruning.
  Future<void> addPin(String channel, int startTs, int endTs, String kind) =>
      _db.insert('pins', {
        'channel': channel,
        'start_ts': startTs,
        'end_ts': endTs,
        'kind': kind,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

  /// Records a broadcast seen live. A later call for the same [id] only
  /// clears its end, since Helix listing it live means it has not ended.
  Future<void> putStream({
    required String channel,
    required String id,
    required int startedTs,
    String? title,
    String? game,
  }) async {
    final b = _db.batch()
      ..insert('streams', {
        'stream_id': id,
        'channel': channel,
        'started_at': startedTs,
        'title': title,
        'game': game,
      }, conflictAlgorithm: ConflictAlgorithm.ignore)
      ..rawUpdate('UPDATE streams SET ended_at = NULL WHERE stream_id = ?', [
        id,
      ]);
    await b.commit(noResult: true);
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
    int toTs,
  ) async {
    await _db.insert('moderation', {
      'channel': channel,
      'login': login,
      'from_ts': fromTs,
      'to_ts': toTs,
    });
    _moderated[channel] = Future.value(true);
  }

  // ---- Reads ---------------------------------------------------------------

  /// Channels known to have moderation rows, so decoding a clean channel
  /// never queries the table.
  final Map<String, Future<bool>> _moderated = {};

  /// Moderation ranges of [channel] overlapping [fromTs]..[toTs].
  Future<List<({String? login, int fromTs, int toTs})>> moderation(
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
      'SELECT login, from_ts, to_ts FROM moderation '
      'WHERE channel = ? AND to_ts >= ? AND from_ts <= ?',
      [channel, fromTs, toTs],
    );
    return [
      for (final row in r)
        (
          login: row['login'] as String?,
          fromTs: row['from_ts']! as int,
          toTs: row['to_ts']! as int,
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
    return [for (final id in ids) byId[id]!];
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
      ({String id, int startedTs, int? endedTs, String? title, String? game})
    >
  >
  streams(String channel, int fromTs) async {
    final r = await _db.rawQuery(
      'SELECT stream_id, started_at, ended_at, title, game FROM streams '
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

  /// Prunes when none ran in the last [pruneEvery]. Returns blocks deleted.
  Future<int> pruneIfDue() async {
    final now = _now();
    final last = _lastPrune;
    if (last != null && now.difference(last) < pruneEvery) {
      return 0;
    }
    _lastPrune = now;
    return prune(now);
  }

  /// Deletes blocks, minute counts, moderation and ended broadcasts older than
  /// [retention] relative to [now], except blocks and counts overlapping a
  /// pin. Returns blocks deleted.
  Future<int> prune(DateTime now) async {
    final cutoff = now.toUtc().subtract(retention).millisecondsSinceEpoch;
    return _db.transaction((txn) async {
      final deleted = await txn.rawDelete(
        'DELETE FROM blocks WHERE end_ts < ? AND NOT EXISTS ('
        'SELECT 1 FROM pins p WHERE p.channel = blocks.channel '
        'AND p.start_ts <= blocks.end_ts AND p.end_ts >= blocks.start_ts)',
        [cutoff],
      );
      await txn.rawDelete(
        'DELETE FROM minute_counts WHERE minute < ? AND NOT EXISTS ('
        'SELECT 1 FROM pins p WHERE p.channel = minute_counts.channel '
        'AND p.start_ts <= minute_counts.minute * 60000 + 59999 '
        'AND p.end_ts >= minute_counts.minute * 60000)',
        [cutoff ~/ 60000],
      );
      await txn.rawDelete('DELETE FROM streams WHERE ended_at < ?', [cutoff]);
      await txn.rawDelete('DELETE FROM moderation WHERE to_ts < ?', [cutoff]);
      return deleted;
    });
  }
}
