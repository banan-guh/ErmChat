import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import '../archive/archive_block.dart';
import '../archive/archive_io.dart';
import '../archive/archive_row.dart';
import '../archive/archive_words.dart';
import '../emotes/emote.dart';
import '../models/twitch_message.dart';
import '../util/chat_search.dart';
import '../util/history_timeline.dart';
import '../util/log.dart';
import '../util/signal.dart';
import 'archive_adapter.dart';
import 'archive_store.dart';
import 'set_history.dart';

/// One decoded block of the windowed list.
class ArchiveWindowBlock {
  const ArchiveWindowBlock({
    required this.key,
    required this.start,
    required this.end,
    required this.rows,
  });

  final int key;
  final DateTime start;
  final DateTime end;

  /// Oldest first.
  final List<TwitchMessage> rows;
}

/// Rows per minute for the days waveforms.
class MinuteCount {
  const MinuteCount(this.minute, this.count);

  /// Start of the minute, UTC.
  final DateTime minute;
  final int count;
}

/// Lowercased texts and sender states a row may match by (both when
/// [both]), text a system row must hold, and the times (epoch ms, inclusive)
/// it must fall in (see [decodeBlocks]).
typedef ArchiveRowFilter = ({
  List<String> texts,
  Set<int> states,
  bool both,
  String? system,
  int? fromMs,
  int? toMs,
});

/// Decodes packed blocks; a damaged block yields null instead of throwing.
Future<List<List<ArchiveRow>?>> decodeOffIsolate(
  List<Uint8List> blocks,
  ArchiveRowFilter? keep,
) => Isolate.run(() => decodeBlocks(blocks, keep));

/// Rows of each block, or null for a damaged one. With [keep], only rows in
/// its times that it matches (see [ArchiveRowFilter]).
List<List<ArchiveRow>?> decodeBlocks(
  List<Uint8List> blocks, [
  ArchiveRowFilter? keep,
]) => [
  for (final b in blocks)
    () {
      try {
        final rows = ArchiveBlock.decode(b);
        return keep == null
            ? rows
            : [
                for (final r in rows)
                  if (_rowMatches(r, keep)) r,
              ];
      } on ArchiveFormatException {
        return null;
      }
    }(),
];

bool _rowMatches(ArchiveRow r, ArchiveRowFilter f) {
  if (f.fromMs != null && r.timestampMs < f.fromMs!) return false;
  if (f.toMs != null && r.timestampMs > f.toMs!) return false;
  final text = r.text.toLowerCase();
  if (r.isSystem) return f.system != null && text.contains(f.system!);
  final bySender = f.states.contains(r.user);
  final byText = f.texts.any(text.contains);
  return f.both ? bySender && byText : bySender || byText;
}

/// What an archive lookup decodes: blocks holding every word of one of
/// [texts] (as substrings of indexed words), or a row by a chatter
/// [sender] accepts; both when [both]. System rows holding [system] count
/// too.
class ArchiveTerms {
  const ArchiveTerms({
    this.texts = const [],
    this.sender,
    this.both = false,
    this.system,
  });

  /// Terms for [q] (see [ChatQuery]).
  factory ArchiveTerms.search(ChatQuery q) {
    final user = q.user;
    return ArchiveTerms(
      texts: [if (q.text.isNotEmpty) q.text],
      sender: user == null
          ? null
          : (login, displayName) =>
                login.toLowerCase().contains(user) ||
                (displayName?.toLowerCase().contains(user) ?? false),
      both: !q.either && user != null && q.text.isNotEmpty,
      system: q.systemText,
    );
  }

  final List<String> texts;
  final bool Function(String login, String? displayName)? sender;
  final bool both;
  final String? system;
}

/// Reads blocks from the archive, decodes them off the UI isolate, and
/// returns [TwitchMessage]s. A block that fails to decode is skipped.
class ArchiveReader {
  /// The pin kind of a kept day.
  static const dayPin = 'day';

  ArchiveReader(
    this._store, {
    this.decode = decodeOffIsolate,
    this.unsealed = _none,
    this.sets,
  });

  static List<TwitchMessage> _none(String channel) => const [];

  /// Deletes recorded after rows were read, by channel, for readers that
  /// hold rows.
  final clears = ChatSignal<(String, HistoryClear)>();

  /// Stored emote definitions by channel, then key; one instance per key.
  final Map<String, Map<String, Emote>> _defs = {};

  /// A broadcast started, ended, or reopened, in some channel.
  final streamsChanged = ChatVoidSignal();

  /// Rows the writer holds that no block has yet; reads include them so a
  /// row is never missing between the store and the live buffer.
  final List<TwitchMessage> Function(String channel) unsealed;

  final Future<ArchiveStore?> _store;

  /// The emote and badge sets over time that rows draw with; without it
  /// rows draw with today's.
  final SetHistory? sets;

  /// Unpacks blocks, keeping only rows a filter allows (see
  /// [decodeBlocks]); off the UI isolate by default.
  final Future<List<List<ArchiveRow>?>> Function(
    List<Uint8List> blocks,
    ArchiveRowFilter? keep,
  )
  decode;

  /// The newest [limit] rows of [channel], oldest first, for cold start.
  Future<List<TwitchMessage>> newestRows(String channel, int limit) async {
    final store = await _store;
    if (store == null || limit <= 0) {
      return const [];
    }
    final edits = await store.edits(channel);
    final blocks = await store.newestBlocks(channel, limit);
    final decoded = await _decodeAll(
      channel,
      blocks,
      asHistory: true,
      edits: edits,
    );
    final rows = [for (final b in decoded) ...b.rows];
    _sortStable(rows);
    return rows.length > limit ? rows.sublist(rows.length - limit) : rows;
  }

  /// Blocks around [time]: [before] older, the anchor, [after] newer.
  Future<List<ArchiveWindowBlock>> blocksAround(
    String channel,
    DateTime time, {
    required int before,
    required int after,
  }) async {
    final store = await _store;
    if (store == null) {
      return const [];
    }
    final edits = await store.edits(channel);
    final blocks = await store.blocksAround(
      channel,
      time.millisecondsSinceEpoch,
      before,
      after,
    );
    return _decodeAll(channel, blocks, edits: edits);
  }

  /// Rows of every block at [time] plus [before] blocks older and [after]
  /// newer, oldest first, cut to the range those blocks cover completely
  /// (see [ArchiveStore.blocksNear]).
  Future<List<TwitchMessage>> rowsNear(
    String channel,
    DateTime time, {
    required int before,
    required int after,
  }) async {
    final store = await _store;
    if (store == null) {
      return const [];
    }
    final edits = await store.edits(channel);
    final near = await store.blocksNear(
      channel,
      time.millisecondsSinceEpoch,
      before,
      after,
    );
    final at = time.millisecondsSinceEpoch;
    // With nothing asked for on a side, the read stops at [time] there.
    final floor = before > 0 ? near.floorTs : at - 1;
    final ceil = after > 0 ? near.ceilTs : at + 1;
    bool inRange(TwitchMessage m) {
      final ts = m.timestamp.millisecondsSinceEpoch;
      return (floor == null || ts > floor) && (ceil == null || ts < ceil);
    }

    final rows = [
      for (final b in await _decodeAll(channel, near.blocks, edits: edits))
        for (final m in b.rows)
          if (inRange(m)) m,
      for (final m in unsealed(channel))
        if (inRange(m)) m,
    ];
    _sortStable(rows);
    return rows;
  }

  Future<ArchiveWindowBlock?> blockAt(String channel, int blockKey) async {
    final store = await _store;
    if (store == null) return null;
    final edits = await store.edits(channel);
    final block = await store.blockAt(channel, blockKey);
    if (block == null) {
      return null;
    }
    final decoded = await _decodeAll(channel, [block], edits: edits);
    return decoded.isEmpty ? null : decoded.first;
  }

  /// Buckets of [per] with rows between [from] and [to], oldest first.
  Future<List<MinuteCount>> minuteCounts(
    String channel,
    DateTime from,
    DateTime to, {
    Duration per = const Duration(minutes: 1),
  }) async {
    final store = await _store;
    if (store == null) {
      return const [];
    }
    final counts = await store.minuteCounts(
      channel,
      from.millisecondsSinceEpoch ~/ 60000,
      to.millisecondsSinceEpoch ~/ 60000,
      per: per.inMinutes,
    );
    return [
      for (final c in counts)
        MinuteCount(
          DateTime.fromMillisecondsSinceEpoch(c.minute * 60000, isUtc: true),
          c.count,
        ),
    ];
  }

  /// Broadcasts still live or ended at or after [from], oldest first. A live
  /// one ends at [now].
  Future<List<HistoryStream>> streams(
    String channel,
    DateTime from,
    DateTime now,
  ) async {
    final store = await _store;
    if (store == null) {
      return const [];
    }
    final rows = await store.streams(channel, from.millisecondsSinceEpoch);
    DateTime at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    return [
      for (final r in rows)
        HistoryStream(
          id: r.id,
          start: at(r.startedTs),
          end: r.endedTs == null ? now : at(r.endedTs!),
          title: r.title ?? '',
          game: r.game ?? '',
          live: r.endedTs == null,
          vodId: r.vodId,
        ),
    ];
  }

  /// Starts of [channel]'s kept days (see `Archive.setDayKept`).
  Future<Set<DateTime>> keptDays(String channel) async {
    final store = await _store;
    if (store == null) return const {};
    return {
      for (final p in await store.pins(channel))
        if (p.kind == dayPin)
          DateTime.fromMillisecondsSinceEpoch(p.startTs, isUtc: true),
    };
  }

  Future<List<ArchiveWindowBlock>> _decodeAll(
    String channel,
    List<StoredBlock> blocks, {
    bool asHistory = false,
    ArchiveRowFilter? keep,
    Map<String, ArchiveEdit>? edits,
  }) async {
    if (blocks.isEmpty) {
      return const [];
    }
    final store = (await _store)!;
    final tables = await store.tables(channel);
    final adapter = ArchiveAdapter(tables);
    final data = [for (final b in blocks) b.data];
    final decoded = await decode(data, keep);
    var lo = blocks.first.startTs;
    var hi = blocks.first.endTs;
    for (final b in blocks) {
      if (b.startTs < lo) lo = b.startTs;
      if (b.endTs > hi) hi = b.endTs;
    }
    // Ranges per login (null = whole chat), so a channel with many bans
    // checks each row against its own sender's ranges only.
    final cleared = <String?, List<({int fromTs, int toTs, int? atTs})>>{};
    for (final c in await store.moderation(channel, lo, hi)) {
      (cleared[c.login] ??= []).add((
        fromTs: c.fromTs,
        toTs: c.toTs,
        atTs: c.atTs,
      ));
    }
    final all = cleared[null] ?? const [];
    final defs = await _defsFor(channel, decoded);
    final drawn = await sets?.load(channel);
    final pending = edits ?? await store.edits(channel);
    final out = <ArchiveWindowBlock>[];
    for (var i = 0; i < blocks.length; i++) {
      final rows = decoded[i];
      final b = blocks[i];
      if (rows == null) {
        logDebug('[ArchiveReader] skipped damaged block ${b.key}');
        continue;
      }
      final messages = <TwitchMessage>[];
      for (final r in rows) {
        final edit = r.messageId == null ? null : pending[r.messageId];
        if (edit == ArchiveEdit.remove) continue;
        final m = adapter.fromRow(
          r,
          channel,
          asHistory: asHistory,
          defs: defs,
          sets: drawn,
        );
        // The reconnect grey marks a catch-up in the session it happened.
        m.isBackfill = false;
        if (edit == ArchiveEdit.deleted) m.deleted = true;
        if (!m.isSystem && !m.deleted && cleared.isNotEmpty) {
          final ts = m.timestamp.millisecondsSinceEpoch;
          bool hit(({int fromTs, int toTs, int? atTs}) c) =>
              ts >= c.fromTs && ts <= c.toTs;
          final c =
              cleared[m.login]?.where(hit).firstOrNull ??
              all.where(hit).firstOrNull;
          if (c != null) {
            m.deleted = true;
            // A range from before action times were kept ends at the action.
            m.deletedAt = DateTime.fromMillisecondsSinceEpoch(
              c.atTs ?? c.toTs,
              isUtc: true,
            );
          }
        }
        messages.add(m);
      }
      _sortStable(messages);
      out.add(
        ArchiveWindowBlock(
          key: b.key,
          start: DateTime.fromMillisecondsSinceEpoch(b.startTs, isUtc: true),
          end: DateTime.fromMillisecondsSinceEpoch(b.endTs, isUtc: true),
          rows: messages,
        ),
      );
    }
    return out;
  }

  /// The emote definitions [decoded] rows reference, read once per key.
  Future<Map<String, Emote>> _defsFor(
    String channel,
    List<List<ArchiveRow>?> decoded,
  ) async {
    final cache = _defs.putIfAbsent(channel, () => {});
    final missing = <String>{
      for (final rows in decoded)
        for (final r in rows ?? const <ArchiveRow>[])
          for (final t in r.tokens)
            if (!cache.containsKey(t.key)) t.key,
    };
    if (missing.isEmpty) return cache;
    final store = (await _store)!;
    for (final MapEntry(:key, :value) in (await store.emoteDefs(
      channel,
      missing,
    )).entries) {
      try {
        cache[key] = Emote.fromJson(jsonDecode(value) as Map<String, dynamic>);
      } on Object catch (e) {
        logDebug('[ArchiveReader] bad emote def $key: $e');
      }
    }
    return cache;
  }

  /// Messages of [channel] matching [query] in [scope] (see [ChatQuery]),
  /// at most [limit]. Newest first, older than
  /// [before] when given; with [after], the oldest at or after it. Only
  /// blocks the index allows are decoded.
  Future<List<TwitchMessage>> search(
    String channel,
    String query, {
    ChatSearchScope scope = ChatSearchScope.messages,
    int limit = 100,
    DateTime? before,
    DateTime? after,
  }) {
    final q = ChatQuery.parse(query, scope);
    if (q.isEmpty) return Future.value(const []);
    return find(
      ArchiveTerms.search(q),
      q.matches,
      channels: [channel],
      limit: limit,
      before: before,
      after: after,
    );
  }

  /// Rows passing [test] in [channels] (every archived channel when null),
  /// at most [limit], newest first; older than [before] when given, with
  /// [after] the oldest at or after it. Only blocks [terms] allows are
  /// decoded, nearest the start point first.
  Future<List<TwitchMessage>> find(
    ArchiveTerms terms,
    bool Function(TwitchMessage m) test, {
    List<String>? channels,
    int limit = 100,
    DateTime? before,
    DateTime? after,
  }) async {
    final store = await _store;
    if (store == null || limit <= 0) return const [];
    final beforeMs = before?.millisecondsSinceEpoch;
    final afterMs = after?.millisecondsSinceEpoch;
    bool hit(TwitchMessage m) {
      final t = m.timestamp.millisecondsSinceEpoch;
      return (beforeMs == null || t < beforeMs) &&
          (afterMs == null || t >= afterMs) &&
          test(m);
    }

    final names = channels ?? await store.channels();
    final out = <TwitchMessage>[
      for (final c in names)
        for (final m in unsealed(c))
          if (hit(m)) m,
    ];
    final blocks = [
      ...await _candidates(
        store,
        names,
        terms,
        beforeTs: beforeMs,
        afterTs: afterMs,
      ),
    ];
    final forward = after != null;
    final lastMs = beforeMs == null ? null : beforeMs - 1;
    blocks.sort(
      forward
          ? (a, b) => a.start.compareTo(b.start)
          : (a, b) => b.end.compareTo(a.end),
    );
    // The [limit]th match from the start point; a block starting past it
    // holds nothing nearer.
    int? edge() {
      if (out.length < limit) return null;
      final ts = [for (final m in out) m.timestamp.millisecondsSinceEpoch]
        ..sort();
      return forward ? ts[limit - 1] : ts[ts.length - limit];
    }

    // Batches grow from one block, so a common word stops early and a rare
    // one soon reads eight at a time.
    final filters = <String, ArchiveRowFilter>{};
    for (var i = 0, n = 1; i < blocks.length; i += n, n = min(n * 2, 8)) {
      final e = edge();
      if (e != null && (forward ? blocks[i].start > e : blocks[i].end < e)) {
        break;
      }
      final batch = blocks.sublist(i, min(i + n, blocks.length));
      for (final c in {for (final b in batch) b.channel}) {
        final edits = await store.edits(c);
        final stored = await store.blocksByKey([
          for (final b in batch)
            if (b.channel == c) b.id,
        ]);
        final f = filters[c] ??= await _filter(store, c, terms);
        // Rows past the [limit]th match so far cannot make the page.
        final keep = (
          texts: f.texts,
          states: f.states,
          both: f.both,
          system: f.system,
          fromMs: forward ? afterMs : _bound(afterMs, e, max),
          toMs: forward ? _bound(lastMs, e, min) : lastMs,
        );
        for (final d in await _decodeAll(c, stored, keep: keep, edits: edits)) {
          out.addAll(d.rows.where(hit));
        }
      }
    }
    // Unsealed rows can repeat a sealed one mid-seal.
    final seen = <String>{};
    final unique = [
      for (final m in out)
        if (m.messageId == null || seen.add(m.messageId!)) m,
    ]..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (unique.length <= limit) return unique;
    return forward
        ? unique.sublist(unique.length - limit)
        : unique.sublist(0, limit);
  }

  static int? _bound(int? a, int? b, int Function(int, int) pick) =>
      a == null ? b : (b == null ? a : pick(a, b));

  /// The row-level form of [terms] in [channel]: lowercased texts, and the
  /// sender states it accepts.
  Future<ArchiveRowFilter> _filter(
    ArchiveStore store,
    String channel,
    ArchiveTerms terms,
  ) async {
    final texts = [for (final t in terms.texts) t.toLowerCase()];
    final system = terms.system?.toLowerCase();
    final sender = terms.sender;
    if (sender == null) {
      return (
        texts: texts,
        states: const <int>{},
        both: false,
        system: system,
        fromMs: null,
        toMs: null,
      );
    }
    final t = await store.tables(channel);
    return (
      fromMs: null,
      toMs: null,
      texts: texts,
      both: terms.both,
      system: system,
      states: {
        for (final (id, s) in t.states.entries)
          if (t.whos[s.who] case final w? when sender(w.login, w.displayName))
            id,
      },
    );
  }

  /// Blocks of [channels] that may hold rows [terms] looks for.
  Future<List<({String channel, int id, int start, int end})>> _candidates(
    ArchiveStore store,
    List<String> channels,
    ArchiveTerms terms, {
    int? beforeTs,
    int? afterTs,
  }) async {
    Future<List<List<Set<int>>>> wordSets(Iterable<String> texts) async => [
      for (final text in texts)
        if (searchWords(text).toSet().toList() case final t when t.isNotEmpty)
          await store.wordIds(t),
    ];
    final words = await wordSets(terms.texts);
    final system = await wordSets([?terms.system]);
    final sender = terms.sender;
    final senders = <String, Set<int>>{};
    if (sender != null) {
      for (final channel in channels) {
        final t = await store.tables(channel);
        final who = {
          for (final (id, w) in t.whos.entries)
            if (sender(w.login, w.displayName)) id,
        };
        if (who.isNotEmpty) senders[channel] = who;
      }
    }
    return store.searchBlocks(
      channels,
      words: words.isEmpty ? null : words,
      senders: senders,
      both: terms.both,
      system: system.isEmpty ? null : system,
      beforeTs: beforeTs,
      afterTs: afterTs,
    );
  }

  /// Sort by time, keeping arrival order for equal timestamps (List.sort is
  /// not stable).
  static void _sortStable(List<TwitchMessage> rows) {
    final order = {for (var i = 0; i < rows.length; i++) rows[i]: i};
    rows.sort((a, b) {
      final c = a.timestamp.compareTo(b.timestamp);
      return c != 0 ? c : order[a]!.compareTo(order[b]!);
    });
  }
}
