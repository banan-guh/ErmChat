import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../color_utils.dart' show streamAccent;
import '../l10n/l10n.dart';
import '../util/history_timeline.dart';

/// Time rail for the history list: a grab handle on an activity-weighted
/// track, with a bubble and day labels while dragging. Dragging left of the
/// rail slows the thumb for fine seeking. It only reports positions; the list
/// owner moves [thumb] while the list scrolls and performs the jump on
/// release.
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

  /// Height of the edge band around the thumb kept from Android's back
  /// gesture; Android honors up to 200dp per edge.
  static const double _band = 160;

  /// Each step this far left of the track halves the thumb's speed.
  static const double _slowStep = 64;

  static const _device = MethodChannel('ermchat/device');

  /// The rail whose band is excluded; only it may clear the exclusion.
  static _HistoryScrubberState? _excluding;

  final ValueNotifier<bool> _dragging = ValueNotifier(false);

  /// Thumb speed while dragging: 1, then 1/2, 1/4 and 1/8 further left.
  final ValueNotifier<double> _speed = ValueNotifier(1);
  double? _sentCenter;
  double _dpr = 1;

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
  DateFormat? _dayLabel;
  String? _locale;

  @override
  void initState() {
    super.initState();
    _dragging.addListener(_syncActive);
    widget.peek.addListener(_syncActive);
    widget.visible.addListener(_syncExclusion);
    widget.thumb.addListener(_syncExclusion);
    if (widget.peek.value) _active.value = 1;
  }

  @override
  void didUpdateWidget(HistoryScrubber old) {
    super.didUpdateWidget(old);
    if (old.peek != widget.peek) {
      old.peek.removeListener(_syncActive);
      widget.peek.addListener(_syncActive);
    }
    if (old.visible != widget.visible) {
      old.visible.removeListener(_syncExclusion);
      widget.visible.addListener(_syncExclusion);
    }
    if (old.thumb != widget.thumb) {
      old.thumb.removeListener(_syncExclusion);
      widget.thumb.addListener(_syncExclusion);
    }
  }

  @override
  void dispose() {
    widget.peek.removeListener(_syncActive);
    widget.visible.removeListener(_syncExclusion);
    widget.thumb.removeListener(_syncExclusion);
    _clearExclusion();
    _dragging.dispose();
    _speed.dispose();
    _active.dispose();
    super.dispose();
  }

  /// Keeps Android's back gesture off the band around the thumb while the
  /// rail shows, so a grab at the screen edge scrubs. Elsewhere on the edge
  /// back works as usual.
  void _syncExclusion() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final box = mounted ? context.findRenderObject() : null;
    if (!widget.visible.value ||
        box is! RenderBox ||
        !box.hasSize ||
        box.size.height < _minHeight) {
      _clearExclusion();
      return;
    }
    final center = widget.thumb.value * box.size.height;
    final sent = _sentCenter;
    if (identical(_excluding, this) &&
        sent != null &&
        (center - sent).abs() < 24) {
      return;
    }
    _sentCenter = center;
    _excluding = this;
    final o = box.localToGlobal(Offset.zero);
    final r = Rect.fromLTWH(
      o.dx,
      o.dy + center - _band / 2,
      box.size.width,
      _band,
    );
    _send([
      for (final v in [r.left, r.top, r.right, r.bottom]) (v * _dpr).round(),
    ]);
  }

  void _clearExclusion() {
    if (!identical(_excluding, this)) return;
    _excluding = null;
    _sentCenter = null;
    _send(null);
  }

  static void _send(List<int>? rect) => unawaited(
    _device
        .invokeMethod<void>('setGestureExclusion', {'rect': rect})
        .catchError((Object _) {}),
  );

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
    _speed.value = 1;
    widget.onDragStart();
    _move(_pos(d.localPosition));
  }

  /// Moves by the finger's travel, scaled down the further left of the
  /// track the finger is.
  void _update(DragUpdateDetails d) {
    final away = (_width - _inset) - d.localPosition.dx;
    final steps = (away / _slowStep).floor().clamp(0, 3);
    final speed = 1 / (1 << steps);
    if (speed != _speed.value) {
      HapticFeedback.selectionClick();
      _speed.value = speed;
    }
    _move((widget.thumb.value + d.delta.dy / _height * speed).clamp(0.0, 1.0));
  }

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
    _speed.value = 1;
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
      _dayLabel = DateFormat('MMM d', locale);
    }
    _dpr = MediaQuery.devicePixelRatioOf(context);
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
                        glyph: scheme.onPrimary,
                        stream: streamAccent,
                        shadow: scheme.shadow,
                      ),
                    ),
                  ),
                  ListenableBuilder(
                    listenable: Listenable.merge([
                      widget.thumb,
                      _active,
                      _speed,
                    ]),
                    builder: (context, _) => Positioned.fill(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          _dayLabels(context, scheme),
                          _bubble(context, scheme),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Day starts beside the track while dragging, thinned so none overlap
  /// each other or the bubble.
  Widget _dayLabels(BuildContext context, ColorScheme scheme) {
    final t = _activeCurve.value;
    if (t == 0 || !_dragging.value) return const SizedBox.shrink();
    final thumbY = widget.thumb.value * _height;
    final style = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    final labels = <Widget>[];
    var last = double.negativeInfinity;
    for (final d in widget.rail.days) {
      final y = d.pos * _height;
      if (y - last < 22 || (y - thumbY).abs() < 40) continue;
      last = y;
      labels.add(
        Positioned(
          top: y - 9,
          right: _width - _inset + 10,
          height: 18,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Center(
                widthFactor: 1,
                child: Text(
                  _dayLabel!.format(dayFromNumber(d.day)),
                  style: style,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Positioned.fill(
      child: IgnorePointer(
        child: Opacity(
          opacity: t,
          child: Stack(clipBehavior: Clip.none, children: labels),
        ),
      ),
    );
  }

  /// Date and time, plus the stream title when one was live and the scrub
  /// speed when slowed, pinned to the left of the thumb.
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
                        if (_speed.value < 1)
                          Text(
                            switch (_speed.value) {
                              0.5 => context.l10n.historyScrubHalf,
                              0.25 => context.l10n.historyScrubQuarter,
                              _ => context.l10n.historyScrubFine,
                            },
                            style: text.bodySmall?.copyWith(
                              color: scheme.primary,
                            ),
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
/// stretches with nothing recorded, stream spans in [stream], and a grab
/// handle in [accent] with up and down chevrons in [glyph]. [active] widens
/// all of it while the rail is in use.
class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.rail,
    required this.thumb,
    required this.active,
    required this.inset,
    required this.track,
    required this.accent,
    required this.glyph,
    required this.stream,
    required this.shadow,
  }) : super(repaint: Listenable.merge([thumb, active]));

  final ActivityRail rail;
  final ValueNotifier<double> thumb;
  final Animation<double> active;
  final double inset;
  final Color track;
  final Color accent;
  final Color glyph;
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

    final tw = ui.lerpDouble(20, 26, t)!;
    final th = ui.lerpDouble(44, 52, t)!;
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
    final chevron = Paint()
      ..color = glyph
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final dir in const [-1.0, 1.0]) {
      canvas.drawPath(
        Path()
          ..moveTo(x - 4, cy + dir * 5)
          ..lineTo(x, cy + dir * 9)
          ..lineTo(x + 4, cy + dir * 5),
        chevron,
      );
    }
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.rail != rail ||
      old.active != active ||
      old.inset != inset ||
      old.track != track ||
      old.accent != accent ||
      old.glyph != glyph ||
      old.stream != stream ||
      old.shadow != shadow;
}
