import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../util/log.dart';
import 'transport/events.dart';

export 'transport/events.dart' show IrcSocketRole;

/// Account-wide JOIN pacing: 20 commands/10.5s, token bucket, single read-socket
/// per channel. Each tick sends one batched `JOIN #a,#b,…` line (up to
/// [batchSize] channels) so N channels cost N Twitch joins but only one
/// WebSocket frame.
class JoinRateLimiter {
  JoinRateLimiter({
    this.capacity = 20,
    this.window = const Duration(milliseconds: 10500),
    this.pumpInterval = const Duration(seconds: 3),
    this.batchSize = _batchSize,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _lastRefill = _now();
  }

  /// Completed channels per [window]; bucket starts full.
  final int capacity;

  /// Refill window (slightly longer than Twitch's 10s to avoid boundary overflows).
  final Duration window;

  /// Pump interval; one batched JOIN line per tick.
  final Duration pumpInterval;

  /// Max channels per batched JOIN line. 6/3s keeps the steady rate at ~2/s
  /// (inside Twitch's 20/10s ceiling) while collapsing frames.
  static const _batchSize = 6;

  /// Batched JOIN lines per pump tick while the bucket affords it. A fresh
  /// bucket fires 3 lines (18 channels) at once; the bucket then paces the
  /// rest as tokens refill. Direct-Twitch only: bypassed roles drain
  /// everything on microtasks regardless.
  static const _burstsPerTick = 3;

  /// Channels per batched JOIN line.
  final int batchSize;

  final DateTime Function() _now;

  double _tokens = -1; // resolved to [capacity] on first use (see _refill)
  late DateTime _lastRefill;
  Timer? _pumpTimer;
  bool _pumpScheduled = false;
  final _handlers = <IrcSocketRole, bool Function(List<String> channels)>{};
  final _queue = <({String channel, IrcSocketRole role})>[];
  // Roles whose units dispatch immediately without token or tick waits.
  // The proxied read socket sets this: proxy traffic costs no Twitch
  // budget, so app-side pacing would only add dead delay.
  final _bypassRoles = <IrcSocketRole>{};
  // Completed units: prevents re-joining on socket bounce.
  final _completed = <String, DateTime>{};
  static const _completionMemory = Duration(seconds: 90);

  /// Tokens available right now (fractional), capped at [capacity].
  @visibleForTesting
  double get availableTokens {
    _refill();
    return _tokens;
  }

  void registerHandler(
    IrcSocketRole role,
    bool Function(List<String> channels) send,
  ) {
    _handlers[role] = send;
  }

  /// Enqueues one JOIN; duplicates no-op. [force] overrides recent completion.
  void enqueue(String channel, IrcSocketRole role, {bool force = false}) {
    if (!force) {
      final completedAt = _completed[channel];
      if (completedAt != null &&
          _now().difference(completedAt) < _completionMemory) {
        return;
      }
      _completed.remove(channel);
    }
    final existing = _queue.indexWhere(
      (unit) => unit.channel == channel && unit.role == role,
    );
    if (existing >= 0) {
      // Duplicate: single JOIN, nothing to add.
      PerfLog.I.record('JOINQ', 'dup $channel (ignored)');
      _schedulePump();
      return;
    }
    _queue.add((channel: channel, role: role));
    PerfLog.I.record(
      'JOINQ',
      'enqueue $channel $role (depth=${_queue.length})',
    );
    _start();
    // Kick pump once per burst; deduplicated to engage send cap.
    _schedulePump();
  }

  void _schedulePump() {
    if (_pumpScheduled) return;
    _pumpScheduled = true;
    Future.microtask(() {
      _pumpScheduled = false;
      _pump();
    });
  }

  /// Marks [role] as unpaced: queued units dispatch back-to-back on
  /// microtasks instead of waiting for tokens or pump ticks.
  void setBypass(IrcSocketRole role, bool value) {
    if (value) {
      _bypassRoles.add(role);
    } else {
      _bypassRoles.remove(role);
    }
    _schedulePump();
  }

  /// Drops pending unit (e.g. channel parted).
  void removeEntry(String channel) {
    _queue.removeWhere((unit) => unit.channel == channel);
    if (_queue.isEmpty) _stop();
  }

  /// Moves [channel] to the front of the queue so the next pump tick
  /// dispatches it first. No-op if not queued or already at head.
  bool bumpToFront(String channel) {
    final index = _queue.indexWhere((unit) => unit.channel == channel);
    if (index <= 0) return index == 0;
    final unit = _queue.removeAt(index);
    _queue.insert(0, unit);
    _schedulePump();
    return true;
  }

  /// Empties queue (session teardown).
  void clear() {
    _queue.clear();
    _stop();
  }

  /// Drops completion memory (e.g. parted channel re-join).
  void forget(String channel) {
    _completed.remove(channel);
  }

  /// Drops all pending units for [role] (dead socket cleanup).
  void dropRole(IrcSocketRole role) {
    _queue.removeWhere((unit) => unit.role == role);
    if (_queue.isEmpty) _stop();
  }

  void _start() {
    _pumpTimer ??= Timer.periodic(pumpInterval, (_) => _pump());
  }

  void _stop() {
    _pumpTimer?.cancel();
    _pumpTimer = null;
  }

  void _refill() {
    final now = _now();
    if (_tokens < 0) {
      _tokens = capacity.toDouble();
      _lastRefill = now;
      return;
    }
    final elapsedMs = now.difference(_lastRefill).inMicroseconds / 1000.0;
    if (elapsedMs <= 0) return;
    _lastRefill = now;
    final ratePerMs = capacity / window.inMilliseconds;
    _tokens = math.min(capacity.toDouble(), _tokens + elapsedMs * ratePerMs);
  }

  void _pump() {
    _refill();
    if (_queue.isEmpty) {
      _stop();
      return;
    }
    final head = _queue.first;
    final handler = _handlers[head.role];
    if (handler == null) {
      // No handler for this role: drop the unit to avoid starvation.
      final dropped = _queue.removeAt(0);
      PerfLog.I.record(
        'JOINQ',
        'dispatch ${dropped.channel} ${dropped.role.name}:no-handler (dropped)',
      );
      return;
    }
    if (_tokens < 1 && !_bypassRoles.contains(head.role)) {
      return; // wait for the bucket to refill
    }
    // Up to [_burstsPerTick] batched JOIN lines per tick while the bucket
    // affords them. Bypassed roles skip the token check: their traffic
    // costs no budget.
    final bypass = _bypassRoles.contains(head.role);
    var batches = 0;
    while (batches < _burstsPerTick &&
        _queue.isNotEmpty &&
        _queue.first.role == head.role &&
        (_tokens >= 1 || bypass)) {
      final batch = <String>[];
      final taken = <({String channel, IrcSocketRole role})>[];
      while (batch.length < batchSize &&
          _queue.isNotEmpty &&
          _queue.first.role == head.role &&
          (_tokens >= 1 || bypass)) {
        final unit = _queue.removeAt(0);
        taken.add(unit);
        batch.add(unit.channel);
        if (!bypass) _tokens -= 1;
      }
      if (batch.isEmpty) break;
      final sent = handler(batch);
      if (sent) {
        for (final unit in taken) {
          _completed[unit.channel] = _now();
        }
        PerfLog.I.record(
          'JOINQ',
          'dispatch batch(${batch.length}) ${head.role.name}:ok '
              'tokens=${_tokens.toStringAsFixed(2)}',
        );
        batches++;
      } else {
        // Socket down: put the units back at the front, untouched, so a later
        // pump retries them; refund the tentatively spent tokens.
        for (var k = taken.length - 1; k >= 0; k--) {
          _queue.insert(0, taken[k]);
        }
        if (!bypass) _tokens += taken.length;
        PerfLog.I.record(
          'JOINQ',
          'dispatch batch ${head.role.name}:dead (stays queued)',
        );
        break;
      }
    }
    if (_queue.isEmpty) {
      _stop();
    } else if (bypass && batches > 0 && _queue.first.role == head.role) {
      // Bypassed remainder drains on microtasks, not pump ticks.
      _schedulePump();
    }
  }
}
