import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../util/log.dart';
import 'base_irc_connection.dart' show IrcSocketRole;

export 'base_irc_connection.dart' show IrcSocketRole;

/// Account-wide pacing for IRC JOIN commands.
///
/// Every channel is a SINGLE read-socket JOIN, so a queue unit is one channel
/// carrying exactly one pending [IrcSocketRole]: the unit goes out the moment
/// that role's socket sends its JOIN. The [role] tag routes the send and lets a
/// dying socket drop its own units via [dropRole] - there is no read/write pair
/// to keep in lockstep anymore.
///
/// Twitch budgets roughly 20 message commands per 10 seconds per connection;
/// a completed channel costs exactly one JOIN command, so [capacity] counts
/// completed channels (default 20) over [window] (10.5s) = 20 channels/window.
/// Tokens are consumed per successful send and refill continuously at
/// capacity/window starting from a full bucket, computed lazily on access.
/// Units whose send fails (socket down) stay queued and retry on every pump;
/// the owning connections also re-queue their channels after each handshake.
class JoinRateLimiter {
  JoinRateLimiter({
    this.capacity = 20,
    this.window = const Duration(milliseconds: 10500),
    this.pumpInterval = const Duration(milliseconds: 1050),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _lastRefill = _now();
  }

  /// Completed channels per [window]; the bucket starts full. Every successful
  /// JOIN send consumes one token, so a full bucket covers 20 channels = the
  /// documented 20 commands per socket per window.
  final int capacity;

  /// Refill window. Slightly longer than Twitch's documented 10s budget so
  /// boundary effects never push a rolling window over the limit.
  final Duration window;

  /// How often the pump wakes while units are queued. With the send cap
  /// below this sets the steady-state pace: two channels per tick ~= your
  /// "20 channels / 10.5s" spread smoothly instead of as a burst.
  final Duration pumpInterval;

  /// Max JOIN commands sent per pump wake. Two per tick = two channels, which
  /// keeps even the initial full-bucket burst inside Twitch's silent-drop
  /// territory.
  static const _maxSendsPerPump = 2;

  final DateTime Function() _now;

  double _tokens = -1; // resolved to [capacity] on first use (see _refill)
  late DateTime _lastRefill;
  Timer? _pumpTimer;
  bool _pumpScheduled = false;
  final _handlers = <IrcSocketRole, bool Function(String channel)>{};
  final _queue = <({String channel, IrcSocketRole role})>[];
  // Recently COMPLETED units. Handshake re-queues arrive for channels that
  // were already fully joined moments ago; without this memory they would
  // spawn fresh units and re-send JOINs for joined channels on every socket
  // bounce. Sweeps bypass the memory via [enqueue]'s force flag.
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

  /// Adds [channel]'s single JOIN (to be sent by [role]'s socket) to the
  /// queue. A channel is joined exactly once, so a second [enqueue] for the
  /// same channel is a no-op - there is no read/write pair to merge.
  ///
  /// Channels that completed recently are ignored unless [force] is set (the
  /// rejoin sweep/retry use force: they exist precisely because a JOIN was
  /// lost and must go out again). Set [force] whenever a NEW socket needs the
  /// join; leave it off for handshake re-queues of live sockets.
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
      // Same channel already queued: it is a single JOIN, nothing to add.
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
    // Always kick the pump: a burst needs the coalesced first pass.
    // Deduplicated, otherwise N enqueues schedule N pumps and the per-pump
    // send cap never engages.
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

  /// Drops one pending unit entirely (e.g. the channel was parted).
  void removeEntry(String channel) {
    _queue.removeWhere((unit) => unit.channel == channel);
    if (_queue.isEmpty) _stop();
  }

  /// Empties the queue entirely; used when the whole session tears down.
  void clear() {
    _queue.clear();
    _stop();
  }

  /// Drops completion memory for one channel (e.g. it was parted, so a
  /// subsequent join must not be suppressed).
  void forget(String channel) {
    _completed.remove(channel);
  }

  /// Drops every pending unit owned by [role]. Used when a socket of a shared
  /// bucket goes away for good; its units must not linger and retry on a dead
  /// socket.
  void dropRole(IrcSocketRole role) {
    _queue.removeWhere((unit) => unit.role == role);
    if (_queue.isEmpty) _stop();
  }

  /// 1-based FIFO position of the pending unit, or null when not queued.
  int? positionOf(String channel) {
    final index = _queue.indexWhere((unit) => unit.channel == channel);
    return index < 0 ? null : index + 1;
  }

  /// Every pending unit with its FIFO position, ordered by send order.
  /// Drives join-progress surfacing (queue countdowns).
  List<({String channel, int position})> pending() {
    return [
      for (var i = 0; i < _queue.length; i++)
        (channel: _queue[i].channel, position: i + 1),
    ];
  }

  /// Seconds until [channel]'s single JOIN has been sent. Counts every
  /// outstanding command up to and including its own (each unit is one JOIN),
  /// and respects BOTH bottlenecks: banked tokens refill at capacity/window,
  /// but the pump can also only push _maxSendsPerPump commands per tick -
  /// ignoring the latter made ETAs collapse to ~0s while the queue was still
  /// seconds away from reaching the channel.
  int etaSecondsForChannel(String channel) {
    final index = _queue.indexWhere((unit) => unit.channel == channel);
    if (index < 0) return 0;
    // Head unit with its command fully banked by tokens: goes out on this
    // pump.
    if (index == 0 && availableTokens >= 1) return 0;
    // Each queued unit ahead of (and including) this one is exactly one JOIN.
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
      // Single JOIN per unit: dispatch to its role's socket. A success
      // consumes one token and completes the unit; a failure (socket down)
      // leaves it queued to retry on the next pump, so a dead socket never
      // strands the channel behind newer ones.
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
          // Keep the slot so it retries in place; step past it so the units
          // behind it still get a chance this pump.
          index++;
        }
      } else {
        // No handler for this role: drop the unit so it cannot starve the
        // queue.
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
