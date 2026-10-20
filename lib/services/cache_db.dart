import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../util/log.dart';
import 'emote_meta_store.dart';

/// One emote's view history as stored: last use (epoch ms), the newest unix
/// hour of its window, and its hourly counts joined by commas.
typedef UsageRow = ({String url, int lastUsed, int hour, String buckets});

/// A chatter's 7TV paint and when it was confirmed (epoch ms).
typedef PaintUserRow = ({String userId, String paintId, int at});

/// SQLite store for emote view history and 7TV name paints. A change writes
/// its own rows instead of rewriting a JSON blob. Everything here can be
/// fetched or rebuilt, so a file that fails to open or to check is deleted
/// and started over, and a store that cannot open leaves callers in memory.
class CacheDb {
  CacheDb._();

  static final CacheDb I = CacheDb._();

  static const _fileName = 'cache.db';
  static const _schemaVersion = 1;
  static const _walLimit = 1024 * 1024;

  /// The JSON blobs these tables replace, deleted when the file is created.
  static const _legacyKeys = [
    'emote_usage',
    'seventv_paints_catalog',
    'seventv_paints_users',
  ];

  Future<Database?>? _db;
  DatabaseFactory? _factory;
  String? _path;

  /// Test seam: open at [path] through [factory] from the next call on.
  @visibleForTesting
  void overrideForTesting(DatabaseFactory factory, String path) {
    _factory = factory;
    _path = path;
    _db = null;
  }

  /// Closes the store; the next call reopens it.
  @visibleForTesting
  Future<void> reset() async {
    final db = await _db;
    _db = null;
    await db?.close();
  }

  DatabaseFactory get _dbFactory => _factory ?? databaseFactory;

  Future<Database?> _open() => _db ??= _openFresh();

  Future<Database?> _openFresh() async {
    final String path;
    try {
      path =
          _path ??
          '${(await getApplicationSupportDirectory()).path}'
              '${Platform.pathSeparator}$_fileName';
    } catch (e) {
      logDebug('[CacheDb] no support directory: $e');
      return null;
    }
    // A second try runs on a deleted file, so only a broken platform fails.
    for (var attempt = 0; attempt < 2; attempt++) {
      var created = false;
      try {
        final db = await _dbFactory.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: _schemaVersion,
            onConfigure: (db) async {
              await db.execute('PRAGMA auto_vacuum=FULL');
              await db.rawQuery('PRAGMA journal_mode=WAL');
              await db.execute('PRAGMA synchronous=NORMAL');
              await db.rawQuery('PRAGMA journal_size_limit=$_walLimit');
            },
            onCreate: (db, _) async {
              created = true;
              await _create(db);
            },
            // Any other schema is a cache from another build: start over.
            onUpgrade: (db, _, _) async {
              created = true;
              await _recreate(db);
            },
            onDowngrade: (db, _, _) async {
              created = true;
              await _recreate(db);
            },
          ),
        );
        final check = await db.rawQuery('PRAGMA quick_check');
        if ('${check.first.values.first}' != 'ok') {
          await db.close();
          throw StateError('quick_check: ${check.first.values.first}');
        }
        if (created) {
          for (final key in _legacyKeys) {
            await EmoteMetaStore.I.delete(key);
          }
        }
        return db;
      } catch (e) {
        logDebug('[CacheDb] open failed, starting over: $e');
        try {
          await _dbFactory.deleteDatabase(path);
        } catch (_) {}
      }
    }
    return null;
  }

  static Future<void> _create(Database db) async {
    await db.execute(
      'CREATE TABLE emote_usage (url TEXT PRIMARY KEY, last_used INTEGER '
      'NOT NULL, hour INTEGER NOT NULL, buckets TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE paint_users (user_id TEXT PRIMARY KEY, paint_id TEXT '
      'NOT NULL, at INTEGER NOT NULL)',
    );
    await db.execute('CREATE INDEX paint_users_at ON paint_users (at)');
    await db.execute(
      'CREATE TABLE paints (id TEXT PRIMARY KEY, data TEXT NOT NULL)',
    );
  }

  static Future<void> _recreate(Database db) async {
    for (final table in ['emote_usage', 'paint_users', 'paints']) {
      await db.execute('DROP TABLE IF EXISTS $table');
    }
    await _create(db);
  }

  /// Runs [op], or returns [fallback] when the store is unavailable or the
  /// call fails. A corrupt file is dropped so the next call starts over.
  Future<T> _run<T>(T fallback, Future<T> Function(Database db) op) async {
    final db = await _open();
    if (db == null) return fallback;
    try {
      return await op(db);
    } catch (e) {
      logDebug('[CacheDb] $e');
      final message = '$e'.toLowerCase();
      if (message.contains('corrupt') ||
          message.contains('malformed') ||
          message.contains('not a database')) {
        await _discard(db);
      }
      return fallback;
    }
  }

  Future<void> _discard(Database db) async {
    if (!identical(await _db, db)) return;
    _db = null;
    try {
      await db.close();
    } catch (_) {}
    try {
      await _dbFactory.deleteDatabase(db.path);
    } catch (_) {}
  }

  // ---- Emote usage ---------------------------------------------------------

  Future<List<UsageRow>> usage() => _run(const [], (db) async {
    final rows = await db.query('emote_usage');
    return [
      for (final r in rows)
        if (r['url'] case final String url)
          if (r['last_used'] case final int lastUsed)
            if (r['hour'] case final int hour)
              if (r['buckets'] case final String buckets)
                (url: url, lastUsed: lastUsed, hour: hour, buckets: buckets),
    ];
  });

  /// Upserts [rows] and deletes [removed] in one transaction.
  Future<void> writeUsage(List<UsageRow> rows, Iterable<String> removed) =>
      _run(null, (db) async {
        final batch = db.batch();
        for (final url in removed) {
          batch.delete('emote_usage', where: 'url = ?', whereArgs: [url]);
        }
        for (final r in rows) {
          batch.insert('emote_usage', {
            'url': r.url,
            'last_used': r.lastUsed,
            'hour': r.hour,
            'buckets': r.buckets,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      });

  // ---- 7TV paints ----------------------------------------------------------

  /// Drops assignments confirmed before [beforeMs] and all but the newest
  /// [keep], then returns the rest.
  Future<List<PaintUserRow>> paintUsers({
    required int beforeMs,
    required int keep,
  }) => _run(const [], (db) async {
    await db.delete('paint_users', where: 'at < ?', whereArgs: [beforeMs]);
    await db.rawDelete(
      'DELETE FROM paint_users WHERE user_id NOT IN '
      '(SELECT user_id FROM paint_users ORDER BY at DESC LIMIT ?)',
      [keep],
    );
    final rows = await db.query('paint_users');
    return [
      for (final r in rows)
        if (r['user_id'] case final String userId)
          if (r['paint_id'] case final String paintId)
            if (r['at'] case final int at)
              (userId: userId, paintId: paintId, at: at),
    ];
  });

  /// Upserts [rows] and deletes [removed] in one transaction.
  Future<void> writePaintUsers(
    List<PaintUserRow> rows,
    Iterable<String> removed,
  ) => _run(null, (db) async {
    final batch = db.batch();
    for (final id in removed) {
      batch.delete('paint_users', where: 'user_id = ?', whereArgs: [id]);
    }
    for (final r in rows) {
      batch.insert('paint_users', {
        'user_id': r.userId,
        'paint_id': r.paintId,
        'at': r.at,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  });

  /// Each stored paint's 7TV JSON.
  Future<List<String>> paints() => _run(const [], (db) async {
    final rows = await db.query('paints', columns: ['data']);
    return [
      for (final r in rows)
        if (r['data'] case final String data) data,
    ];
  });

  /// Upserts paints as (id, 7TV JSON).
  Future<void> writePaints(List<(String, String)> paints) =>
      _run(null, (db) async {
        final batch = db.batch();
        for (final (id, data) in paints) {
          batch.insert('paints', {
            'id': id,
            'data': data,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      });
}
