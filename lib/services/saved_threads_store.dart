import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/twitch_message.dart';
import '../util/prefs.dart';

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

// In-memory bookmark list plus the full per-thread message logs. Metadata
// syncs through prefs-encode for tests; the real persistence is file-backed
// (one JSON file per thread plus an index), so unbounded threads never blow
// the prefs size budget.
class SavedThreadsStore {
  final List<SavedThread> _threads = [];
  final Map<String, List<TwitchMessage>> _messages = {};
  // Message ids per thread, kept in sync with _messages so append dedupe is
  // O(1) instead of a scan of the whole (uncapped) thread log.
  final Map<String, Set<String>> _messageIds = {};

  Directory? _dir;
  bool _dirResolved = false;
  Timer? _flushTimer;
  final Set<String> _dirty = {};

  // Open while load() runs: disk writes wait on it, and saves made meanwhile
  // merge into the loaded list instead of being replaced by it.
  Completer<void>? _loading;
  final Set<String> _removedWhileLoading = {};
  // False when an index exists but cannot be read (primary and backup). The
  // index is then never rewritten, so a read failure cannot shrink it.
  bool _indexTrusted = true;
  // Disk work runs one task at a time so writes to a file never interleave.
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

  /// Test seam: override blob directory.
  @visibleForTesting
  void overrideDirectory(Directory dir) {
    _dir = dir;
    _dirResolved = true;
  }

  @visibleForTesting
  void reset() {
    _threads.clear();
    _messages.clear();
    _messageIds.clear();
    _dirty.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  Future<Directory?> _resolveDir() async {
    if (_dirResolved) return _dir;
    _dirResolved = true;
    try {
      final docs = await getApplicationDocumentsDirectory();
      _dir = Directory('${docs.path}${Platform.pathSeparator}saved_threads');
      await _dir!.create(recursive: true);
    } catch (_) {
      _dir = null;
    }
    return _dir;
  }

  static Set<String> _idsOf(Iterable<TwitchMessage> messages) {
    final ids = <String>{};
    for (final m in messages) {
      if (m.messageId != null) ids.add(m.messageId!);
    }
    return ids;
  }

  String _safeFileName(SavedThread t) {
    final channel = t.channel.replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    final root = t.rootId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return '${channel}__$root.json';
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
        final evicted = _threads.removeLast();
        _messages.remove(evicted.key);
        _messageIds.remove(evicted.key);
        _dirty.remove(evicted.key);
        unawaited(_deleteFile(evicted));
      }
    }
    _messages[entry.key] = List.of(messages);
    _messageIds[entry.key] = _idsOf(messages);
    _removedWhileLoading.remove(entry.key);
    _markDirty(entry);
    unawaited(_writeIndex());
    return true;
  }

  // Returns true when the thread is saved after the call.
  bool toggle(SavedThread entry, [List<TwitchMessage>? messages]) {
    if (entry.channel.isEmpty || entry.rootId.isEmpty) return false;
    final idx = _threads.indexWhere(
      (t) => t.channel == entry.channel && t.rootId == entry.rootId,
    );
    if (idx >= 0) {
      final removed = _threads.removeAt(idx);
      _messages.remove(removed.key);
      _messageIds.remove(removed.key);
      _dirty.remove(removed.key);
      unawaited(_deleteFile(removed));
      unawaited(_writeIndex());
      return false;
    }
    saveThread(entry, messages ?? const []);
    return true;
  }

  bool remove(String channel, String rootId) {
    final lc = channel.toLowerCase();
    final idx = _threads.indexWhere(
      (t) => t.channel == lc && t.rootId == rootId,
    );
    if (idx < 0) return false;
    final removed = _threads.removeAt(idx);
    _messages.remove(removed.key);
    _messageIds.remove(removed.key);
    _dirty.remove(removed.key);
    unawaited(_deleteFile(removed));
    unawaited(_writeIndex());
    return true;
  }

  // Appends a live message to its saved thread when the message belongs to
  // one. Returns true when appended. Callers schedule persistence via flush.
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
    _markDirty(_threads[idx]);
    return true;
  }

  void _markDirty(SavedThread t) {
    _dirty.add(t.key);
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 1), () {
      unawaited(flush());
    });
  }

  /// Writes pending thread files now. Tests and dispose paths await this.
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_dirty.isEmpty) return;
    final pending = Set.of(_dirty);
    _dirty.clear();
    for (final key in pending) {
      final idx = _threads.indexWhere((t) => t.key == key);
      if (idx < 0) continue;
      await _writeThread(_threads[idx]);
    }
  }

  /// Test seam: resolves once queued index and file writes finish.
  @visibleForTesting
  Future<void> flushIo() => _ioQueue;

  Future<void> _enqueue(Future<void> Function() task) {
    return _ioQueue = _ioQueue.then((_) async {
      await _loading?.future;
      try {
        await task();
      } catch (_) {}
    });
  }

  File _file(Directory dir, String name) =>
      File('${dir.path}${Platform.pathSeparator}$name');

  // Writes a temp file, then renames it over [target], so a kill mid-write
  // never leaves a truncated target. The previous version stays as .bak.
  static Future<void> _atomicWrite(File target, String content) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    if (await target.exists()) await target.rename('${target.path}.bak');
    await tmp.rename(target.path);
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

  Future<void> _writeIndex() => _enqueue(() async {
    if (!_indexTrusted) return;
    final dir = await _resolveDir();
    if (dir == null) return;
    await _atomicWrite(
      _file(dir, 'index.json'),
      jsonEncode([for (final t in _threads) t.toJson()]),
    );
  });

  Future<void> _writeThread(SavedThread t) => _enqueue(() async {
    final dir = await _resolveDir();
    final log = _messages[t.key];
    if (dir == null || log == null) return;
    await _atomicWrite(
      _file(dir, _safeFileName(t)),
      jsonEncode([for (final m in log) m.toJson()]),
    );
  });

  Future<void> _deleteFile(SavedThread t) {
    if (_loading != null) _removedWhileLoading.add(t.key);
    return _enqueue(() async {
      final dir = await _resolveDir();
      if (dir == null) return;
      for (final suffix in const ['', '.bak', '.tmp']) {
        final file = _file(dir, '${_safeFileName(t)}$suffix');
        if (await file.exists()) await file.delete();
      }
    });
  }

  /// Loads index + thread files, migrating the legacy prefs snapshots once.
  /// Saves made while loading are kept and merged ahead of the loaded list.
  Future<void> load() async {
    final gate = _loading = Completer<void>();
    try {
      await _loadFromDisk();
    } catch (_) {
      // Corrupt storage never blocks startup; the store keeps what it has.
    } finally {
      _loading = null;
      _removedWhileLoading.clear();
      gate.complete();
    }
  }

  Future<void> _loadFromDisk() async {
    await _migrateFromPrefs();
    final dir = await _resolveDir();
    if (dir == null) return;
    final indexFile = _file(dir, 'index.json');
    final list = await _readList(indexFile);
    if (list == null) {
      if (await indexFile.exists() ||
          await File('${indexFile.path}.bak').exists()) {
        _indexTrusted = false;
      }
      return;
    }
    final loaded = <SavedThread>[];
    for (final item in list) {
      try {
        if (item is! Map) continue;
        final entry = SavedThread.fromJson(Map<String, dynamic>.from(item));
        if (entry == null) continue;
        if (loaded.any((t) => t.key == entry.key)) continue;
        loaded.add(entry);
        if (loaded.length >= maxSavedThreads) break;
      } catch (_) {
        continue;
      }
    }
    final disk = <String, List<TwitchMessage>>{};
    for (final t in loaded) {
      if (_removedWhileLoading.contains(t.key)) continue;
      final mlist = await _readList(_file(dir, _safeFileName(t)));
      if (mlist == null) continue;
      final msgs = <TwitchMessage>[];
      for (final m in mlist) {
        try {
          if (m is! Map) continue;
          msgs.add(TwitchMessage.fromJson(Map<String, dynamic>.from(m)));
        } catch (_) {
          continue;
        }
      }
      disk[t.key] = msgs;
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
      _messages.remove(evicted.key);
      _messageIds.remove(evicted.key);
      _dirty.remove(evicted.key);
      unawaited(_deleteFile(evicted));
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
    if (early.isNotEmpty || _removedWhileLoading.isNotEmpty) {
      unawaited(_writeIndex());
    }
  }

  Future<void> _migrateFromPrefs() async {
    try {
      final prefs = await Prefs.load();
      final raw = prefs.savedThreads;
      if (raw == null || raw.isEmpty) return;
      final dir = await _resolveDir();
      if (dir == null) return;
      final indexFile = _file(dir, 'index.json');
      if (!await indexFile.exists()) {
        await _atomicWrite(
          indexFile,
          (SavedThreadsStore()..decode(raw)).encode(),
        );
      }
      await prefs.removeSavedThreads();
    } catch (_) {}
  }

  String encode() => jsonEncode([for (final t in _threads) t.toJson()]);

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
