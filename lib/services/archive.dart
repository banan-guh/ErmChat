import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../archive/archive_row.dart';
import '../archive/set_log.dart';
import '../emotes/emote.dart';
import '../models/twitch_badge.dart';
import '../util/log.dart';
import '../util/prefs.dart';
import 'archive_adapter.dart';
import 'archive_reader.dart';
import 'archive_store.dart';
import 'archive_writer.dart';
import 'fake_chat_feed.dart';

/// The history archive: one SQLite store with its writer and reader. The
/// store opens lazily on first use; if it cannot open (for example after a
/// downgrade) the archive logs once and acts empty, and chat is unaffected.
class Archive {
  Archive(this.store) : writer = ArchiveWriter(store) {
    reader = ArchiveReader(store, unsealed: writer.unsealed);
  }

  /// The shared store; null once resolved when it could not open. Saved
  /// threads persist through it.
  final Future<ArchiveStore?> store;

  /// Opens `archive.db` in the app support directory.
  factory Archive.inAppSupport() => Archive(_openDefault());

  final ArchiveWriter writer;
  late final ArchiveReader reader;

  /// Where [Archive.inAppSupport] keeps its database.
  static Future<String> defaultPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}${Platform.pathSeparator}archive.db';
  }

  static Future<ArchiveStore?> _openDefault() async {
    try {
      // The open prunes once, so the chosen limits apply before it.
      final prefs = await Prefs.load();
      ArchiveStore.retention = Duration(days: prefs.archiveRetentionDays);
      ArchiveStore.channelCapBytes = capBytes(prefs.archiveChannelCapMb);
      return await ArchiveStore.open(await defaultPath());
    } catch (e) {
      logDebug('[Archive] open failed: $e');
      return null;
    }
  }

  /// The database's size on disk, write-ahead log included, or null when
  /// it cannot be read.
  static Future<int?> defaultSizeBytes() async {
    try {
      final path = await defaultPath();
      var total = 0;
      for (final suffix in ['', '-wal']) {
        final file = File('$path$suffix');
        if (await file.exists()) total += await file.length();
      }
      return total;
    } catch (_) {
      return null;
    }
  }

  /// Deletes the default database while no archive has it open. Never
  /// throws.
  static Future<void> deleteDefault() async {
    try {
      final path = await defaultPath();
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('$path$suffix');
        if (await file.exists()) await file.delete();
      }
    } catch (e) {
      logDebug('[Archive] delete failed: $e');
    }
  }

  /// Bytes of chat that kept days hold, or null when the store is closed.
  Future<int?> keptBytes() async {
    try {
      return await (await store)?.keptBytes();
    } catch (_) {
      return null;
    }
  }

  /// Sets how long chat stays and prunes to it now. Never throws.
  Future<void> setRetention(Duration retention) async {
    ArchiveStore.retention = retention;
    await _shrink();
  }

  /// Bytes for a per-channel cap of [mb] megabytes, null for 0 (no cap).
  static int? capBytes(int mb) => mb > 0 ? mb * 1024 * 1024 : null;

  /// Sets the per-channel cap and prunes to it now. Never throws.
  Future<void> setChannelCap(int? bytes) async {
    ArchiveStore.channelCapBytes = bytes;
    await _shrink();
  }

  /// Prunes to the current limits and hands the freed space back to the
  /// file system, so the size shown drops at once.
  Future<void> _shrink() => _quiet((s) async {
    await s.prune(DateTime.now());
    await s.pruneUsers();
    await s.reclaimSpace(all: true);
  });

  /// Records a broadcast seen live. Never throws.
  Future<void> recordStream({
    required String channel,
    required String id,
    required DateTime startedAt,
    String? title,
    String? game,
  }) => _quiet((s) async {
    final changed = await s.putStream(
      channel: channel,
      id: id,
      startedTs: startedAt.millisecondsSinceEpoch,
      title: title,
      game: game,
    );
    if (changed) reader.streamsChanged.emit();
  });

  /// Records the end of broadcast [id]. Never throws.
  Future<void> endStream(String id, DateTime endedAt) => _quiet((s) async {
    await s.endStream(id, endedAt.millisecondsSinceEpoch);
    reader.streamsChanged.emit();
  });

  /// Keeps the day [start] to [end] of [channel] past retention, or releases
  /// it. Never throws.
  Future<void> setDayKept(
    String channel,
    DateTime start,
    DateTime end, {
    required bool keep,
  }) => _quiet((s) {
    final from = start.millisecondsSinceEpoch;
    final to = end.millisecondsSinceEpoch;
    const kind = ArchiveReader.dayPin;
    return keep
        ? s.addPin(channel, from, to, kind)
        : s.removePin(channel, from, to, kind);
  });

  /// Remembers the video on demand of broadcast [streamId]. Never throws.
  Future<void> setVod(String streamId, String vodId) =>
      _quiet((s) => s.setVod(streamId, vodId));

  /// Records rows by [login] (everyone when null) from [from] to [to] as
  /// deleted, for rows already sealed. Never throws.
  Future<void> recordModeration(
    String channel,
    String? login,
    DateTime from,
    DateTime to,
  ) {
    if (FakeChatFeed.ownsLogin(login)) return Future.value();
    reader.clears.emit((channel, (login: login, from: from, to: to)));
    return _quiet(
      (s) => s.addModeration(
        channel,
        login,
        from.millisecondsSinceEpoch,
        to.millisecondsSinceEpoch,
        atTs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// Records an edit of every id in [messageIds] in one store transaction: drop
  /// them or mark them deleted. A row still in the writer's tail changes there.
  /// Never throws.
  Future<void> recordEdits(
    String channel,
    Iterable<String> messageIds,
    ArchiveEdit edit,
  ) async {
    try {
      await writer.recordEdits(channel, messageIds, edit);
    } catch (e) {
      logDebug('[Archive] edits failed: $e');
    }
  }

  static const emoteKind = 'emote';
  static const badgeKind = 'badge';

  /// Set logs by kind, scope and source, loaded on first use.
  final Map<String, Future<SetLog>> _logs = {};
  Future<void> _observing = Future.value();

  /// Notes that a fetch of one set ([SetLog]) returned [items], key to
  /// definition JSON, at [at] (now by default). An empty result is skipped:
  /// it cannot be told from a broken fetch, and the next one settles it.
  /// Never throws.
  Future<void> observe(
    String kind,
    String scope,
    String source,
    Map<String, String> items, {
    DateTime? at,
  }) => _observeWith(kind, scope, source, (_) => items, at);

  Future<void> _observeWith(
    String kind,
    String scope,
    String source,
    Map<String, String> Function(Map<String, String> latest) build,
    DateTime? at,
  ) {
    final atMs = (at ?? DateTime.now()).millisecondsSinceEpoch;
    return _observing = _observing.then(
      (_) => _quiet((s) async {
        final log = await (_logs['$kind|$scope|$source'] ??= s
            .observations(kind, scope, source)
            .then(SetLog.new));
        final rows = log.rows;
        if (rows.isNotEmpty && atMs <= rows.last.atMs) return;
        final items = build(log.latest);
        if (items.isEmpty) return;
        final o = log.diff(items, atMs);
        if (o == null) {
          await s.touchObservation(kind, scope, source, rows.last.atMs, atMs);
          log.touch(atMs);
          return;
        }
        await s.addObservation(kind, scope, source, o);
        log.add(o);
      }),
    );
  }

  /// One set as observed at [at]: key to definition JSON.
  Future<Map<String, String>> observedAt(
    String kind,
    String scope,
    String source,
    DateTime at,
  ) async {
    await _observing;
    final s = await store;
    if (s == null) return const {};
    final log = await (_logs['$kind|$scope|$source'] ??= s
        .observations(kind, scope, source)
        .then(SetLog.new));
    return log.at(at.millisecondsSinceEpoch);
  }

  /// A fetch of [provider]'s emotes for [scope] ('' for global). Twitch
  /// emotes are left out: rows keep their positions.
  Future<void> observeEmotes(
    String scope,
    EmoteType provider,
    Iterable<Emote> emotes, {
    DateTime? at,
  }) {
    if (provider == EmoteType.twitch) return Future.value();
    return observe(emoteKind, scope, provider.name, {
      for (final e in emotes) ArchiveAdapter.defKey(e): jsonEncode(e.toJson()),
    }, at: at);
  }

  /// A 7TV live change to [channel]'s set, applied over the last observed
  /// one. Without one there is nothing to apply it to, so it waits for the
  /// next fetch.
  Future<void> observeSevenTvDelta(
    String channel, {
    List<Emote> added = const [],
    List<String> removedIds = const [],
    Map<String, String> renamed = const {},
    DateTime? at,
  }) => _observeWith(emoteKind, channel, EmoteType.sevenTv.name, (latest) {
    if (latest.isEmpty) return const {};
    final next = <String, String>{};
    for (final e in latest.entries) {
      final id = e.key.split(':')[1];
      if (removedIds.contains(id)) continue;
      final name = renamed[id];
      if (name == null) {
        next[e.key] = e.value;
        continue;
      }
      final def = jsonDecode(e.value) as Map<String, dynamic>;
      def['code'] = name;
      next['${EmoteType.sevenTv.name}:$id:$name'] = jsonEncode(def);
    }
    for (final e in added) {
      next[ArchiveAdapter.defKey(e)] = jsonEncode(e.toJson());
    }
    return next;
  }, at);

  /// A fetch of [scope]'s Twitch badges ('' for global). A redrawn badge
  /// keeps its set and version but not its image, so the image is part of
  /// the key.
  Future<void> observeBadges(
    String scope,
    Map<String, BadgeSet> sets, {
    DateTime? at,
  }) => observe(badgeKind, scope, 'twitch', {
    for (final set in sets.entries)
      for (final v in set.value.versions.entries)
        '${set.key}/${v.key}/${v.value.imageUrl}': jsonEncode({
          'set': set.key,
          'version': v.key,
          'url': v.value.imageUrl,
          'title': ?v.value.title,
        }),
  }, at: at);

  Future<void> _quiet(Future<void> Function(ArchiveStore s) write) async {
    try {
      final s = await store;
      if (s != null) await write(s);
    } catch (e) {
      logDebug('[Archive] write failed: $e');
    }
  }

  /// Deletes the whole archive. Never throws.
  Future<void> wipe() async {
    try {
      await _observing;
      _logs.clear();
      await writer.wipe();
    } catch (e) {
      logDebug('[Archive] wipe failed: $e');
    }
  }

  Future<void> dispose() => writer.dispose();
}
