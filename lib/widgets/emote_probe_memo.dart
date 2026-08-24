import 'package:flutter/foundation.dart';

/// Memoizes "is this URL cached" probe results shared by every emote widget
/// rendering the same asset.
///
/// Under emote spam one message can hold hundreds of copies of the same
/// emote; without memoization each copy independently checks the image cache
/// and hits the disk cache for its placeholder probe. Results of either kind
/// expire after [ttl] (cache contents change under eviction and lazy
/// downloads, so answers must stay fresh), which still covers a burst: all
/// copies of an emote probe within milliseconds of each other. Concurrent
/// probes of one URL share a single in-flight check.
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

  /// Resolves whether [url] is cached via [check], deduplicating concurrent
  /// probes and replaying fresh memoized results. Errors from [check]
  /// propagate to every waiter and clear the in-flight slot.
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
