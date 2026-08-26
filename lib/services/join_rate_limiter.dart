import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../util/log.dart';
import 'base_irc_connection.dart' show IrcSocketRole;

export 'base_irc_connection.dart' show IrcSocketRole;

/// Account-wide pacing for IRC JOIN commands.
///
/// A channel occupies exactly ONE queue unit until every participating socket
/// has sent its JOIN: the unit carries a set of roles still pending, each
/// dispatch attempt strips the roles whose send succeeded, and a later
/// [enqueue] for a role merges into the existing unit instead of duplicating
/// it. This makes the read/write pair move together even when the sockets
/// finish their handshakes at different moments - the lagging side completes
/// the units in place rather than re-queuing channels behind newer ones.
///
/// Twitch budgets roughly 20 message commands per 10 seconds per connection;
/// a completed pair costs one command per socket, so [capacity] counts
/// completed units (default 10) over [window] (10.5s). Tokens are consumed
/// per successful send and refill continuously at capacity/window starting
/// from a full bucket, computed lazily on access. Units whose sends all fail
/// (sockets down) stay queued and retry on every pump; the owning
/// connections also re-queue their channels after each handshake.
class JoinRateLimiter {
  JoinRateLimiter({
    this.capacity = 20,
    this.window = const Duration(milliseconds: 10500),
    this.pumpInterval = const Duration(milliseconds: 500),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _lastRefill = _now();
  }

  /// Completed channel-units per [window]; the bucket starts full. Every
  /// successful JOIN send consumes one token regardless of socket, so a
  /// read/write pair costs two - a full bucket covers 10 pairs = the
  /// documented 20 commands per socket per window.
  final int capacity;

  /// Refill window. Slightly longer than Twitch's documented 10s budget so
  /// boundary effects never push a rolling window over the limit.
  final Duration window;

  /// How often the pump wakes while units are queued. Only affects drip
  /// granularity, not throughput.
  final Duration pumpInterval;

  final DateTime Function() _now;

  double _tokens = -1; // resolved to [capacity] on first use (see _refill)
  late DateTime _lastRefill;
  Timer? _pumpTimer;
  final _handlers = <IrcSocketRole, bool Function(String channel)>{};
  final _queue = <({String channel, Set<IrcSocketRole> remaining})>[];

  /// Tokens available right now (fractional), capped at [capacity].
  @visibleForTesting
  double get availableTokens {
    _refill();
    return _tokens;
  }

  void registerHandler(IrcSocketRole role, bool Function(String channel) send) {
    _handlers[role] = send;
  }

  /// Adds [role]'s JOIN for [channel] to the queue, merging into an existing
  /// unit when one is already waiting so the pair shares a slot. New units
  /// start pending on EVERY registered socket: when the write side wins the
  /// handshake race and dispatches early, the unit stays alive holding the
  /// read role until the read socket catches up and merges - instead of
  /// completing immediately and forcing the read join into a fresh,
  /// back-of-queue unit later.
  void enqueue(String channel, IrcSocketRole role) {
    final existing = _queue.indexWhere((unit) => unit.channel == channel);
    if (existing >= 0) {
      final added = _queue[existing].remaining.add(role);
      if (added) {
        PerfLog.I.record(
          'JOINQ',
          'merge $channel $role '
              '(depth=${existing + 1}, left=${_queue[existing].remaining.length})',
        );
      }
    } else {
      final remaining = {..._handlers.keys, role};
      _queue.add((channel: channel, remaining: remaining));
      PerfLog.I.record(
        'JOINQ',
        'enqueue $channel $role '
            '(depth=${_queue.length}, roles=${remaining.map((r) => r.name).join("+")})',
      );
      _start();
    }
    // Always kick the pump: a burst needs the coalesced first pass, and a
    // merge can complete a resident unit whose other roles were waiting.
    Future.microtask(_pump);
  }

  /// Drops one pending unit entirely (e.g. the channel was parted on both
  /// sockets; the second call is a no-op).
  void removeEntry(String channel) {
    _queue.removeWhere((unit) => unit.channel == channel);
    if (_queue.isEmpty) _stop();
  }

  /// Empties the queue entirely; used when the whole session tears down.
  void clear() {
    _queue.clear();
    _stop();
  }

  /// Strips [role] from every pending unit, dropping units left with no
  /// remaining roles. Used when one socket of a shared bucket goes away for
  /// good; its live counterpart's roles keep their slots.
  void dropRole(IrcSocketRole role) {
    _queue.removeWhere((unit) {
      unit.remaining.remove(role);
      return unit.remaining.isEmpty;
    });
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

  /// Seconds until [channel]'s unit would START sending. Counts the actual
  /// outstanding commands ahead of it (a pair-unit costs two), so the ETA is
  /// honest even when every unit carries both roles.
  int etaSecondsForChannel(String channel) {
    final index = _queue.indexWhere((unit) => unit.channel == channel);
    if (index < 0) return 0;
    var commands = 0;
    for (var i = 0; i < index; i++) {
      commands += _queue[i].remaining.length;
    }
    final deficit = commands - availableTokens;
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
    var index = 0;
    while (_tokens >= 1 && walk > 0 && index < _queue.length) {
      final unit = _queue[index];
      walk--;
      // Dispatch to every still-pending role. Successes strip out of the
      // unit's remaining set (consuming a token each); failures stay queued
      // and retry on the next pump, so a lagging socket never forces the
      // channel back behind newer units.
      for (final role in unit.remaining.toList()) {
        final handler = _handlers[role];
        if (handler == null) continue;
        final sent = handler.call(unit.channel);
        if (sent) {
          unit.remaining.remove(role);
          _tokens -= 1;
          PerfLog.I.record(
            'JOINQ',
            'dispatch ${unit.channel} ${role.name}:ok '
                'left=${unit.remaining.length} tokens=${_tokens.toStringAsFixed(2)}',
          );
        } else {
          PerfLog.I.record(
            'JOINQ',
            'dispatch ${unit.channel} ${role.name}:dead (stays queued)',
          );
        }
      }
      final completed = unit.remaining.isEmpty;
      if (completed) _queue.removeAt(index);
      // Only step past the slot when the unit completed; a partially-sent
      // one keeps its slot (its remaining roles retry on later pumps) while
      // still not blocking the units behind it.
      if (!completed) index++;
      if (_tokens < 1) break;
    }
    if (_queue.isEmpty) _stop();
  }
}
