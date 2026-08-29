import 'package:flutter/foundation.dart';

/// Memoizes disk-cache probe results with TTL. Deduplicates concurrent probes per URL.
class EmoteProbeMemo {
  EmoteProbeMemo({
    this.ttl = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static final EmoteProbeMemo instance = EmoteProbeMemo();

  final Duration ttl;
  final DateTime Function() _now;

  final Map<String, Future<bool>> _inflight = {};
  final Map<String, (bool, DateTime)> _entries = {};

  /// Probes [url] with dedup and TTL memoization. Errors clear the slot.
  Future<bool> probe(String url, Future<bool> Function(String) check) {
    final entry = _entries[url];
    if (entry != null && _now().difference(entry.$2) < ttl) {
      return SynchronousFuture<bool>(entry.$1);
    }
    return _inflight.putIfAbsent(url, () => _run(url, check));
  }

  Future<bool> _run(String url, Future<bool> Function(String) check) async {
    try {
      final cached = await check(url);
      _entries[url] = (cached, _now());
      return cached;
    } on Object {
      // Leave no decision recorded; a retry may succeed.
      _entries.remove(url);
      rethrow;
    } finally {
      _inflight.remove(url);
    }
  }

  /// Drops every memoized result. Exposed for tests.
  @visibleForTesting
  void reset() {
    _inflight.clear();
    _entries.clear();
  }
}
