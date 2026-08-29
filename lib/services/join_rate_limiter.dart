import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../util/log.dart';
import 'base_irc_connection.dart' show IrcSocketRole;

export 'base_irc_connection.dart' show IrcSocketRole;

/// Account-wide JOIN pacing: 20 commands/10.5s, token bucket, single read-socket per channel.
class JoinRateLimiter {
  JoinRateLimiter({
    this.capacity = 20,
    this.window = const Duration(milliseconds: 10500),
    this.pumpInterval = const Duration(milliseconds: 1050),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _lastRefill = _now();
  }

  /// Completed channels per [window]; bucket starts full.
  final int capacity;

  /// Refill window (slightly longer than Twitch's 10s to avoid boundary overflows).
  final Duration window;

  /// Pump interval; 2 channels/tick smooths the burst.
  final Duration pumpInterval;

  /// Max JOIN sends per pump (2 keeps burst under Twitch limit).
  static const _maxSendsPerPump = 2;

  final DateTime Function() _now;

  double _tokens = -1; // resolved to [capacity] on first use (see _refill)
  late DateTime _lastRefill;
  Timer? _pumpTimer;
  bool _pumpScheduled = false;
  final _handlers = <IrcSocketRole, bool Function(String channel)>{};
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

  void registerHandler(IrcSocketRole role, bool Function(String channel) send) {
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
    final existing = _queue.indexWhere((unit) => unit.channel == channel);
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

  /// ETA seconds for [channel]'s JOIN (respects token + pump cap bottlenecks).
  int etaSecondsForChannel(String channel) {
    final index = _queue.indexWhere((unit) => unit.channel == channel);
    if (index < 0) return 0;
    // Head unit with banked token: goes out this pump.
    if (index == 0 && availableTokens >= 1) return 0;
    // Each queued unit = one JOIN.
    final commands = index + 1;
    final tokenSeconds = math.max(
      0,
      (commands - availableTokens) * window.inMilliseconds / capacity / 1000,
    );
    final capSeconds =
        (commands / _maxSendsPerPump).ceil() *
        pumpInterval.inMilliseconds /
        1000;
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
    var walk = _queue.length;
    var index = 0;
    var sendsThisPump = 0;
    while (_tokens >= 1 &&
        sendsThisPump < _maxSendsPerPump &&
        walk > 0 &&
        index < _queue.length) {
      final unit = _queue[index];
      walk--;
      // Dispatch JOIN; success consumes token, failure retries next pump.
      final handler = _handlers[unit.role];
      if (handler != null) {
        final sent = handler.call(unit.channel);
        if (sent) {
          _tokens -= 1;
          sendsThisPump++;
          _queue.removeAt(index);
          _completed[unit.channel] = _now();
          PerfLog.I.record(
            'JOINQ',
            'dispatch ${unit.channel} ${unit.role.name}:ok '
                'tokens=${_tokens.toStringAsFixed(2)}',
          );
        } else {
          PerfLog.I.record(
            'JOINQ',
            'dispatch ${unit.channel} ${unit.role.name}:dead (stays queued)',
          );
          // Retry in place; step past so others get a chance.
          index++;
        }
      } else {
        // No handler: drop unit to avoid starvation.
        _queue.removeAt(index);
        PerfLog.I.record(
          'JOINQ',
          'dispatch ${unit.channel} ${unit.role.name}:no-handler (dropped)',
        );
      }
      if (_tokens < 1) break;
    }
    if (_queue.isEmpty) _stop();
  }
}
