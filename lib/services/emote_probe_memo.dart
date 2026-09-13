import 'package:flutter/foundation.dart';

/// Memoizes disk-cache probe results with TTL. Deduplicates concurrent probes per URL.
class EmoteProbeMemo {
  EmoteProbeMemo({
    this.ttl = const Duration(seconds: 60),
    DateTime Function()? now,
    this.maxEntries = 2048,
  }) : _now = now ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _now;

  /// Upper bound on retained results; over-cap inserts drop the oldest.
  final int maxEntries;

  final Map<String, Future<bool>> _inflight = {};
  final Map<String, (bool, DateTime)> _entries = {};

  /// Probes [url] with dedup and TTL memoization. Errors clear the slot.
  Future<bool> probe(String url, Future<bool> Function(String) check) {
    final entry = _entries[url];
    if (entry != null) {
      if (_now().difference(entry.$2) < ttl) {
        return SynchronousFuture<bool>(entry.$1);
      }
      _entries.remove(url);
    }
    return _inflight.putIfAbsent(url, () => _run(url, check));
  }

  Future<bool> _run(String url, Future<bool> Function(String) check) async {
    try {
      final cached = await check(url);
      _entries[url] = (cached, _now());
      _prune();
      return cached;
    } on Object {
      // Leave no decision recorded; a retry may succeed.
      _entries.remove(url);
      rethrow;
    } finally {
      _inflight.remove(url);
    }
  }

  /// Drops expired results, then the oldest retained ones down to the cap.
  void _prune() {
    if (_entries.length <= maxEntries) return;
    final cutoff = _now().subtract(ttl);
    _entries.removeWhere((_, entry) => entry.$2.isBefore(cutoff));
    final excess = _entries.length - maxEntries;
    if (excess <= 0) return;
    final it = _entries.keys.iterator;
    for (var i = 0; i < excess && it.moveNext(); i++) {
      _entries.remove(it.current);
    }
  }

  /// Drops every memoized result. Exposed for tests.
  @visibleForTesting
  void reset() {
    _inflight.clear();
    _entries.clear();
  }
}
