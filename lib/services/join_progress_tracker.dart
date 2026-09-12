import 'dart:async';

import '../util/log.dart';
import '../irc/join_rate_limiter.dart';

/// Per-channel join-queue progress: the channel's position in the shared
/// JOIN FIFO and an estimated seconds-to-send. Null info means the wait is
/// over (confirmed, sent, or dropped) and any countdown line should go.
class JoinProgress {
  const JoinProgress(this.position, this.etaSeconds);
  final int position;
  final int etaSeconds;
}

/// Emits per-channel JOIN-queue progress once per second while a join waits
/// in the shared budget. Reads chat state through injected predicates.
class JoinProgressTracker {
  JoinProgressTracker({
    required this.joinBudget,
    required this.channelNames,
    required this.isReady,
    required this.isFailed,
    required this.onProgress,
  });

  final JoinRateLimiter? joinBudget;
  final List<String> Function() channelNames;
  final bool Function(String channel) isReady;
  final bool Function(String channel) isFailed;
  final void Function(String channel, JoinProgress? info) onProgress;

  // Channels currently showing a join-countdown line; drives the clear emit
  // when the wait ends or the socket drops.
  final _joinWaitShown = <String>{};
  // Last countdown values shown per channel, so the displayed position never
  // regresses when the rejoin sweep re-queues an in-flight channel.
  final _lastJoinProgress = <String, JoinProgress>{};
  Timer? _timer;
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _joinWaitShown.clear();
    _lastJoinProgress.clear();
  }

  /// Retires [channel]'s countdown line (if shown) via a null progress emit,
  /// so the UI removes the row.
  void clearWait(String channel) {
    _lastJoinProgress.remove(channel);
    if (!_joinWaitShown.remove(channel)) return;
    onProgress(channel, null);
  }

  /// Clears every channel currently showing a countdown line.
  void clearAllWaits() {
    for (final channel in List.of(_joinWaitShown)) {
      clearWait(channel);
    }
  }

  /// Starts the one-second progress ticker. It idles cheaply when nothing is
  /// queued; mid-session channel joins must surface too, so it never stops
  /// until [dispose].
  void ensureTicker() {
    if (_timer != null || joinBudget == null || _disposed) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    // First snapshot immediately so a cold start shows positions at once.
    _tick();
  }

  /// Emits progress once: position plus an ETA derived from the bucket's
  /// refill rate. Channels that left the queue but have not confirmed on
  /// every live socket yet keep or drop their countdown accordingly.
  void _tick() {
    final budget = joinBudget;
    if (budget == null || _disposed) return;
    for (final channel in channelNames()) {
      if (isFailed(channel)) continue;
      if (isReady(channel)) {
        clearWait(channel);
        continue;
      }
      final position = budget.positionOf(channel);
      if (position != null && position > 0) {
        // Monotonic clamp: a rejoin sweep can re-queue an in-flight channel
        // behind newer joins, which would make the countdown jump back up.
        // Once shown, the numbers only move down until the channel is ready.
        final last = _lastJoinProgress[channel];
        final shown = (last != null && last.position < position)
            ? last.position
            : position;
        if (last != null && shown < position) {
          PerfLog.I.record(
            'JOINQ',
            'wait $channel clamped pos=$position -> $shown',
          );
        }
        final rawEta = budget.etaSecondsForChannel(channel);
        final eta = (last != null && last.etaSeconds < rawEta)
            ? last.etaSeconds
            : rawEta;
        final numbersDone = position <= 1 && eta <= 0;
        if (numbersDone) {
          // Head-of-queue with banked tokens: dispatches this instant, and
          // "position 1 · ~0s" would just repeat every tick. Degrade to the
          // numberless marker until the echo lands.
          _lastJoinProgress.remove(channel);
          _emitPlainJoining(channel);
          continue;
        }
        final progress = JoinProgress(shown, eta);
        _lastJoinProgress[channel] = progress;
        _joinWaitShown.add(channel);
        onProgress(channel, progress);
      } else {
        // Unit fully sent (or imminent): no honest numbers exist anymore.
        // Keep a numberless marker so the channel still reads as joining
        // until its "Connected" lands.
        _emitPlainJoining(channel);
      }
    }
  }

  /// Emits the numberless "still joining" state for [channel].
  void _emitPlainJoining(String channel) {
    _joinWaitShown.add(channel);
    onProgress(channel, const JoinProgress(0, 0));
  }
}
