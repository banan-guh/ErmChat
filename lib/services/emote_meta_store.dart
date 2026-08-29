import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// File-backed persistence for MB-scale emote metadata blobs.
class EmoteMetaStore {
  EmoteMetaStore._();

  static final EmoteMetaStore I = EmoteMetaStore._();

  static const _prefix = 'emotes3_';
  static const _dirName = 'emote_meta';

  Directory? _dir;
  bool _dirResolved = false;
  bool _migrated = false;
  final _fallback = <String, String>{};

  /// Test seam: override blob directory.
  @visibleForTesting
  void overrideDirectory(Directory dir) {
    _dir = dir;
    _dirResolved = true;
    _migrated = false;
    _fallback.clear();
  }

  @visibleForTesting
  void reset() {
    _dir = null;
    _dirResolved = false;
    _migrated = false;
    _fallback.clear();
  }

  Future<Directory?> _resolveDir() async {
    if (_dirResolved) return _dir;
    _dirResolved = true;
    try {
      final docs = await getApplicationDocumentsDirectory();
      _dir = Directory('${docs.path}${Platform.pathSeparator}$_dirName');
      await _dir!.create(recursive: true);
    } catch (_) {
      // No docs dir: degrade to in-memory fallback.
      _dir = null;
    }
    return _dir;
  }

  File? _fileFor(String key, Directory dir) {
    if (!key.startsWith(_prefix) || key.contains(Platform.pathSeparator)) {
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
      for (final key in prefs.getKeys().where((k) => k.startsWith(_prefix))) {
        final raw = prefs.getString(key);
        if (raw == null) continue;
        final file = dir == null ? null : _fileFor(key, dir);
        try {
          if (file != null) {
            await file.writeAsString(raw, flush: true);
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
        await file.writeAsString(contents);
        return;
      }
    } catch (_) {}
    _fallback[key] = contents;
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
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    } catch (_) {
      return null;
    }
  }
}
