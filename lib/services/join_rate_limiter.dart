import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../util/log.dart';
import 'base_irc_connection.dart' show IrcSocketRole;

export 'base_irc_connection.dart' show IrcSocketRole;

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

  /// Channels per batched JOIN line.
  final int batchSize;

  final DateTime Function() _now;

  double _tokens = -1; // resolved to [capacity] on first use (see _refill)
  late DateTime _lastRefill;
  Timer? _pumpTimer;
  bool _pumpScheduled = false;
  final _handlers = <IrcSocketRole, bool Function(List<String> channels)>{};
  final _queue = <({String channel, IrcSocketRole role})>[];
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

  /// Drops pending unit (e.g. channel parted).
  void removeEntry(String channel) {
    _queue.removeWhere((unit) => unit.channel == channel);
    if (_queue.isEmpty) _stop();
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

  /// 1-based FIFO position, or null.
  int? positionOf(String channel) {
    final index = _queue.indexWhere((unit) => unit.channel == channel);
    return index < 0 ? null : index + 1;
  }

  /// Pending units with positions (drives queue countdowns).
  List<({String channel, int position})> pending() {
    return [
      for (var i = 0; i < _queue.length; i++)
        (channel: _queue[i].channel, position: i + 1),
    ];
  }

  /// ETA seconds for [channel]'s JOIN (respects token + per-pump batch cap).
  int etaSecondsForChannel(String channel) {
    final index = _queue.indexWhere((unit) => unit.channel == channel);
    if (index < 0) return 0;
    // Channels in the leading batch go out this pump.
    if (index < batchSize && availableTokens >= index + 1) return 0;
    // Each batched line covers [batchSize] channels and is one pump tick.
    final position = index + 1;
    final batches = ((position + batchSize - 1) ~/ batchSize);
    final tokenSeconds = math.max(
      0,
      (position - availableTokens) * window.inMilliseconds / capacity / 1000,
    );
    final capSeconds = batches * pumpInterval.inMilliseconds / 1000;
    return math.max(tokenSeconds, capSeconds).ceil();
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
    if (_tokens < 1) return; // wait for the bucket to refill
    // One batched JOIN line per pump tick, up to [batchSize] channels.
    final batch = <String>[];
    final taken = <({String channel, IrcSocketRole role})>[];
    while (batch.length < batchSize &&
        _queue.isNotEmpty &&
        _queue.first.role == head.role &&
        _tokens >= 1) {
      final unit = _queue.removeAt(0);
      taken.add(unit);
      batch.add(unit.channel);
      _tokens -= 1;
    }
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
    } else {
      // Socket down: put the units back at the front, untouched, so a later
      // pump retries them; refund the tentatively spent tokens.
      for (var k = taken.length - 1; k >= 0; k--) {
        _queue.insert(0, taken[k]);
      }
      _tokens += taken.length;
      PerfLog.I.record(
        'JOINQ',
        'dispatch batch ${head.role.name}:dead (stays queued)',
      );
    }
    if (_queue.isEmpty) _stop();
  }
}
