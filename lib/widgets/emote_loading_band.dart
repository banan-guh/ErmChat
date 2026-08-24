import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Shared playback clock for every visible loading placeholder.
///
/// One [Ticker] drives a single 0..1 [phase] notifier; all placeholders read
/// it, so their bands sweep in phase and the app wakes at most once per frame
/// total instead of once per placeholder controller (the cost model that made
/// per-instance shimmers expensive under emote spam). The ticker starts when
/// the first placeholder mounts ([acquire]) and stops when the last unmounts
/// ([release]), so nothing schedules frames while no placeholder is visible.
class EmoteLoadingClock {
  EmoteLoadingClock._();

  static const Duration _period = Duration(milliseconds: 1200);

  /// Sweep position shared by every visible placeholder, monotonically
  /// wrapping 0..1. Listeners repaint via CustomPainter(repaint:) or direct
  /// render-object subscriptions; values carry no meaning beyond animation.
  static final ValueNotifier<double> phase = ValueNotifier<double>(0);

  static Ticker? _ticker;
  static int _users = 0;

  /// Registers a placeholder consumer, starting the shared clock on demand.
  static void acquire() {
    _users++;
    if (_ticker != null) return;
    _ticker = Ticker(_onTick)..start();
  }

  /// Drops a placeholder consumer, stopping the shared clock at zero users.
  static void release() {
    if (_users > 0) _users--;
    if (_users == 0 && _ticker != null) {
      _ticker!.stop();
      _ticker!.dispose();
      _ticker = null;
    }
  }

  /// True while at least one placeholder consumer is registered.
  @visibleForTesting
  static bool get isActive => _ticker != null;

  static void _onTick(Duration elapsed) {
    phase.value =
        (elapsed.inMicroseconds % _period.inMicroseconds) /
        _period.inMicroseconds;
  }
}

/// Paints the moving highlight band of a loading placeholder onto [canvas].
///
/// Only the band itself is painted: everything else stays untouched, which
/// keeps the placeholder see-through (zero-width overlays load on top of base
/// emotes and must never occlude them). No masks and no saveLayers are
/// involved, unlike the ShaderMask-based shimmer this replaces.
///
/// [phase] is the shared sweep position from [EmoteLoadingClock.phase].
void paintLoadingBand(Canvas canvas, Size size, Color highlight, double phase) {
  if (size.isEmpty) return;
  final bandWidth = math.max(size.width * 0.8, 24.0);
  final travel = size.width + bandWidth;
  final center = -bandWidth / 2 + travel * phase;
  // Oversized vertically so the band covers the box for the whole sweep.
  final rect = Rect.fromLTWH(
    center - bandWidth / 2,
    -size.height,
    bandWidth,
    size.height * 3,
  );
  final paint = Paint()
    ..shader = LinearGradient(
      colors: [highlight.withValues(alpha: 0), highlight],
      stops: const [0, 1],
    ).createShader(rect);
  canvas
    ..save()
    ..clipRect(Offset.zero & size)
    ..drawRect(rect, paint)
    ..restore();
}

/// Loading placeholder for emotes: a faint band sweeping in phase across an
/// otherwise fully transparent box.
///
/// Transparency is load-bearing: zero-width overlays render stacked on top of
/// base emotes while loading, so an opaque box would hide the emote under it.
class LoadingBand extends StatefulWidget {
  const LoadingBand({super.key, this.width, this.height, this.opacity = 1.0});

  final double? width;
  final double? height;

  /// Opacity applied to the highlight color. Below 1 the band reads as a hint
  /// over content that is already showing (e.g. a cached smaller scale).
  final double opacity;

  @override
  State<LoadingBand> createState() => _LoadingBandState();
}

class _LoadingBandState extends State<LoadingBand> {
  @override
  void initState() {
    super.initState();
    EmoteLoadingClock.acquire();
  }

  @override
  void dispose() {
    EmoteLoadingClock.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final highlight = scheme.surfaceContainerHighest.withValues(
      alpha: widget.opacity,
    );
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: CustomPaint(painter: _LoadingBandPainter(highlight)),
    );
  }
}

class _LoadingBandPainter extends CustomPainter {
  _LoadingBandPainter(this.highlight) : super(repaint: EmoteLoadingClock.phase);

  final Color highlight;

  @override
  void paint(Canvas canvas, Size size) =>
      paintLoadingBand(canvas, size, highlight, EmoteLoadingClock.phase.value);

  @override
  bool shouldRepaint(_LoadingBandPainter oldDelegate) => false;
}
