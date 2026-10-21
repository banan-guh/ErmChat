import 'dart:convert';

/// One observation of a set (a provider's emotes, a channel's badges): what
/// a fetch returned at [atMs], stored as a diff against the observation
/// before it, or whole when [full]. [seenMs] is the last time a fetch saw
/// the same set. [hash] covers the whole set's keys, so a broken diff chain
/// shows, and a remote copy of the log can be compared by it.
class SetObservation {
  const SetObservation({
    required this.atMs,
    required this.seenMs,
    required this.full,
    required this.added,
    required this.removed,
    required this.hash,
  });

  final int atMs;
  final int seenMs;
  final bool full;

  /// Keys new to the set (all of them when [full]) and their definitions.
  final Map<String, String> added;
  final List<String> removed;
  final String hash;

  String get addedJson => jsonEncode(added);
  String get removedJson => jsonEncode(removed);

  static SetObservation fromJson({
    required int atMs,
    required int seenMs,
    required bool full,
    required String added,
    required String removed,
    required String hash,
  }) => SetObservation(
    atMs: atMs,
    seenMs: seenMs,
    full: full,
    added: (jsonDecode(added) as Map<String, dynamic>).cast<String, String>(),
    removed: (jsonDecode(removed) as List<dynamic>).cast<String>(),
    hash: hash,
  );
}

/// The observations of one set, oldest first, replayed into the set as it
/// was at any time. A removal counts from the first observation without
/// the key: the log knows no better, and a remote log with more
/// observations narrows it.
class SetLog {
  SetLog([Iterable<SetObservation> rows = const []]) {
    rows.forEach(_apply);
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
  SetObservation? diff(Map<String, String> items, int atMs) {
    final removed = [
      for (final k in _latest.keys)
        if (!items.containsKey(k)) k,
    ];
    final added = {
      for (final e in items.entries)
        if (!_latest.containsKey(e.key)) e.key: e.value,
    };
    if (_rows.isNotEmpty && removed.isEmpty && added.isEmpty) return null;
    final full = _rows.isEmpty || _sinceFull + 1 >= fullEvery;
    return SetObservation(
      atMs: atMs,
      seenMs: atMs,
      full: full,
      added: full ? {...items} : added,
      removed: full ? const [] : removed,
      hash: hashKeys(items.keys),
    );
  }

  /// Appends [o], which must be newer than every row.
  void add(SetObservation o) => _apply(o);

  /// Moves the newest row's [SetObservation.seenMs] to [ms].
  void touch(int ms) {
    final last = _rows.removeLast();
    _rows.add(
      SetObservation(
        atMs: last.atMs,
        seenMs: ms,
        full: last.full,
        added: last.added,
        removed: last.removed,
        hash: last.hash,
      ),
    );
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
