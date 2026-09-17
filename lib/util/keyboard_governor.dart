import 'dart:async';
import 'dart:math';

/// Cleans the engine keyboard signal before the Scaffold consumes it.
///
/// On Android edge-to-edge the engine over-reports viewInsets.bottom for a
/// frame at the end of the IME open animation, then snaps down to the true
/// height (upstream flutter#168768/#190974 family). A cancelled close also
/// leaks a single zero frame mid-reopen. Both reach the Scaffold resize
/// directly, so the composer jumps above the keyboard and snaps back.
///
/// The open side is capped at the learned height. The close side reports
/// raw untouched while falling, which preserves the raw-plus-padding sum
/// the composer top rests on; only a zero arriving mid-rise (the phantom
/// signature) is held back. The rule is pure except for its timers, so it
/// stays unit-testable under FakeAsync.
class KeyboardInsetGovernor {
  KeyboardInsetGovernor({
    double settled = 0,
    this.slack = 1.0,
    this.closeAfter = const Duration(milliseconds: 48),
    this.settleAfter = const Duration(milliseconds: 120),
    this.onSettled,
    this.onChanged,
  }) : settled = settled,
       _lastSaved = settled;

  /// Learned open height in dp. Zero means unknown: consume passes raw
  /// through until the first stable open teaches it. The host seeds this
  /// from persistence and this relearns live for taller keyboards.
  double settled;

  /// Headroom above [settled] that still passes. Covers the observed
  /// settled jitter (a few tenths of a dp) without letting the
  /// end-of-animation overshoot through in any visible amount.
  final double slack;

  /// Delay before reporting a held phantom zero when nothing follows it.
  /// Only a zero arriving mid-rise is ever held; a real close lands on its
  /// own ticks. A reopen arriving first cancels this.
  final Duration closeAfter;

  /// Stillness window before adopting a new height. Mirrors ChatBody.
  final Duration settleAfter;

  /// Fired when a new height is adopted, so the host can persist it.
  final void Function(double value)? onSettled;

  /// Fired when the debounced close lands, so the host rebuilds. No build
  /// follows a settled signal on its own.
  final void Function()? onChanged;

  double _lastRaw = 0;
  double _reported = 0;
  bool _rising = false;
  double _lastSaved;
  Timer? _settleTimer;
  Timer? _closeTimer;

  /// Maps a true raw inset to the value the Scaffold may consume. Feeds
  /// true raw only; learning needs the unclamped signal to converge.
  double consume(double raw) {
    if ((raw - _lastRaw).abs() >= 0.5) {
      final rising = raw > _lastRaw;
      _lastRaw = raw;
      if (raw > 0.5) {
        _rising = rising;
        _closeTimer?.cancel();
        _closeTimer = null;
        _settleTimer?.cancel();
        _settleTimer = Timer(settleAfter, () {
          final stable = _lastRaw;
          if (stable <= 50 || stable >= 1500) return;
          settled = stable;
          if ((stable - _lastSaved).abs() < 10) return;
          _lastSaved = stable;
          onSettled?.call(stable);
        });
        final v = settled > 0 ? min(raw, settled + slack) : raw;
        _reported = v;
      } else if (_rising) {
        // Zero amid a rise is the phantom: hold the last open value. The
        // timer reports it if the signal truly went quiet; a reopen
        // cancels first and the zero never shows.
        _settleTimer?.cancel();
        _closeTimer ??= Timer(closeAfter, () {
          _closeTimer = null;
          _rising = false;
          _reported = 0.0;
          onChanged?.call();
        });
      } else {
        // Falling or steady close: pass raw through untouched, so the
        // raw-plus-padding sum the composer top rests on never breaks.
        _settleTimer?.cancel();
        _reported = raw;
      }
      return _reported;
    }
    if (raw <= 0.5 && _reported > 0.5 && !_rising) {
      // Drifted shut without a distinct tick: follow it so nothing sticks
      // slightly open. Skipped while rising, so a stray rebuild inside the
      // phantom window keeps holding instead of flashing closed.
      _reported = raw;
    }
    return _reported;
  }

  void dispose() {
    _settleTimer?.cancel();
    _closeTimer?.cancel();
  }
}
