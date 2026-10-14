import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../models/twitch_message.dart';
import '../util/log.dart';
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
    this._createTimer = Timer.new,
  }) : _store = store ?? Future.value(null);

  static const _flushDelay = Duration(seconds: 1);
  // Message bytes above which load decodes in an isolate.
  static const _isolateBytes = 64 * 1024;

  final Future<ArchiveStore?> _store;
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

  /// Loads saved threads from the archive. Saves made while loading are kept
  /// and merged ahead of the loaded list. With no database saved threads live
  /// in memory for the session only.
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
    final List<SavedThread> loaded;
    final Map<String, List<TwitchMessage>> disk;
    if (db == null) {
      logDebug('[SavedThreads] archive unavailable, memory only');
      loaded = const [];
      disk = const {};
    } else {
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
}
