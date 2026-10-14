import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/twitch_message.dart';
import '../util/log.dart';
import '../util/prefs.dart';
import 'archive_store.dart';

// Global cap; evicts the oldest-saved entry first. Saved threads themselves
// are uncapped: every message stays on disk and in memory forever.
const maxSavedThreads = 50;

// Snapshot of a bookmarked thread. The full message log lives alongside in
// memory and on disk, so the Saved tab renders after a restart and keeps
// recording new replies while the channel is joined.
class SavedThread {
  final String channel;
  final String rootId;
  final String login;
  final String author;
  final String preview;
  final DateTime savedAt;

  SavedThread({
    required String channel,
    required this.rootId,
    required this.login,
    required this.author,
    required this.preview,
    required this.savedAt,
  }) : channel = channel.toLowerCase();

  String get key => '$channel:$rootId';

  static String previewFor(String text) {
    final runes = text.runes.toList();
    if (runes.length <= 80) return text;
    return '${String.fromCharCodes(runes.take(80))}...';
  }

  factory SavedThread.fromMessage(
    TwitchMessage msg,
    String rootId, {
    DateTime? now,
  }) {
    return SavedThread(
      channel: msg.channel ?? '',
      rootId: rootId,
      login: msg.login,
      author: msg.displayName.isNotEmpty ? msg.displayName : msg.login,
      preview: previewFor(msg.text),
      savedAt: now ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'channel': channel,
    'rootId': rootId,
    'login': login,
    'author': author,
    'preview': preview,
    'savedAt': savedAt.toUtc().toIso8601String(),
  };

  static SavedThread? fromJson(Map<String, dynamic> json) {
    final channel = (json['channel'] as String? ?? '').toLowerCase();
    final rootId = json['rootId'] as String? ?? '';
    if (channel.isEmpty || rootId.isEmpty) return null;
    final savedAt = DateTime.tryParse(json['savedAt'] as String? ?? '');
    if (savedAt == null) return null;
    return SavedThread(
      channel: channel,
      rootId: rootId,
      login: json['login'] as String? ?? '',
      author: json['author'] as String? ?? '',
      preview: json['preview'] as String? ?? '',
      savedAt: savedAt,
    );
  }
}

// In-memory bookmark list plus the full per-thread message logs, persisted
// in the archive database: one bookmark row per thread and one row per
// message, so a new reply costs one small insert.
//
// Message rows hold the self-contained `TwitchMessage.toJson` encoding rather
// than archive blocks. A block needs the channel's interned user tables saved
// in the same transaction and drops fields the Saved tab shows, and a
// one-message block would not be much smaller than a row of this size.
// A message without an id gets a synthetic id from its time and text, so an
// identical (time, text) pair collapses to one row.
class SavedThreadsStore {
  SavedThreadsStore({
    Future<ArchiveStore?>? store,
    this._legacyDir,
    this._createTimer = Timer.new,
  }) : _store = store ?? Future.value(null);

  static const _migratedKey = 'saved_threads_json_migrated';
  static const _flushDelay = Duration(seconds: 1);
  // Message bytes above which load decodes in an isolate.
  static const _isolateBytes = 64 * 1024;

  final Future<ArchiveStore?> _store;
  final Directory? _legacyDir;
  final Timer Function(Duration, void Function()) _createTimer;

  final List<SavedThread> _threads = [];
  final Map<String, List<TwitchMessage>> _messages = {};
  // Message ids per thread, kept in sync with _messages so append dedupe is
  // O(1) instead of a scan of the whole (uncapped) thread log.
  final Map<String, Set<String>> _messageIds = {};

  Timer? _flushTimer;
  final List<(SavedThread, TwitchMessage)> _pending = [];

  // Open while load() runs: db writes wait on it, and saves made meanwhile
  // merge into the loaded list instead of being replaced by it.
  Completer<void>? _loading;
  final Set<String> _removedWhileLoading = {};
  // Db work runs one task at a time so writes never interleave.
  Future<void> _ioQueue = Future.value();

  List<SavedThread> get threads => List.unmodifiable(_threads);

  List<TwitchMessage> messagesFor(String channel, String rootId) =>
      List.unmodifiable(
        _messages['${channel.toLowerCase()}:$rootId'] ?? const [],
      );

  bool isSaved(String channel, String rootId) => _threads.any(
    (t) => t.channel == channel.toLowerCase() && t.rootId == rootId,
  );

  /// Whether any saved thread belongs to [channel] (stored lowercase).
  bool hasChannel(String channel) => _threads.any((t) => t.channel == channel);

  Set<String> get keys => {for (final t in _threads) t.key};

  static Set<String> _idsOf(Iterable<TwitchMessage> messages) {
    final ids = <String>{};
    for (final m in messages) {
      if (m.messageId != null) ids.add(m.messageId!);
    }
    return ids;
  }

  static StoredThread _stored(SavedThread t) => StoredThread(
    channel: t.channel,
    rootId: t.rootId,
    login: t.login,
    author: t.author,
    preview: t.preview,
    savedAtMs: t.savedAt.millisecondsSinceEpoch,
  );

  static SavedThread _saved(StoredThread t) => SavedThread(
    channel: t.channel,
    rootId: t.rootId,
    login: t.login,
    author: t.author,
    preview: t.preview,
    savedAt: DateTime.fromMillisecondsSinceEpoch(t.savedAtMs, isUtc: true),
  );

  static StoredThreadMessage _row(SavedThread t, TwitchMessage m) {
    final ts = m.timestamp.millisecondsSinceEpoch;
    return StoredThreadMessage(
      channel: t.channel,
      rootId: t.rootId,
      messageId: m.messageId ?? '~$ts-${_fnv(m.text)}',
      ts: ts,
      data: Uint8List.fromList(utf8.encode(jsonEncode(m.toJson()))),
    );
  }

  // FNV-1a; String.hashCode differs between runs, so it cannot key a row.
  static int _fnv(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return h;
  }

  // Saves the thread with its current full log. Returns true when the thread
  // is saved after the call.
  bool saveThread(SavedThread entry, List<TwitchMessage> messages) {
    if (entry.channel.isEmpty || entry.rootId.isEmpty) return false;
    final idx = _threads.indexWhere(
      (t) => t.channel == entry.channel && t.rootId == entry.rootId,
    );
    if (idx >= 0) {
      _threads[idx] = entry;
    } else {
      _threads.insert(0, entry);
      while (_threads.length > maxSavedThreads) {
        _forget(_threads.removeLast());
      }
    }
    final log = List.of(messages);
    _messages[entry.key] = log;
    _messageIds[entry.key] = _idsOf(log);
    _removedWhileLoading.remove(entry.key);
    _pending.removeWhere((p) => p.$1.key == entry.key);
    _enqueue(
      (db) =>
          db.putThread(_stored(entry), [for (final m in log) _row(entry, m)]),
    );
    return true;
  }

  // Returns true when the thread is saved after the call.
  bool toggle(SavedThread entry, [List<TwitchMessage>? messages]) {
    if (entry.channel.isEmpty || entry.rootId.isEmpty) return false;
    if (remove(entry.channel, entry.rootId)) return false;
    return saveThread(entry, messages ?? const []);
  }

  bool remove(String channel, String rootId) {
    final lc = channel.toLowerCase();
    final idx = _threads.indexWhere(
      (t) => t.channel == lc && t.rootId == rootId,
    );
    if (idx < 0) return false;
    _forget(_threads.removeAt(idx));
    return true;
  }

  // Drops [t] from memory and queues the delete of its rows.
  void _forget(SavedThread t) {
    _messages.remove(t.key);
    _messageIds.remove(t.key);
    _pending.removeWhere((p) => p.$1.key == t.key);
    if (_loading != null) _removedWhileLoading.add(t.key);
    _enqueue((db) => db.deleteThread(t.channel, t.rootId));
  }

  // Appends a live message to its saved thread when the message belongs to
  // one. Returns true when appended. The row is written by the next flush.
  bool appendMessage(TwitchMessage msg) {
    final rootId = msg.replyThreadRootId ?? msg.messageId;
    final channel = msg.channel?.toLowerCase();
    if (rootId == null || channel == null) return false;
    final key = '$channel:$rootId';
    final idx = _threads.indexWhere((t) => t.key == key);
    if (idx < 0) return false;
    final log = _messages.putIfAbsent(key, () => []);
    final ids = _messageIds.putIfAbsent(key, () => _idsOf(log));
    final msgId = msg.messageId;
    if (msgId != null && !ids.add(msgId)) return false;
    log.insert(0, msg);
    _pending.add((_threads[idx], msg));
    // The first change arms the write and later ones join it, so a busy
    // thread still reaches disk every second instead of waiting for a quiet
    // one.
    _flushTimer ??= _createTimer(_flushDelay, () {
      unawaited(flush());
    });
    return true;
  }

  /// Writes pending message rows now, in one transaction, and resolves once
  /// all queued db work finishes. Called on app pause and by tests.
  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pending.isNotEmpty) {
      final batch = List.of(_pending);
      _pending.clear();
      _enqueue(
        (db) =>
            db.appendThreadMessages([for (final (t, m) in batch) _row(t, m)]),
      );
    }
    return _ioQueue;
  }

  /// Test seam: resolves once queued db writes finish.
  @visibleForTesting
  Future<void> flushIo() => _ioQueue;

  void _enqueue(Future<void> Function(ArchiveStore db) task) {
    _ioQueue = _ioQueue.then((_) async {
      await _loading?.future;
      try {
        final db = await _store;
        if (db != null) await task(db);
      } catch (e) {
        logDebug('[SavedThreads] write failed: $e');
      }
    });
  }

  /// Loads saved threads from the archive, importing the legacy JSON store
  /// once first. Saves made while loading are kept and merged ahead of the
  /// loaded list. With no database the legacy files are read into memory and
  /// nothing persists this session.
  Future<void> load() async {
    final gate = _loading = Completer<void>();
    try {
      await _load();
    } catch (e) {
      // Corrupt storage never blocks startup; the store keeps what it has.
      logDebug('[SavedThreads] load failed: $e');
    } finally {
      _loading = null;
      _removedWhileLoading.clear();
      gate.complete();
    }
  }

  Future<void> _load() async {
    final db = await _store;
    final legacy = _legacyDir ?? await _resolveLegacyDir();
    final List<SavedThread> loaded;
    final Map<String, List<TwitchMessage>> disk;
    if (db == null) {
      logDebug('[SavedThreads] archive unavailable, reading JSON files');
      final old = await _readLegacy(legacy);
      loaded = old.threads;
      disk = old.messages;
    } else {
      await _importLegacy(db, legacy);
      (loaded, disk) = await _readDb(db);
    }

    // Everything in memory now was saved during load and wins over disk.
    final early = {for (final t in _threads) t.key};
    final merged = [..._threads];
    for (final t in loaded) {
      if (early.contains(t.key) || _removedWhileLoading.contains(t.key)) {
        continue;
      }
      merged.add(t);
    }
    for (final evicted in merged.skip(maxSavedThreads)) {
      _forget(evicted);
    }
    _threads
      ..clear()
      ..addAll(merged.take(maxSavedThreads));
    for (final t in _threads) {
      final fromDisk = disk[t.key];
      if (fromDisk == null) continue;
      final msgs = _messages[t.key] ?? [];
      final ids = _messageIds[t.key] ?? _idsOf(msgs);
      for (final m in fromDisk) {
        if (m.messageId == null || ids.add(m.messageId!)) msgs.add(m);
      }
      msgs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      _messages[t.key] = msgs;
      _messageIds[t.key] = ids;
    }
  }

  Future<(List<SavedThread>, Map<String, List<TwitchMessage>>)> _readDb(
    ArchiveStore db,
  ) async {
    final loaded = [
      for (final t in await db.savedThreads()) _saved(t),
    ].take(maxSavedThreads).toList();
    final raw = <String, List<Uint8List>>{};
    var bytes = 0;
    for (final t in loaded) {
      if (_removedWhileLoading.contains(t.key)) continue;
      final rows = await db.threadMessages(t.channel, t.rootId);
      for (final r in rows) {
        bytes += r.data.length;
      }
      raw[t.key] = [for (final r in rows) r.data];
    }
    final decoded = bytes > _isolateBytes
        ? await Isolate.run(() => _decodeAll(raw))
        : _decodeAll(raw);
    return (loaded, decoded);
  }

  static Map<String, List<TwitchMessage>> _decodeAll(
    Map<String, List<Uint8List>> raw,
  ) => {
    for (final e in raw.entries)
      e.key: [for (final data in e.value) ?_decodeMessage(data)],
  };

  static TwitchMessage? _decodeMessage(Uint8List data) {
    try {
      return TwitchMessage.fromJson(
        Map<String, dynamic>.from(jsonDecode(utf8.decode(data)) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  Future<Directory?> _resolveLegacyDir() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      return Directory('${docs.path}${Platform.pathSeparator}saved_threads');
    } catch (_) {
      return null;
    }
  }

  // One-time import of the JSON store (and the older prefs snapshot) into the
  // db, in one transaction that also records the marker. The files stay for
  // one more launch; the launch after the marker exists deletes them.
  Future<void> _importLegacy(ArchiveStore db, Directory? dir) async {
    if (await db.hasMeta(_migratedKey)) {
      try {
        if (dir != null && await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } catch (e) {
        logDebug('[SavedThreads] legacy cleanup failed: $e');
      }
      return;
    }
    if (dir == null) return;
    final old = await _readLegacy(dir);
    if (old.unreadable) {
      logDebug('[SavedThreads] legacy index unreadable, import skipped');
      return;
    }
    await db.importThreads(
      [for (final t in old.threads) _stored(t)],
      [
        for (final t in old.threads)
          for (final m in old.messages[t.key] ?? const <TwitchMessage>[])
            _row(t, m),
      ],
      _migratedKey,
    );
    if (old.fromPrefs) {
      try {
        await (await Prefs.load()).removeSavedThreads();
      } catch (_) {}
    }
  }

  // Decoded JSON list from [file], falling back to its .bak. Null when
  // neither is readable.
  static Future<List?> _readList(File file) async {
    for (final f in [file, File('${file.path}.bak')]) {
      try {
        if (await f.exists()) return jsonDecode(await f.readAsString()) as List;
      } catch (_) {}
    }
    return null;
  }

  static String _legacyFileName(SavedThread t) {
    final channel = t.channel.replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    final root = t.rootId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return '${channel}__$root.json';
  }

  // Reads the legacy index and thread files. Unreadable thread files are
  // skipped; an index that exists but cannot be read sets `unreadable`. With
  // no index file the pre-file prefs snapshot is used when present.
  Future<_Legacy> _readLegacy(Directory? dir) async {
    if (dir == null) return _Legacy();
    final indexFile = File('${dir.path}${Platform.pathSeparator}index.json');
    final list = await _readList(indexFile);
    if (list == null) {
      if (await indexFile.exists() ||
          await File('${indexFile.path}.bak').exists()) {
        return _Legacy(unreadable: true);
      }
      try {
        final raw = (await Prefs.load()).savedThreads;
        if (raw == null || raw.isEmpty) return _Legacy();
        final old = SavedThreadsStore()..decode(raw);
        return _Legacy(threads: [...old._threads], fromPrefs: true);
      } catch (_) {
        return _Legacy();
      }
    }
    final result = _Legacy();
    for (final item in list) {
      try {
        if (item is! Map) continue;
        final entry = SavedThread.fromJson(Map<String, dynamic>.from(item));
        if (entry == null) continue;
        if (result.threads.any((t) => t.key == entry.key)) continue;
        result.threads.add(entry);
        if (result.threads.length >= maxSavedThreads) break;
      } catch (_) {
        continue;
      }
    }
    for (final t in result.threads) {
      final mlist = await _readList(
        File('${dir.path}${Platform.pathSeparator}${_legacyFileName(t)}'),
      );
      if (mlist == null) {
        logDebug('[SavedThreads] skipped unreadable ${t.key}');
        continue;
      }
      result.messages[t.key] = [
        for (final m in mlist)
          if (m is Map) ?_fromLegacyMap(m),
      ];
    }
    return result;
  }

  static TwitchMessage? _fromLegacyMap(Map m) {
    try {
      return TwitchMessage.fromJson(Map<String, dynamic>.from(m));
    } catch (_) {
      return null;
    }
  }

  /// Parses a legacy bookmark list (the prefs snapshot) into the store.
  void decode(String? raw) {
    final next = <SavedThread>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        for (final item in list) {
          try {
            if (item is! Map) continue;
            final entry = SavedThread.fromJson(Map<String, dynamic>.from(item));
            if (entry == null) continue;
            if (next.any(
              (t) => t.channel == entry.channel && t.rootId == entry.rootId,
            )) {
              continue;
            }
            next.add(entry);
          } catch (_) {
            continue;
          }
          if (next.length >= maxSavedThreads) break;
        }
      } catch (_) {
        return;
      }
    }
    _threads
      ..clear()
      ..addAll(next);
  }
}

// What the legacy JSON store (or prefs snapshot) held.
class _Legacy {
  _Legacy({
    List<SavedThread>? threads,
    this.fromPrefs = false,
    this.unreadable = false,
  }) : threads = threads ?? [],
       messages = {};

  final List<SavedThread> threads;
  final Map<String, List<TwitchMessage>> messages;
  final bool fromPrefs;
  final bool unreadable;
}
