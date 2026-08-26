import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'base_irc_connection.dart' show IrcSocketRole;

/// Account-wide pacing for IRC JOIN commands.
///
/// Twitch throttles connections that fire JOINs faster than roughly 20
/// message commands per 10 seconds, silently dropping the excess. Both IRC
/// sockets (read + write) share one [JoinRateLimiter] so their combined
/// demand stays inside that budget instead of each socket racing its own
/// burst limiter.
///
/// Entries sit in a single FIFO across roles; a pump drains heads whenever
/// at least one token is available. Tokens refill continuously at
/// [capacity]/[window] (starting full), computed lazily on access so no
/// dedicated ticker runs while idle. A failed send (socket down) drops the
/// entry: the connection re-queues every channel itself after the handshake,
/// mirroring the old per-socket queue behavior.
class JoinRateLimiter {
  JoinRateLimiter({
    this.capacity = 20,
    this.window = const Duration(milliseconds: 10500),
    this.pumpInterval = const Duration(milliseconds: 500),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _lastRefill = _now();
  }

  /// JOINs allowed per [window]; the bucket starts full.
  final int capacity;

  /// Refill window. Slightly longer than Twitch's documented 10s budget so
  /// boundary effects never push a rolling window over the limit.
  final Duration window;

  /// How often the pump wakes while entries are queued. Only affects drip
  /// granularity, not throughput.
  final Duration pumpInterval;

  final DateTime Function() _now;

  double _tokens = -1; // resolved to [capacity] on first use (see _refill)
  late DateTime _lastRefill;
  Timer? _pumpTimer;
  final _handlers = <IrcSocketRole, bool Function(String channel)>{};
  final _queue = <({IrcSocketRole role, String channel})>[];

  /// Tokens available right now (fractional), capped at [capacity].
  @visibleForTesting
  double get availableTokens {
    _refill();
    return _tokens;
  }

  void registerHandler(IrcSocketRole role, bool Function(String channel) send) {
    _handlers[role] = send;
  }

  /// Queues a JOIN unless an identical entry is already waiting.
  void enqueue(IrcSocketRole role, String channel) {
    if (_queue.any((e) => e.role == role && e.channel == channel)) return;
    _queue.add((role: role, channel: channel));
    _start();
    // Coalesce a synchronous burst of join() calls into one pump instead of
    // letting the first entry pay nothing but the rest wait a full interval.
    Future.microtask(_pump);
  }

  /// Drops one pending entry (e.g. the channel was parted).
  void removeEntry(IrcSocketRole role, String channel) {
    _queue.removeWhere((e) => e.role == role && e.channel == channel);
    if (_queue.isEmpty) _stop();
  }

  /// Drops every pending entry for [role]: used when its socket dies; the
  /// reconnect path re-queues the channels itself.
  void dropRole(IrcSocketRole role) {
    _queue.removeWhere((e) => e.role == role);
    if (_queue.isEmpty) _stop();
  }

  /// 1-based FIFO position of the pending entry, or null when not queued.
  int? positionOf(IrcSocketRole role, String channel) {
    final index = _queue.indexWhere(
      (e) => e.role == role && e.channel == channel,
    );
    return index < 0 ? null : index + 1;
  }

  /// Seconds until the entry at 1-based [position] would go out, assuming
  /// nothing ahead of it is removed first.
  int etaSecondsForPosition(int position) {
    final deficit = position - availableTokens;
    if (deficit <= 0) return 0;
    final ratePerSecond = capacity * 1000 / window.inMilliseconds;
    return (deficit / ratePerSecond).ceil();
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
    while (_tokens >= 1 && walk > 0 && _queue.isNotEmpty) {
      final head = _queue.first;
      final handler = _handlers[head.role];
      walk--;
      // No handler or a dead socket drops the entry; the connection's own
      // reconnect path re-queues it once the handshake completes.
      final sent = handler?.call(head.channel) ?? false;
      _queue.removeAt(0);
      if (sent) _tokens -= 1;
    }
    if (_queue.isEmpty) _stop();
  }
}
