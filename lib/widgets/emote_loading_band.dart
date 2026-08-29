import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Shared clock for loading placeholders. One ticker drives all bands in phase. Starts on first acquire, stops on last release.
class EmoteLoadingClock {
  EmoteLoadingClock._();

  static const Duration _period = Duration(milliseconds: 1200);

  /// Shared sweep position (0..1 wrapping). Values are animation-only.
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

/// Paints the sweep band onto [canvas]. Transparent; no masks or saveLayers.
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

/// Transparent loading placeholder with a shared-clock sweep band.
class LoadingBand extends StatefulWidget {
  const LoadingBand({super.key, this.width, this.height, this.opacity = 1.0});

  final double? width;
  final double? height;

  /// Highlight opacity. Below 1 = subtle hint over existing content.
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
