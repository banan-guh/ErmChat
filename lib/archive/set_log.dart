import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

/// Observation definitions as zlib bytes. A text value is an older row.
final _setZlib = ZLibCodec(level: 6);

/// Compresses an observation's definition JSON for storage.
Uint8List packSetJson(String json) =>
    Uint8List.fromList(_setZlib.encode(utf8.encode(json)));

/// A stored definition JSON, from a compressed blob or an older text row.
String unpackSetJson(Object stored) => stored is String
    ? stored
    : utf8.decode(_setZlib.decode(stored as List<int>));

/// One observation of a set (a provider's emotes, a channel's badges): what
/// a fetch returned at [atMs], stored as a diff against the observation
/// before it, or whole when [full]. [seenMs] is the last time a fetch saw
/// the same set. [hash] covers the whole set's keys, so a broken diff chain
/// shows, and a remote copy of the log can be compared by it.
class SetObservation {
  factory SetObservation({
    required int atMs,
    required int seenMs,
    required bool full,
    required Map<String, String> added,
    required List<String> removed,
    required String hash,
  }) => SetObservation._(atMs, seenMs, full, added, null, removed, hash);

  SetObservation._(
    this.atMs,
    this.seenMs,
    this.full,
    this._added,
    this._stored,
    this.removed,
    this.hash,
  );

  final int atMs;
  final int seenMs;
  final bool full;

  final Map<String, String>? _added;

  /// The stored definition JSON, a String for older text rows or zlib bytes.
  /// Inflated on first read, so a snapshot nobody replays costs nothing.
  final Object? _stored;
  Map<String, String>? _decoded;

  /// Keys new to the set (all of them when [full]) and their definitions.
  /// A stored snapshot decodes on first read, so one that is never replayed
  /// costs no parse.
  Map<String, String> get added =>
      _added ??
      (_decoded ??=
          (jsonDecode(unpackSetJson(_stored!)) as Map<String, dynamic>)
              .cast<String, String>());

  final List<String> removed;
  final String hash;

  String get addedJson =>
      _stored != null ? unpackSetJson(_stored) : jsonEncode(_added!);
  String get removedJson => jsonEncode(removed);

  /// This observation with only [seenMs] replaced; every other field, and
  /// the maps and lists it shares, are carried over unchanged.
  SetObservation _withSeen(int ms) {
    final stored = _stored;
    return SetObservation._(
      atMs,
      ms,
      full,
      stored != null ? null : _added,
      stored,
      removed,
      hash,
    );
  }

  static SetObservation fromStored({
    required int atMs,
    required int seenMs,
    required bool full,
    required Object added,
    required String removed,
    required String hash,
  }) => SetObservation._(
    atMs,
    seenMs,
    full,
    null,
    added,
    (jsonDecode(removed) as List<dynamic>).cast<String>(),
    hash,
  );

  static SetObservation fromJson({
    required int atMs,
    required int seenMs,
    required bool full,
    required String added,
    required String removed,
    required String hash,
  }) => fromStored(
    atMs: atMs,
    seenMs: seenMs,
    full: full,
    added: added,
    removed: removed,
    hash: hash,
  );
}

/// The observations of one set, oldest first, replayed into the set as it
/// was at any time. A removal counts from the first observation without
/// the key: the log knows no better, and a remote log with more
/// observations narrows it.
class SetLog {
  SetLog([Iterable<SetObservation> rows = const []]) {
    _rows.addAll(rows);
    _primeLatest();
  }

  /// Builds the current state from the newest full snapshot and the deltas
  /// after it. Older snapshots stay unparsed until [stateAt] needs one.
  void _primeLatest() {
    if (_rows.isEmpty) return;
    var from = _rows.length - 1;
    while (from > 0 && !_rows[from].full) {
      from--;
    }
    var state = <String, String>{};
    for (var i = from; i < _rows.length; i++) {
      final o = _rows[i];
      state = _replay(o.full ? {} : state, o);
      _sinceFull = o.full ? 0 : _sinceFull + 1;
    }
    _latest = state;
  }

  /// A diff run this long ends in a whole snapshot, so replay stays short.
  static const fullEvery = 32;

  final _rows = <SetObservation>[];
  Map<String, String> _latest = {};
  int _sinceFull = 0;

  List<SetObservation> get rows => List.unmodifiable(_rows);
  Map<String, String> get latest => Map.unmodifiable(_latest);

  void _apply(SetObservation o) {
    _rows.add(o);
    _latest = _replay(o.full ? {} : _latest, o);
    _sinceFull = o.full ? 0 : _sinceFull + 1;
  }

  static Map<String, String> _replay(
    Map<String, String> base,
    SetObservation o,
  ) {
    final next = {...base};
    for (final key in o.removed) {
      next.remove(key);
    }
    next.addAll(o.added);
    return next;
  }

  /// The set as observed at [ms]: empty before the first observation.
  Map<String, String> at(int ms) =>
      _rows.isEmpty || ms < _rows.first.atMs ? {} : stateAt(indexAt(ms));

  /// The row in force at [ms]: the newest at or before it, or the first
  /// when [ms] is older than every row (the nearest knowledge). -1 when
  /// there are no rows.
  int indexAt(int ms) {
    var lo = 0;
    var hi = _rows.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_rows[mid].atMs <= ms) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return hi;
  }

  /// The set as of row [index], replayed from the full snapshot before it.
  Map<String, String> stateAt(int index) {
    var from = index;
    while (from > 0 && !_rows[from].full) {
      from--;
    }
    var state = <String, String>{};
    for (var i = from; i <= index; i++) {
      state = _replay(state, _rows[i]);
    }
    return state;
  }

  /// Notes that a fetch at [atMs] returned [items]. Returns the observation
  /// to store, or null when the set is unchanged (the caller moves the last
  /// one's [SetObservation.seenMs] instead). Nothing is applied until
  /// [add].
  SetObservation? diff(Map<String, String> items, int atMs) =>
      diffKeys(items.keys, (key) => items[key]!, atMs);

  /// [diff] for a set whose definitions cost more to encode than to keep, so
  /// [encode] runs only for the keys the observation stores.
  SetObservation? diffKeys(
    Iterable<String> keys,
    String Function(String key) encode,
    int atMs,
  ) {
    final present = keys.toSet();
    final removed = [
      for (final k in _latest.keys)
        if (!present.contains(k)) k,
    ];
    final added = [
      for (final k in present)
        if (!_latest.containsKey(k)) k,
    ];
    if (_rows.isNotEmpty && removed.isEmpty && added.isEmpty) return null;
    final full = _rows.isEmpty || _sinceFull + 1 >= fullEvery;
    final stored = full ? present : added;
    return SetObservation(
      atMs: atMs,
      seenMs: atMs,
      full: full,
      added: {for (final k in stored) k: encode(k)},
      removed: full ? const [] : removed,
      hash: hashKeys(present),
    );
  }

  /// Appends [o], which must be newer than every row.
  void add(SetObservation o) => _apply(o);

  /// Moves the newest row's [SetObservation.seenMs] to [ms].
  void touch(int ms) {
    final last = _rows.removeLast();
    _rows.add(last._withSeen(ms));
  }

  /// FNV-1a over the sorted keys, as 16 hex digits.
  static String hashKeys(Iterable<String> keys) {
    var h = 0xcbf29ce484222325;
    for (final key in keys.toList()..sort()) {
      for (final unit in utf8.encode('$key\n')) {
        h ^= unit;
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
      }
    }
    return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }
}
