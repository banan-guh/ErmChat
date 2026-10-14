import '../models/twitch_message.dart';
import 'history_timeline.dart';

/// The rows the windowed history list holds: one contiguous run of history,
/// oldest first, addressed by position. Positions stay put while rows attach
/// or trim at either end, so list items can key on them; [reset] starts a
/// fresh run. Markers derive per position from the previous row's time.
class HistoryWindow {
  HistoryWindow({required this.now, LocalTime? local})
    : _local = local ?? _deviceLocal;

  /// Clock for day markers (only rows older than a day get one).
  final DateTime Function() now;
  final LocalTime _local;
  static DateTime _deviceLocal(DateTime t) => t.toLocal();

  /// Broadcasts for stream markers; set before rows attach.
  List<HistoryStream> streams = const [];

  final List<TwitchMessage> _rows = [];
  final Set<String> _keys = {};
  final Map<int, List<HistoryMarker>> _markers = {};
  int _base = 0;

  /// The first row is the oldest the source has; it gets its day marker.
  bool atOldest = false;

  /// The last row is the newest the source has.
  bool atNewest = false;

  int get first => _base;
  int get end => _base + _rows.length;
  int get length => _rows.length;
  bool get isEmpty => _rows.isEmpty;
  bool contains(int position) => position >= _base && position < end;

  TwitchMessage operator [](int position) => _rows[position - _base];
  TwitchMessage? at(int position) =>
      contains(position) ? _rows[position - _base] : null;

  List<HistoryMarker> markersAt(int position) => _markers[position] ?? const [];

  /// Identity for dedup and list keys: the message id, or the fields that
  /// stay fixed for an id-less row (archive rows drop ids after a day).
  static String keyOf(TwitchMessage m) =>
      m.messageId ??
      'anon-${m.timestamp.microsecondsSinceEpoch}-${m.login}-'
          '${m.text.hashCode}';

  /// Replaces the run with [rows] starting at position 0.
  void reset(List<TwitchMessage> rows) {
    _rows.clear();
    _keys.clear();
    _markers.clear();
    _base = 0;
    atOldest = false;
    atNewest = false;
    for (final r in rows) {
      if (_keys.add(keyOf(r))) _rows.add(r);
    }
    _mark(_base, end);
  }

  /// Attaches [rows] (oldest first) before the first row, skipping rows
  /// already held. Returns how many attached.
  int prepend(List<TwitchMessage> rows) {
    final fresh = [
      for (final r in rows)
        if (!_keys.contains(keyOf(r))) r,
    ];
    if (fresh.isEmpty) return 0;
    for (final r in fresh) {
      _keys.add(keyOf(r));
    }
    final oldFirst = _base;
    _rows.insertAll(0, fresh);
    _base -= fresh.length;
    // The old first row now has a predecessor.
    _mark(_base, oldFirst + 1);
    return fresh.length;
  }

  /// Attaches [rows] (oldest first) after the last row, skipping rows already
  /// held. Returns how many attached.
  int append(List<TwitchMessage> rows) {
    final from = end;
    for (final r in rows) {
      if (_keys.add(keyOf(r))) _rows.add(r);
    }
    _mark(from, end);
    return end - from;
  }

  /// Drops every row before [position].
  void trimBefore(int position) {
    final n = (position - _base).clamp(0, _rows.length);
    if (n == 0) return;
    for (var i = 0; i < n; i++) {
      _keys.remove(keyOf(_rows[i]));
      _markers.remove(_base + i);
    }
    _rows.removeRange(0, n);
    _base += n;
    atOldest = false;
    // The new first row lost its predecessor, so its markers are unknown.
    _markers.remove(_base);
  }

  /// Drops every row at or after [position].
  void trimFrom(int position) {
    final from = (position - _base).clamp(0, _rows.length);
    if (from == _rows.length) return;
    for (var i = from; i < _rows.length; i++) {
      _keys.remove(keyOf(_rows[i]));
      _markers.remove(_base + i);
    }
    _rows.removeRange(from, _rows.length);
    atNewest = false;
  }

  /// First position whose row is at or after [time]; [end] when none is.
  int positionAt(DateTime time) {
    var lo = 0;
    var hi = _rows.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_rows[mid].timestamp.isBefore(time)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return _base + lo;
  }

  /// Marks the first row as the oldest and gives it its leading markers.
  void markOldest() {
    atOldest = true;
    _mark(_base, _base + 1);
  }

  /// Recomputes markers for positions in [from]..[to). The first row gets
  /// markers only at the oldest end, since its predecessor is otherwise
  /// unknown.
  void _mark(int from, int to) {
    final clock = now();
    for (var p = from; p < to; p++) {
      _markers.remove(p);
      if (p == _base && !atOldest) continue;
      final m = markersBefore(
        prev: p == _base ? null : _rows[p - 1 - _base].timestamp,
        time: _rows[p - _base].timestamp,
        now: clock,
        streams: streams,
        local: _local,
      );
      if (m.isNotEmpty) _markers[p] = m;
    }
  }
}
