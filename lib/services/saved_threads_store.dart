import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/twitch_message.dart';

// Legacy prefs key (v1 snapshots). Kept for migration; new writes go to files.
const savedThreadsPrefsKey = 'saved_threads_v1';

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

  Directory? _dir;
  bool _dirResolved = false;
  Timer? _flushTimer;
  final Set<String> _dirty = {};

  List<SavedThread> get threads => List.unmodifiable(_threads);

  List<TwitchMessage> messagesFor(String channel, String rootId) =>
      List.unmodifiable(
        _messages['${channel.toLowerCase()}:$rootId'] ?? const [],
      );

  bool isSaved(String channel, String rootId) => _threads.any(
    (t) => t.channel == channel.toLowerCase() && t.rootId == rootId,
  );

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
        _dirty.remove(evicted.key);
        unawaited(_deleteFile(evicted));
      }
    }
    _messages[entry.key] = List.of(messages);
    _markDirty(entry);
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
    if (msg.messageId != null && log.any((m) => m.messageId == msg.messageId)) {
      return false;
    }
    log.insert(0, msg);
    _markDirty(_threads[idx]);
    return true;
  }

  void _markDirty(SavedThread t) {
    _dirty.add(t.key);
    unawaited(_writeIndex());
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

  Future<void> _writeIndex() async {
    try {
      final dir = await _resolveDir();
      if (dir == null) return;
      final file = File('${dir.path}${Platform.pathSeparator}index.json');
      await file.writeAsString(
        jsonEncode([for (final t in _threads) t.toJson()]),
      );
    } catch (_) {}
  }

  Future<void> _writeThread(SavedThread t) async {
    try {
      final dir = await _resolveDir();
      if (dir == null) return;
      final file = File(
        '${dir.path}${Platform.pathSeparator}${_safeFileName(t)}',
      );
      final log = _messages[t.key] ?? const [];
      await file.writeAsString(jsonEncode([for (final m in log) m.toJson()]));
    } catch (_) {}
  }

  Future<void> _deleteFile(SavedThread t) async {
    try {
      final dir = await _resolveDir();
      if (dir == null) return;
      final file = File(
        '${dir.path}${Platform.pathSeparator}${_safeFileName(t)}',
      );
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Loads index + thread files, migrating the legacy prefs snapshots once.
  Future<void> load() async {
    await _migrateFromPrefs();
    try {
      final dir = await _resolveDir();
      if (dir == null) return;
      final indexFile = File('${dir.path}${Platform.pathSeparator}index.json');
      if (!await indexFile.exists()) return;
      final raw = await indexFile.readAsString();
      final list = jsonDecode(raw) as List;
      final next = <SavedThread>[];
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
          if (next.length >= maxSavedThreads) break;
        } catch (_) {
          continue;
        }
      }
      _threads
        ..clear()
        ..addAll(next);
      _messages.clear();
      for (final t in _threads) {
        try {
          final file = File(
            '${dir.path}${Platform.pathSeparator}${_safeFileName(t)}',
          );
          if (!await file.exists()) continue;
          final mraw = await file.readAsString();
          final mlist = jsonDecode(mraw) as List;
          final msgs = <TwitchMessage>[];
          for (final m in mlist) {
            try {
              if (m is! Map) continue;
              msgs.add(TwitchMessage.fromJson(Map<String, dynamic>.from(m)));
            } catch (_) {
              continue;
            }
          }
          msgs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
          _messages[t.key] = msgs;
        } catch (_) {
          continue;
        }
      }
    } catch (_) {}
  }

  Future<void> _migrateFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(savedThreadsPrefsKey);
      if (raw == null || raw.isEmpty) return;
      decode(raw);
      await prefs.remove(savedThreadsPrefsKey);
      await _writeIndex();
      for (final t in _threads) {
        await _writeThread(t);
      }
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
