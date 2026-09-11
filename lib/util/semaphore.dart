import 'dart:async';

/// FIFO permit gate: runs an action only when a permit is free.
class Semaphore {
  Semaphore(this.maxPermits) : _permits = maxPermits;

  final int maxPermits;
  int _permits;
  final List<Completer<void>> _queue = [];

  Future<T> withPermit<T>(Future<T> Function() action) async {
    await _acquire();
    try {
      return await action();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_permits > 0) {
      _permits--;
      return Future.value();
    }
    final c = Completer<void>();
    _queue.add(c);
    return c.future;
  }

  void _release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    } else {
      _permits++;
    }
  }
}
