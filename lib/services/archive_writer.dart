import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../archive/archive_block.dart';
import '../archive/archive_io.dart';
import '../archive/archive_row.dart';
import '../archive/archive_users.dart';
import '../archive/archive_words.dart';
import '../models/twitch_message.dart';
import '../util/log.dart';
import 'archive_adapter.dart';
import 'archive_store.dart';

Future<Uint8List> encodeOffIsolate(List<ArchiveRow> rows) =>
    Isolate.run(() => ArchiveBlock.encode(rows));

class _Chan {
  UserTables? tables;
  Future<void>? loading;
  final waiting = <TwitchMessage>[];
  final tail = <ArchiveRow>[];

  /// The tail's messages plus those of seals still writing, oldest first.
  final unsealed = <TwitchMessage>[];

  /// Recent message ids (insertion ordered): the unsealed tail plus the
  /// newest sealed block, so a row arriving twice is stored once.
  final ids = <String>{};

  /// Emote definitions the tail uses that no seal has sent yet, as JSON by
  /// key, and the keys sent this session.
  final defs = <String, String>{};
  final sentDefs = <String>{};
  Timer? timer;
  Future<void> chain = Future.value();
}

/// Appends accepted messages to an in-memory tail per channel and seals the
/// tail into one block every [sealCount] rows or [sealAfter] after its first
/// row. Encoding runs off the UI isolate and each block is written in one
/// transaction with its minute counts. Nothing waits for lifecycle events: a
/// kill loses at most the unsealed tail.
class ArchiveWriter {
  ArchiveWriter(
    this._store, {
    this.sealCount = 256,
    this.sealAfter = const Duration(seconds: 30),
    this.createTimer = Timer.new,
    this.encode = encodeOffIsolate,
  });

  /// Message ids remembered per channel for dedup.
  static const int idWindow = 4096;

  /// Messages parked per channel while the user tables load.
  static const int maxWaiting = 1024;

  final Future<ArchiveStore?> _store;
  final int sealCount;
  final Duration sealAfter;

  /// Injectable so tests fire the seal timer by hand.
  final Timer Function(Duration, void Function()) createTimer;

  /// Packs one tail; off the UI isolate by default.
  final Future<Uint8List> Function(List<ArchiveRow> rows) encode;
  final Map<String, _Chan> _chans = {};

  /// Store edits not yet written, in order.
  Future<void> _pending = Future.value();
  bool _disposed = false;

  /// Queues [msg] for [channel]. Never throws and never blocks the caller.
  void add(String channel, TwitchMessage msg) {
    if (_disposed) {
      return;
    }
    final c = _chans.putIfAbsent(channel, _Chan.new);
    if (c.tables == null) {
      if (c.waiting.length < maxWaiting) {
        c.waiting.add(msg);
      }
      c.loading ??= _load(channel, c);
      return;
    }
    _append(channel, c, msg);
  }

  Future<void> _load(String channel, _Chan c) async {
    try {
      final store = await _store;
      if (store == null) {
        c.waiting.clear();
        return;
      }
      final tables = await store.tables(channel);
      // Oldest first, so the dedup window keeps the newest ids.
      final blocks = await store.newestBlocks(channel, idWindow);
      for (final b in blocks.reversed) {
        try {
          for (final r in ArchiveBlock.decode(b.data)) {
            final id = r.messageId;
            if (id != null) {
              c.ids.add(id);
            }
          }
        } on ArchiveFormatException {
          continue;
        }
      }
      while (c.ids.length > idWindow) {
        c.ids.remove(c.ids.first);
      }
      c.tables = tables;
      final queued = List.of(c.waiting);
      c.waiting.clear();
      for (final m in queued) {
        _append(channel, c, m);
      }
    } catch (e) {
      logDebug('[ArchiveWriter] load failed for $channel: $e');
    } finally {
      c.loading = null;
    }
  }

  void _append(String channel, _Chan c, TwitchMessage msg) {
    final id = msg.messageId;
    if (id != null) {
      if (!c.ids.add(id)) {
        return;
      }
      if (c.ids.length > idWindow) {
        c.ids.remove(c.ids.first);
      }
    }
    c.tail.add(ArchiveAdapter(c.tables!).toRow(msg));
    for (final t in ArchiveAdapter.storedTokens(msg) ?? const []) {
      final key = ArchiveAdapter.defKey(t.emote!);
      if (c.sentDefs.contains(key) || c.defs.containsKey(key)) continue;
      c.defs[key] = jsonEncode(t.emote!.toJson());
    }
    c.unsealed.add(msg);
    if (c.tail.length >= sealCount) {
      _seal(channel, c);
    } else {
      c.timer ??= createTimer(sealAfter, () => _seal(channel, c));
    }
  }

  /// Records an edit of every id in [messageIds]. Ids the writer still holds
  /// change in place; the rest are written to the store in one transaction.
  Future<void> recordEdits(
    String channel,
    Iterable<String> messageIds,
    ArchiveEdit edit,
  ) {
    if (_disposed) return Future.value();
    final c = _chans[channel];
    final stored = <String>[];
    for (final id in messageIds) {
      if (c != null && _applyEdit(c, id, edit)) continue;
      stored.add(id);
    }
    if (stored.isEmpty) return Future.value();
    return _pending = _pending.then((_) => _writeEdits(channel, stored, edit));
  }

  /// Message ids [channel] the writer still holds: parked or in a seal that has
  /// not committed. Upkeep must not clear a pending edit for one.
  Set<String> heldIds(String channel) {
    final c = _chans[channel];
    if (c == null) return const {};
    return {
      for (final m in c.waiting) ?m.messageId,
      for (final m in c.unsealed) ?m.messageId,
    };
  }

  /// [edit] on [messageId] in the unchanging tail. A row in a seal still
  /// writing is already sealed from this side, so the store takes that edit.
  bool _applyEdit(_Chan c, String messageId, ArchiveEdit edit) {
    if (c.tables == null) {
      for (var i = 0; i < c.waiting.length; i++) {
        if (c.waiting[i].messageId != messageId) continue;
        if (edit == ArchiveEdit.remove) {
          c.waiting.removeAt(i);
        } else {
          c.waiting[i].deleted = true;
        }
        return true;
      }
      return false;
    }
    for (var i = 0; i < c.tail.length; i++) {
      if (c.tail[i].messageId != messageId) continue;
      if (edit == ArchiveEdit.remove) {
        c.tail.removeAt(i);
        c.unsealed.removeWhere((m) => m.messageId == messageId);
      } else {
        c.tail[i] = c.tail[i].asDeleted();
        for (final m in c.unsealed) {
          if (m.messageId == messageId) m.deleted = true;
        }
      }
      return true;
    }
    return false;
  }

  Future<void> _writeEdits(
    String channel,
    List<String> messageIds,
    ArchiveEdit edit,
  ) async {
    try {
      final store = await _store;
      await store?.addEdits(channel, messageIds, edit);
    } catch (e) {
      logDebug('[ArchiveWriter] edits failed for $channel: $e');
    }
  }

  void _seal(String channel, _Chan c) {
    c.timer?.cancel();
    c.timer = null;
    if (c.tail.isEmpty) {
      return;
    }
    final rows = List.of(c.tail);
    c.tail.clear();
    final defs = Map.of(c.defs);
    c.sentDefs.addAll(defs.keys);
    c.defs.clear();
    c.chain = c.chain.then((_) async {
      await _write(channel, rows, defs);
      // Readable from the store now, or lost to a failed write.
      c.unsealed.removeRange(0, rows.length);
    });
  }

  /// Messages of [channel] not yet readable from the store, oldest first:
  /// parked, in the tail, or in a seal still writing.
  List<TwitchMessage> unsealed(String channel) {
    final c = _chans[channel];
    if (c == null) return const [];
    return [...c.waiting, ...c.unsealed];
  }

  Future<void> _write(
    String channel,
    List<ArchiveRow> rows,
    Map<String, String> defs,
  ) async {
    try {
      final data = await encode(rows);
      final store = await _store;
      if (store == null) {
        return;
      }
      final tables = await store.tables(channel);
      var start = rows.first.timestampMs;
      var end = start;
      final minutes = <int, int>{};
      for (final r in rows) {
        final t = r.timestampMs;
        if (t < start) start = t;
        if (t > end) end = t;
        minutes.update(t ~/ 60000, (n) => n + 1, ifAbsent: () => 1);
      }
      await store.appendBlock(
        channel: channel,
        startTs: start,
        endTs: end,
        count: rows.length,
        data: data,
        minutes: minutes,
        emoteDefs: defs,
        refIds: {
          for (final r in rows) ...[?r.replyParentId, ?r.threadRootId],
        },
        words: {
          for (final r in rows)
            if (!r.isSystem) ...searchWords(r.text),
        },
        senders: {
          for (final r in rows)
            if (!r.isSystem && r.user < tables.states.length)
              tables.states[r.user].who,
        },
      );
      await store.pruneIfDue(heldEdits: heldIds);
    } catch (e) {
      logDebug('[ArchiveWriter] seal failed for $channel: $e');
    }
  }

  /// Completes when every load and queued seal has finished.
  Future<void> settled() async {
    for (final c in List.of(_chans.values)) {
      await c.loading;
      await c.chain;
    }
    await _pending;
  }

  /// Seals every tail now and waits for the writes.
  Future<void> flush() async {
    for (final c in List.of(_chans.values)) {
      await c.loading;
    }
    for (final e in _chans.entries) {
      _seal(e.key, e.value);
    }
    await settled();
  }

  /// Seals what is pending, then closes the store.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    await flush();
    _disposed = true;
    for (final c in _chans.values) {
      c.timer?.cancel();
    }
    await (await _store)?.close();
  }
}
