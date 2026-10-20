/// Values interned to small integer ids: a lookup by id and a reverse index
/// by value. Ids are handed out in order and never reused until [compact].
///
/// Dense tables keep values in a list indexed by id, so a removed id leaves
/// an empty slot until [compact] closes the gaps. Sparse tables keep them in
/// a map instead, for ids that stored data points into and that therefore
/// can never be renumbered.
class InternTable<T extends Object> {
  InternTable() : _list = [], _map = null;

  InternTable.sparse() : _list = null, _map = {};

  final List<T?>? _list;
  final Map<int, T>? _map;
  final Map<T, int> _ids = {};
  int _next = 0;

  /// The id the next new value gets.
  int get length => _next;

  /// Live values.
  int get count => _ids.length;

  T? operator [](int? id) {
    if (id == null || id < 0) return null;
    final list = _list;
    if (list == null) return _map![id];
    return id < list.length ? list[id] : null;
  }

  int? idOf(T value) => _ids[value];

  /// Live ids and values, in id order for a dense table.
  Iterable<(int, T)> get entries sync* {
    final list = _list;
    if (list == null) {
      for (final e in _map!.entries) {
        yield (e.key, e.value);
      }
      return;
    }
    for (var i = 0; i < list.length; i++) {
      if (list[i] case final v?) yield (i, v);
    }
  }

  /// The id of [value], adding it when new.
  int intern(T value) => _ids.putIfAbsent(value, () {
    _set(_next, value);
    return _next++;
  });

  /// Restores a saved [value] at [id], in any order.
  void put(int id, T value) {
    _set(id, value);
    _ids[value] = id;
    if (id >= _next) _next = id + 1;
  }

  void _set(int id, T value) {
    final list = _list;
    if (list == null) {
      _map![id] = value;
      return;
    }
    while (list.length <= id) {
      list.add(null);
    }
    list[id] = value;
  }

  /// Drops [ids]; a dense table keeps their slots empty.
  void remove(Iterable<int> ids) {
    for (final id in ids) {
      final value = this[id];
      if (value == null) continue;
      _ids.remove(value);
      final list = _list;
      if (list == null) {
        _map!.remove(id);
      } else {
        list[id] = null;
      }
    }
  }

  /// Drops every id from [length] on, after a write that added them failed.
  void truncate(int length) {
    remove([for (var id = length; id < _next; id++) id]);
    _list?.length = length;
    _next = length;
  }

  /// Replaces every value with [values] by position, null for a gap. Only
  /// dense tables reset.
  void reset(List<T?> values) {
    final list = _list!;
    list
      ..clear()
      ..addAll(values);
    _ids.clear();
    for (var i = 0; i < values.length; i++) {
      if (values[i] case final v?) _ids[v] = i;
    }
    _next = values.length;
  }

  /// Whether fewer than half the ids handed out are still live, so
  /// [compact] would at least halve the table.
  bool get sparse => _list != null && _ids.length * 2 < _next;

  /// Swaps the value at live [id] for [value].
  void replace(int id, T value) {
    final old = this[id];
    if (old != null) _ids.remove(old);
    _set(id, value);
    _ids[value] = id;
  }

  /// What [compact] would return now, without compacting.
  List<int> compactPlan() {
    final list = _list!;
    final remap = List<int>.filled(list.length, -1);
    var to = 0;
    for (var i = 0; i < list.length; i++) {
      if (list[i] != null) remap[i] = to++;
    }
    return remap;
  }

  /// Renumbers live values to 0.. in id order. Returns each old id's new id,
  /// or -1 for an empty slot. Only dense tables compact.
  List<int> compact() {
    final list = _list!;
    final remap = compactPlan();
    for (var i = 0; i < list.length; i++) {
      final to = remap[i];
      if (to < 0) continue;
      final v = list[i]!;
      list[to] = v;
      _ids[v] = to;
    }
    _next = list.length = _ids.length;
    return remap;
  }
}
