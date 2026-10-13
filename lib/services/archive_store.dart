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

  static const int schemaVersion = 1;
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
  }

  /// Schema upgrade hook: add one `if (from < n)` step per version bump.
  static Future<void> migrate(Database db, int from, int to) async {}

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
    final args = [channel];
    for (final r in await _db.rawQuery(
      'SELECT user_id, login, display_name FROM users WHERE channel = ? ORDER BY id',
      args,
    )) {
      t.internWho(
        Who(
          userId: r['user_id']! as String,
          login: r['login']! as String,
          displayName: r['display_name'] as String?,
        ),
      );
    }
    for (final r in await _db.rawQuery(
      'SELECT color, badges, extra FROM looks WHERE channel = ? ORDER BY id',
      args,
    )) {
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
    }
    for (final r in await _db.rawQuery(
      'SELECT who, look FROM user_states WHERE channel = ? ORDER BY id',
      args,
    )) {
      t.internState(r['who']! as int, r['look']! as int);
    }
    return _ChannelTables(t);
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
  }

  /// Keeps [startTs]..[endTs] (epoch ms, inclusive) out of retention pruning.
  Future<void> addPin(String channel, int startTs, int endTs, String kind) =>
      _db.insert('pins', {
        'channel': channel,
        'start_ts': startTs,
        'end_ts': endTs,
        'kind': kind,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

  // ---- Reads ---------------------------------------------------------------

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

  Future<StoredBlock?> blockAt(String channel, int key) async {
    final r = await _db.rawQuery(
      'SELECT $_cols FROM blocks WHERE channel = ? AND id = ?',
      [channel, key],
    );
    return r.isEmpty ? null : _block(r.first);
  }

  /// Per-minute row counts for epoch minutes in [fromMinute]..[toMinute].
  Future<List<({int minute, int count})>> minuteCounts(
    String channel,
    int fromMinute,
    int toMinute,
  ) async {
    final r = await _db.rawQuery(
      'SELECT minute, count FROM minute_counts '
      'WHERE channel = ? AND minute >= ? AND minute <= ? ORDER BY minute',
      [channel, fromMinute, toMinute],
    );
    return [
      for (final row in r)
        (minute: row['minute']! as int, count: row['count']! as int),
    ];
  }

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

  /// Deletes blocks and minute counts older than [retention] relative to
  /// [now], except ranges overlapping a pin. Returns blocks deleted.
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
      return deleted;
    });
  }
}
