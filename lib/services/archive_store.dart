import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../archive/archive_block.dart';
import '../archive/archive_io.dart';
import '../archive/archive_row.dart';
import '../archive/archive_users.dart';
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

  static const int schemaVersion = 5;
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
    await _createEmoteDefs(db);
    await _addBlockFlags(db);
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

  /// Third-party emotes as they were when first archived, so history shows
  /// an emote after its set drops or renames it. Written once per key
  /// ([ArchiveToken.key]) and never pruned: a channel uses thousands at most.
  static Future<void> _createEmoteDefs(Database db) =>
      db.execute('''CREATE TABLE emote_defs(
         channel TEXT NOT NULL, key TEXT NOT NULL, json TEXT NOT NULL,
         PRIMARY KEY(channel, key)) WITHOUT ROWID''');

  /// Per block: `refs` once its reply parent and root ids are in `ref_ids`
  /// (new blocks at seal, older ones by [backfillRefs]), and `stripped`
  /// once its message ids are gone ([strip]).
  static Future<void> _addBlockFlags(Database db) async {
    await db.execute(
      'ALTER TABLE blocks ADD COLUMN refs INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE blocks ADD COLUMN stripped INTEGER NOT NULL DEFAULT 0',
    );
  }

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

  /// Schema upgrade hook: add one `if (from < n)` step per version bump.
  /// Version 1 data is never touched; each step only adds tables.
  static Future<void> migrate(Database db, int from, int to) async {
    if (from < 2) {
      await _createThreads(db);
    }
    if (from < 3) {
      await _createModeration(db);
    }
    if (from < 4) {
      await _createEmoteDefs(db);
    }
    if (from < 5) {
      await _addBlockFlags(db);
    }
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
  /// the number of rows the block adds.
  Future<void> appendBlock({
    required String channel,
    required int startTs,
    required int endTs,
    required int count,
    required Uint8List data,
    required Map<int, int> minutes,
    Map<String, String> emoteDefs = const {},
    Set<String> refIds = const {},
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
        'refs': 1,
      });
      for (final id in refIds) {
        b.insert('ref_ids', {
          'channel': channel,
          'message_id': id,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
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

  /// Background upkeep after a prune: merge small blocks, record reply
  /// references of blocks sealed before `ref_ids` was kept, then strip ids.
  Future<void> _upkeep(DateTime now) async {
    await compact(now);
    await backfillRefs();
    await strip();
  }

  /// Message ids kept per channel, newest first. Robotty's fetch (800) and
  /// the live buffer dedup by id, and replies and mod actions need them;
  /// past this only reply roots and parents keep theirs.
  static const int keepIdRows = 1000;

  /// Records the reply parent and root ids of blocks sealed before they were
  /// kept at seal. Returns blocks done.
  Future<int> backfillRefs() async {
    var done = 0;
    while (true) {
      final r = await _db.rawQuery(
        'SELECT id, channel, data FROM blocks WHERE refs = 0 LIMIT 64',
      );
      if (r.isEmpty) return done;
      final refs = await _refsOffIsolate([
        for (final row in r) row['data']! as Uint8List,
      ]);
      await _db.transaction((txn) async {
        final b = txn.batch();
        for (var i = 0; i < r.length; i++) {
          for (final id in refs[i]) {
            b.insert('ref_ids', {
              'channel': r[i]['channel'],
              'message_id': id,
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
          b.rawUpdate('UPDATE blocks SET refs = 1 WHERE id = ?', [r[i]['id']]);
        }
        await b.commit(noResult: true);
      });
      done += r.length;
    }
  }

  /// Drops message ids from blocks wholly past the newest [keepIdRows] rows
  /// of their channel, keeping every id a reply references. A channel with
  /// references not yet recorded waits. Returns blocks stripped.
  Future<int> strip() async {
    var stripped = 0;
    final channels = await _db.rawQuery(
      'SELECT channel, MIN(refs) AS r FROM blocks GROUP BY channel',
    );
    for (final c in channels) {
      if (c['r'] != 1) continue;
      final channel = c['channel']! as String;
      final blocks = await _db.rawQuery(
        'SELECT id, count, stripped FROM blocks WHERE channel = ? '
        'ORDER BY end_ts DESC, id DESC',
        [channel],
      );
      final targets = <int>[];
      var newer = 0;
      for (final b in blocks) {
        if (newer >= keepIdRows && b['stripped'] == 0) {
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

  static Future<List<Set<String>>> _refsOffIsolate(List<Uint8List> blocks) =>
      Isolate.run(() => blockRefs(blocks));

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
      data.add([for (final id in g) byId[id]! as Uint8List]);
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

/// Rebuilds the user tables from joined table strings, interning in id
/// order so every id lands at its saved index.
UserTables parseJoinedTables(
  List<String> users,
  List<String> looks,
  List<String> states,
) {
  List<List<String>> rows(List<String> joined) {
    final out = [
      for (final g in joined)
        for (final row in g.split('\u001e')) row.split('\u001f'),
    ];
    out.sort((a, b) => int.parse(a[0]).compareTo(int.parse(b[0])));
    return out;
  }

  final t = UserTables();
  for (final r in rows(users)) {
    t.internWho(
      Who(userId: r[1], login: r[2], displayName: r[4] == '1' ? null : r[3]),
    );
  }
  for (final r in rows(looks)) {
    final extra = r[4];
    t.internLook(
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
    t.internState(int.parse(r[1]), int.parse(r[2]));
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

/// Reply parent and root ids each block references; empty for a damaged one.
List<Set<String>> blockRefs(List<Uint8List> blocks) => [
  for (final b in blocks)
    () {
      try {
        return {
          for (final r in ArchiveBlock.decode(b)) ...[
            ?r.replyParentId,
            ?r.threadRootId,
          ],
        };
      } on ArchiveFormatException {
        return <String>{};
      }
    }(),
];

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
