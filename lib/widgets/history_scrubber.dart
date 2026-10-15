import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../color_utils.dart' show streamAccent;
import '../l10n/l10n.dart';
import '../util/history_timeline.dart';

/// Time rail for the history list: a thumb on an activity-weighted track with
/// a bubble while dragging. It only reports positions; the list owner moves
/// [thumb] while the list scrolls and performs the jump on release.
///
/// Visibility, thumb and bubble are driven by notifiers, so showing, hiding
/// and following the list never rebuild the list itself.
class HistoryScrubber extends StatefulWidget {
  const HistoryScrubber({
    super.key,
    required this.rail,
    required this.thumb,
    required this.visible,
    required this.peek,
    required this.onDragStart,
    required this.onDrag,
    required this.onDragEnd,
  });

  final ActivityRail rail;

  /// Rail position of the thumb, 0 (oldest) at the top to 1 (newest).
  final ValueNotifier<double> thumb;
  final ValueListenable<bool> visible;

  /// Shows the bubble without a drag, e.g. after tapping a day marker.
  final ValueListenable<bool> peek;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDrag;
  final ValueChanged<double> onDragEnd;

  @override
  State<HistoryScrubber> createState() => _HistoryScrubberState();
}

class _HistoryScrubberState extends State<HistoryScrubber>
    with SingleTickerProviderStateMixin {
  static const double _width = 40;

  /// Shorter than this (stream and keyboard up), the rail cannot pick a
  /// stretch, so it hides.
  static const double _minHeight = 160;

  /// Rail center, in from the right edge.
  static const double _inset = 12;
  static const Duration _fade = Duration(milliseconds: 200);

  final ValueNotifier<bool> _dragging = ValueNotifier(false);

  /// 0 at rest, 1 while dragging or peeking: grows the rail and shows the
  /// bubble.
  late final AnimationController _active = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
    reverseDuration: const Duration(milliseconds: 240),
  );
  late final Animation<double> _activeCurve = CurvedAnimation(
    parent: _active,
    curve: Curves.easeOutCubic,
  );
  double _height = 1;
  DateFormat? _day;
  DateFormat? _time;
  String? _locale;

  @override
  void initState() {
    super.initState();
    _dragging.addListener(_syncActive);
    widget.peek.addListener(_syncActive);
    if (widget.peek.value) _active.value = 1;
  }

  @override
  void didUpdateWidget(HistoryScrubber old) {
    super.didUpdateWidget(old);
    if (old.peek != widget.peek) {
      old.peek.removeListener(_syncActive);
      widget.peek.addListener(_syncActive);
    }
  }

  @override
  void dispose() {
    widget.peek.removeListener(_syncActive);
    _dragging.dispose();
    _active.dispose();
    super.dispose();
  }

  void _syncActive() {
    if (_dragging.value || widget.peek.value) {
      _active.forward();
    } else {
      _active.reverse();
    }
  }

  double _pos(Offset local) => (local.dy / _height).clamp(0.0, 1.0);

  void _start(DragStartDetails d) {
    _dragging.value = true;
    widget.onDragStart();
    _move(_pos(d.localPosition));
  }

  void _update(DragUpdateDetails d) => _move(_pos(d.localPosition));

  void _move(double pos) {
    final prev = widget.thumb.value;
    final tick = widget.rail.crossed(prev, pos);
    if (tick == 2) {
      HapticFeedback.mediumImpact();
    } else if (tick == 1) {
      HapticFeedback.selectionClick();
    }
    widget.thumb.value = pos;
    widget.onDrag(pos);
  }

  void _end([DragEndDetails? _]) {
    _dragging.value = false;
    widget.onDragEnd(widget.thumb.value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final locale = Localizations.localeOf(context).toString();
    if (_locale != locale) {
      _locale = locale;
      _day = DateFormat('EEE MMM d', locale);
      _time = DateFormat.Hm(locale);
    }
    return ValueListenableBuilder<bool>(
      valueListenable: widget.visible,
      builder: (context, visible, child) => IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: _fade,
          child: child,
        ),
      ),
      child: SizedBox(
        width: _width,
        child: LayoutBuilder(
          builder: (context, box) {
            if (box.maxHeight < _minHeight) return const SizedBox.shrink();
            _height = box.maxHeight;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: _start,
              onVerticalDragUpdate: _update,
              onVerticalDragEnd: _end,
              onVerticalDragCancel: _end,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _RailPainter(
                        rail: widget.rail,
                        thumb: widget.thumb,
                        active: _activeCurve,
                        inset: _inset,
                        track: scheme.onSurface,
                        accent: scheme.primary,
                        stream: streamAccent,
                        shadow: scheme.shadow,
                      ),
                    ),
                  ),
                  ListenableBuilder(
                    listenable: Listenable.merge([widget.thumb, _active]),
                    builder: (context, _) => _bubble(context, scheme),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Date and time, plus the stream title when one was live, pinned to the
  /// left of the thumb.
  Widget _bubble(BuildContext context, ColorScheme scheme) {
    final t = _activeCurve.value;
    if (t == 0) return const SizedBox.shrink();
    final pos = widget.thumb.value;
    final at = widget.rail.timeAt(pos).toLocal();
    final stream = widget.rail.streamAt(at);
    final text = Theme.of(context).textTheme;
    const height = 56.0;
    return Positioned(
      top: (pos * _height - height / 2).clamp(-8.0, _height - height + 8),
      right: _width - _inset + 14,
      height: height,
      child: IgnorePointer(
        child: Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(12 * (1 - t), 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.shadow.withValues(alpha: 0.35),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          context.l10n.historyScrubberBubble(
                            _day!.format(at),
                            _time!.format(at),
                          ),
                          maxLines: 1,
                          softWrap: false,
                          style: text.labelLarge?.copyWith(
                            color: scheme.onSurface,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        if (stream != null)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(
                                  color: streamAccent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  stream.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the rail: a slim rounded track that breaks into dots over
/// stretches with nothing recorded, stream spans in [stream], and a pill
/// thumb in [accent]. [active] widens all of it while the rail is in use.
class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.rail,
    required this.thumb,
    required this.active,
    required this.inset,
    required this.track,
    required this.accent,
    required this.stream,
    required this.shadow,
  }) : super(repaint: Listenable.merge([thumb, active]));

  final ActivityRail rail;
  final ValueNotifier<double> thumb;
  final Animation<double> active;
  final double inset;
  final Color track;
  final Color accent;
  final Color stream;
  final Color shadow;

  static const double _dotStep = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final t = active.value;
    final x = size.width - inset;
    final h = size.height;
    final w = ui.lerpDouble(3, 5, t)!;
    final base = Paint()
      ..color = track.withValues(alpha: ui.lerpDouble(0.16, 0.24, t)!);
    final live = Paint()
      ..color = stream.withValues(alpha: ui.lerpDouble(0.75, 1, t)!);

    void bar(double a, double b, Paint p) {
      final top = a * h;
      final bottom = b * h;
      if (bottom - top < 0.5) return;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(x - w / 2, top, x + w / 2, bottom),
          Radius.circular(w / 2),
        ),
        p,
      );
    }

    // Track segments between gaps; each gap is a dotted run.
    var cursor = 0.0;
    for (final g in rail.gaps) {
      if (g.start > cursor) bar(cursor, g.start, base);
      final top = g.start * h + _dotStep / 2;
      for (var y = top; y < g.end * h - _dotStep / 4; y += _dotStep) {
        canvas.drawCircle(Offset(x, y), w * 0.32, base);
      }
      cursor = g.end;
    }
    if (cursor < 1) bar(cursor, 1, base);
    for (final s in rail.streamSpans) {
      bar(s.start, s.end, live);
    }

    final tw = ui.lerpDouble(6, 10, t)!;
    final th = ui.lerpDouble(36, 48, t)!;
    final cy = (thumb.value * h).clamp(th / 2, h - th / 2);
    final thumbRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(x, cy), width: tw, height: th),
      Radius.circular(tw / 2),
    );
    if (t > 0) {
      canvas.drawShadow(
        Path()..addRRect(thumbRect),
        shadow.withValues(alpha: t),
        3,
        false,
      );
    }
    canvas.drawRRect(thumbRect, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.rail != rail ||
      old.active != active ||
      old.inset != inset ||
      old.track != track ||
      old.accent != accent ||
      old.stream != stream ||
      old.shadow != shadow;
}
