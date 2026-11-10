import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'design_tokens.dart';
import 'eased_progress.dart';
import 'island_metrics.dart' show kComposerIslandRadius;

// Focus state for the composer island while any inner field holds focus.
// With a [surface], it paints the island's fill: a hair see-through at rest,
// opaque and faintly tinted toward primary when focused, so the state shows
// without a line. Without one, it tints the shell toward primary in its own
// [shape]. Neither shifts layout.
class ComposerFocusGlow extends StatelessWidget {
  const ComposerFocusGlow({
    super.key,
    required this.shape,
    this.surface,
    required this.child,
  });

  final OutlinedBorder shape;
  final Color? surface;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Focus(
      // Observes the inner fields only; never a traversal stop itself.
      skipTraversal: true,
      // Reads focus on build rather than on change, so a field that arrives
      // already focused (the pill hand-off) lights the new shell at once.
      child: Builder(
        builder: (context) {
          final lit = Focus.of(context).hasFocus;
          final fill = surface;
          if (fill != null) {
            return AnimatedContainer(
              duration: Motion.fast,
              curve: Motion.enter,
              decoration: ShapeDecoration(
                shape: shape,
                color: lit
                    ? Color.alphaBlend(primary.withValues(alpha: 0.06), fill)
                    : fill.withValues(alpha: 0.94),
              ),
              child: child,
            );
          }
          return AnimatedContainer(
            duration: Motion.fast,
            curve: Motion.enter,
            foregroundDecoration: ShapeDecoration(
              shape: shape,
              color: primary.withValues(alpha: lit ? 0.12 : 0),
            ),
            child: child,
          );
        },
      ),
    );
  }
}

// Indeterminate progress drawn as a ring along the island's outline. The
// timing is the stock LinearProgressIndicator's (1800ms cycle, two lines,
// same head and tail curves), mapped onto the outline's length clockwise.
// The lines wrap past the start, which drifts a third of a lap per cycle
// so no cycle ends on the same spot. The ticker
// runs only while [busy] holds; the ring fades over 200ms and, with
// animations disabled, shows static at reduced opacity.
class IslandBusyRing extends StatefulWidget {
  const IslandBusyRing({
    super.key,
    required this.listenable,
    required this.busy,
    required this.child,
  });

  final Listenable listenable;
  final bool Function() busy;
  final Widget child;

  @override
  State<IslandBusyRing> createState() => _IslandBusyRingState();
}

class _IslandBusyRingState extends State<IslandBusyRing>
    with TickerProviderStateMixin {
  late final _spin = AnimationController(
    vsync: this,
    duration: _IslandRingPainter.cycle * _IslandRingPainter.cyclesPerLap,
  );
  late final _fade = AnimationController(vsync: this, duration: Motion.normal);

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_sync);
    _fade.addStatusListener((s) {
      if (s == AnimationStatus.dismissed) _spin.stop();
    });
    _sync();
  }

  @override
  void didUpdateWidget(IslandBusyRing old) {
    super.didUpdateWidget(old);
    if (old.listenable != widget.listenable) {
      old.listenable.removeListener(_sync);
      widget.listenable.addListener(_sync);
    }
    _sync();
  }

  void _sync() {
    if (widget.busy()) {
      if (!_spin.isAnimating) _spin.repeat();
      _fade.forward();
    } else {
      _fade.reverse();
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_sync);
    _spin.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) == true;
    if (reduced) {
      _spin.stop();
    } else if (_fade.value > 0 && !_spin.isAnimating) {
      _spin.repeat();
    }
    return CustomPaint(
      foregroundPainter: _IslandRingPainter(
        spin: _spin,
        fade: _fade,
        color: Theme.of(context).colorScheme.primary,
        still: reduced,
      ),
      child: widget.child,
    );
  }
}

class _IslandRingPainter extends CustomPainter {
  _IslandRingPainter({
    required this.spin,
    required this.fade,
    required this.color,
    required this.still,
  }) : super(repaint: Listenable.merge([spin, fade]));

  final Animation<double> spin;
  final Animation<double> fade;
  final Color color;
  final bool still;

  static const _width = 2.5;
  static const cycle = Duration(milliseconds: 1800);

  /// Cycles per lap of the closed outline's drift. [spin] runs one lap, so
  /// it wraps where the drift does.
  static const cyclesPerLap = 3;
  static const line1Head = Interval(
    0.0,
    750.0 / 1800,
    curve: Cubic(0.2, 0.0, 0.8, 1.0),
  );
  static const line1Tail = Interval(
    333.0 / 1800,
    (333.0 + 750.0) / 1800,
    curve: Cubic(0.4, 0.0, 1.0, 1.0),
  );
  static const line2Head = Interval(
    1000.0 / 1800,
    (1000.0 + 567.0) / 1800,
    curve: Cubic(0.0, 0.0, 0.65, 1.0),
  );
  static const line2Tail = Interval(
    1267.0 / 1800,
    (1267.0 + 533.0) / 1800,
    curve: Cubic(0.10, 0.0, 0.45, 1.0),
  );

  static Path outline(Size size) {
    const inset = _width / 2;
    final r = kComposerIslandRadius - inset;
    final l = inset, t = inset, rt = size.width - inset;
    final b = size.height - inset;
    final arc = Radius.circular(r);
    return Path()
      ..moveTo(l + r, t)
      ..lineTo(rt - r, t)
      ..arcToPoint(Offset(rt, t + r), radius: arc)
      ..lineTo(rt, b - r)
      ..arcToPoint(Offset(rt - r, b), radius: arc)
      ..lineTo(l + r, b)
      ..arcToPoint(Offset(l, b - r), radius: arc)
      ..lineTo(l, t + r)
      ..arcToPoint(Offset(l + r, t), radius: arc);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = fade.value;
    if (alpha <= 0 || size.isEmpty) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _width
      ..strokeCap = StrokeCap.butt
      ..color = color.withValues(alpha: still ? alpha * 0.5 : alpha);
    final path = outline(size);
    if (still) {
      canvas.drawPath(path, paint);
      return;
    }
    final lap = spin.value;
    final t = (lap * cyclesPerLap) % 1;
    final drift = lap;
    final metrics = path.computeMetrics().toList();
    final metric = metrics.first;
    final len = metric.length;
    void line(double tail, double head) {
      if (head - tail <= 0) return;
      final from = (tail + drift) % 1;
      final to = from + head - tail;
      canvas.drawPath(metric.extractPath(from * len, to * len), paint);
      if (to > 1) canvas.drawPath(metric.extractPath(0, (to - 1) * len), paint);
    }

    line(line1Tail.transform(t), line1Head.transform(t));
    line(line2Tail.transform(t), line2Head.transform(t));
  }

  @override
  bool shouldRepaint(_IslandRingPainter old) =>
      old.color != color || old.still != still;
}

/// Traces the island's outline as far as [progress] has come, from 0 to 1,
/// in the busy ring's stroke. Shows while [progress] holds a value and fades
/// out full once it clears.
class IslandProgressRing extends StatefulWidget {
  const IslandProgressRing({
    super.key,
    required this.progress,
    required this.child,
  });

  final ValueListenable<double?> progress;
  final Widget child;

  @override
  State<IslandProgressRing> createState() => _IslandProgressRingState();
}

class _IslandProgressRingState extends State<IslandProgressRing>
    with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(vsync: this, duration: Motion.normal);

  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(IslandProgressRing old) {
    super.didUpdateWidget(old);
    if (old.progress != widget.progress) {
      old.progress.removeListener(_sync);
      widget.progress.addListener(_sync);
    }
    _sync();
  }

  void _sync() {
    if (widget.progress.value != null) {
      _fade.forward();
    } else {
      _fade.reverse();
    }
  }

  @override
  void dispose() {
    widget.progress.removeListener(_sync);
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => EasedProgress(
    progress: widget.progress,
    builder: (context, share, _) => CustomPaint(
      foregroundPainter: _IslandProgressPainter(
        share: share,
        fade: _fade,
        color: Theme.of(context).colorScheme.primary,
      ),
      child: widget.child,
    ),
  );
}

class _IslandProgressPainter extends CustomPainter {
  _IslandProgressPainter({
    required this.share,
    required this.fade,
    required this.color,
  }) : super(repaint: fade);

  /// How far round the outline to draw, from 0 to 1.
  final double share;
  final Animation<double> fade;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = fade.value;
    if (alpha <= 0 || size.isEmpty) return;
    final metrics = _IslandRingPainter.outline(size).computeMetrics().toList();
    final metric = metrics.first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * share.clamp(0.0, 1.0)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _IslandRingPainter._width
        ..color = color.withValues(alpha: alpha),
    );
  }

  @override
  bool shouldRepaint(_IslandProgressPainter old) =>
      old.color != color || old.share != share;
}
