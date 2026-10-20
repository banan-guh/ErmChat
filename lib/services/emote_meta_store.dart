import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/log.dart';
import '../util/prefs.dart';

/// File-backed persistence for MB-scale emote metadata blobs.
class EmoteMetaStore {
  EmoteMetaStore._();

  static final EmoteMetaStore I = EmoteMetaStore._();

  // Cache keys moved through emotes3_ and emotes4_ to emotes5_ as the catalog
  // shape changed, so legacy prefixes still map to files during migration.
  // emote_usage and seventv_paints_ moved to [CacheDb] and stay mapped only
  // so it can delete their old files.
  static const _prefixes = [
    'emotes3_',
    'emotes4_',
    'emotes5_',
    'emote_usage',
    'seventv_paints_',
  ];
  static const _dirName = 'emote_meta';

  // Shared by concurrent callers, so none reads before the dir resolves.
  Future<Directory?>? _dir;
  bool _migrated = false;
  int _tmpSeq = 0;
  final _fallback = <String, String>{};

  /// Test seam: override blob directory.
  @visibleForTesting
  void overrideDirectory(Directory dir) {
    _dir = Future.value(dir);
    _migrated = false;
    _fallback.clear();
  }

  @visibleForTesting
  void reset() {
    _dir = null;
    _migrated = false;
    _fallback.clear();
  }

  Future<Directory?> _resolveDir() => _dir ??= _openDir();

  Future<Directory?> _openDir() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}${Platform.pathSeparator}$_dirName');
      await dir.create(recursive: true);
      return dir;
    } catch (_) {
      // No docs dir: degrade to in-memory fallback.
      return null;
    }
  }

  bool _hasPrefix(String key) => _prefixes.any(key.startsWith);

  File? _fileFor(String key, Directory dir) {
    if (!_hasPrefix(key) || key.contains(Platform.pathSeparator)) {
      return null;
    }
    return File('${dir.path}${Platform.pathSeparator}$key.json');
  }

  /// Migrates legacy prefs to files; later calls are no-ops.
  Future<void> migrateFromPrefs(SharedPreferences prefs) async {
    if (_migrated) return;
    _migrated = true;
    try {
      final dir = await _resolveDir();
      for (final key in prefs.getKeys().where(_hasPrefix)) {
        final raw = prefs.getString(key);
        if (raw == null) continue;
        final file = dir == null ? null : _fileFor(key, dir);
        try {
          if (file != null) {
            // A file already on disk is newer than the pref copy.
            if (!await file.exists()) await _writeAtomic(file, raw);
            await prefs.remove(key);
          }
        } catch (_) {
          // Keep key; read fallback still finds it.
        }
      }
    } catch (_) {
      // Prefs unavailable: skip migration.
    }
  }

  Future<String?> read(String key) async {
    try {
      final dir = await _resolveDir();
      final file = dir == null ? null : _fileFor(key, dir);
      if (file != null && await file.exists()) {
        return await file.readAsString();
      }
      return _fallback[key] ?? (await _legacyRead(key));
    } catch (_) {
      return _fallback[key];
    }
  }

  Future<void> write(String key, String contents) async {
    try {
      final dir = await _resolveDir();
      final file = dir == null ? null : _fileFor(key, dir);
      if (file != null) {
        await _writeAtomic(file, contents);
        return;
      }
    } catch (e) {
      logDebug('[EmoteMetaStore] write $key failed, kept in memory: $e');
    }
    _fallback[key] = contents;
  }

  // Each write gets its own temp so overlapping writes never share one.
  Future<void> _writeAtomic(File file, String contents) async {
    final tmp = File('${file.path}.${_tmpSeq++}.tmp');
    try {
      await tmp.writeAsString(contents, flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      try {
        await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> delete(String key) async {
    _fallback.remove(key);
    try {
      final dir = await _resolveDir();
      final file = dir == null ? null : _fileFor(key, dir);
      if (file != null && await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  /// All stored registry keys (disk + fallback).
  Future<Set<String>> keys() async {
    try {
      final dir = await _resolveDir();
      final fileKeys = dir == null
          ? const <String>{}
          : (await dir.list().toList())
                .whereType<File>()
                .map((f) {
                  final name = f.uri.pathSegments.last;
                  return name.endsWith('.json')
                      ? name.substring(0, name.length - '.json'.length)
                      : null;
                })
                .whereType<String>()
                .toSet();
      return {...fileKeys, ..._fallback.keys};
    } catch (_) {
      return {..._fallback.keys};
    }
  }

  Future<String?> _legacyRead(String key) async {
    try {
      final prefs = await Prefs.load();
      return prefs.rawGetString(key);
    } catch (_) {
      return null;
    }
  }
}
