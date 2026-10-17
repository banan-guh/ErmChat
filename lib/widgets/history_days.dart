import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../util/history_timeline.dart';
import 'glass_chrome.dart';

/// The days of a history list, opened from the menu's calendar: a column
/// that slides in from the right edge, one row per day, oldest at the top
/// and stacked from the bottom. A tapped day grows to fill the column as a
/// bar over that day's time; a touch on it picks a time, and letting go
/// jumps there.
class HistoryDays extends StatefulWidget {
  const HistoryDays({
    super.key,
    required this.rail,
    required this.open,
    required this.viewTime,
    required this.onPick,
    this.glass = false,
  });

  final ActivityRail rail;

  /// Whether the days are out; the owner dims the list under them and
  /// closes them on a tap there.
  final ValueNotifier<bool> open;

  /// The list's time, whose day is highlighted.
  final DateTime? Function() viewTime;

  /// A picked time.
  final ValueChanged<DateTime> onPick;

  /// Liquid glass surface instead of an opaque one.
  final bool glass;

  /// Whether [rail] has days to pick from.
  static bool hasDays(ActivityRail rail) =>
      rail.calendar && rail.days.isNotEmpty;

  @override
  State<HistoryDays> createState() => _HistoryDaysState();
}

/// Claims a touch on the open day at once, so a diagonal drag picks a time
/// instead of paging channels.
class _EagerPan extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _HistoryDaysState extends State<HistoryDays>
    with TickerProviderStateMixin {
  /// Day row size, at most.
  static const double _row = 44;
  static const double _maxDay = 40;

  /// Space around the rows inside the surface.
  static const double _pad = 6;
  static const double _width = _row + _pad * 2;
  static const double _radius = 20;
  static const Duration _duration = Duration(milliseconds: 200);

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: _duration,
    value: widget.open.value ? 1 : 0,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _anim,
    curve: Curves.easeOutCubic,
  );

  /// 0 with the days listed, 1 with [_picked] filling the column.
  late final AnimationController _expand = AnimationController(
    vsync: this,
    duration: _duration,
  );
  late final Animation<double> _expandCurve = CurvedAnimation(
    parent: _expand,
    curve: Curves.easeOutCubic,
  );

  DateFormat? _dayLabel;
  DateFormat? _time;
  String? _locale;

  /// The list's day when the days opened, highlighted.
  int? _current;

  /// The open day's index and its bar's scale, weighted by activity so busy
  /// stretches get room and quiet ones shrink.
  int? _picked;
  RailScale? _scale;

  /// The touch on the open day's bar, as a bar position 0..1.
  final ValueNotifier<double?> _touch = ValueNotifier(null);
  int _lastHour = -1;
  double _barH = 1;

  @override
  void initState() {
    super.initState();
    widget.open.addListener(_sync);
  }

  @override
  void didUpdateWidget(HistoryDays old) {
    super.didUpdateWidget(old);
    if (old.open != widget.open) {
      old.open.removeListener(_sync);
      widget.open.addListener(_sync);
      _sync();
    }
    if (old.rail != widget.rail) _reset();
  }

  @override
  void dispose() {
    widget.open.removeListener(_sync);
    _anim.dispose();
    _expand.dispose();
    _touch.dispose();
    super.dispose();
  }

  void _sync() {
    if (widget.open.value) {
      // Read on open, outside layout: the list's rows are laid out by then.
      final view = widget.viewTime();
      setState(() {
        _reset();
        _current = view == null ? null : dayNumber(widget.rail.local(view));
      });
      _anim.forward();
    } else {
      _anim.reverse();
    }
  }

  void _reset() {
    _picked = null;
    _scale = null;
    _expand.value = 0;
    _touch.value = null;
  }

  /// Where [i]'s day ends: the next day's start, or the rail's end.
  DateTime _endOf(int i) {
    final days = widget.rail.days;
    return i + 1 < days.length ? days[i + 1].start : widget.rail.to;
  }

  void _open(int i) {
    HapticFeedback.selectionClick();
    setState(() {
      _picked = i;
      _scale = widget.rail.window(widget.rail.days[i].start, _endOf(i));
    });
    _expand.forward();
  }

  void _onTouch(double y) {
    final p = ((y - _pad) / _barH).clamp(0.0, 1.0);
    _touch.value = p;
    final hour = widget.rail.local(_scale!.timeAt(p)).hour;
    if (_lastHour >= 0 && hour != _lastHour) HapticFeedback.selectionClick();
    _lastHour = hour;
  }

  void _release() {
    final p = _touch.value;
    final scale = _scale;
    _lastHour = -1;
    if (p == null || scale == null) return;
    widget.open.value = false;
    widget.onPick(scale.timeAt(p));
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    if (_locale != locale) {
      _locale = locale;
      _dayLabel = DateFormat('MMM d', locale);
      _time = DateFormat.Hm(locale);
    }
    return AnimatedBuilder(
      animation: _curve,
      builder: (context, child) {
        final o = _curve.value;
        if (o == 0) return const SizedBox.shrink();
        return Transform.translate(
          offset: Offset((_width + _radius) * (1 - o), 0),
          child: child,
        );
      },
      child: SizedBox(
        width: _width,
        child: LayoutBuilder(
          builder: (context, box) => AnimatedBuilder(
            animation: _expandCurve,
            builder: (context, _) => _panel(box.maxHeight),
          ),
        ),
      ),
    );
  }

  Widget _panel(double height) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall;
    final days = widget.rail.days;
    final n = days.length;
    final dayH = math.min((height - _pad * 2) / math.max(1, n), _maxDay);
    if (dayH <= 0) return const SizedBox.shrink();
    final gap = math.min(3.0, dayH * 0.2);
    final t = _expandCurve.value;
    _barH = math.max(1, height - _pad * 2);
    final picked = _picked;
    final rows = <Widget>[];
    for (var i = 0; i < n; i++) {
      final top = height - _pad - (n - i) * dayH + gap / 2;
      final h = dayH - gap;
      if (i == picked) {
        rows.add(
          Positioned(
            left: _pad,
            right: _pad,
            top: lerpDouble(top, _pad, t),
            height: lerpDouble(h, _barH, t),
            child: _openDay(i, h, t, style),
          ),
        );
      } else if (t < 1) {
        rows.add(
          Positioned(
            left: _pad,
            right: _pad,
            top: top,
            height: h,
            child: Opacity(
              opacity: 1 - t,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: picked == null ? () => _open(i) : null,
                child: _day(days, i, h, style),
              ),
            ),
          ),
        );
      }
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: lerpDouble(n * dayH + _pad * 2, height, t),
          child: _surface(scheme),
        ),
        ...rows,
        if (picked != null)
          // The pointer drives the pick, so a still tap picks too; the pan
          // only claims the touch.
          Positioned.fill(
            child: Listener(
              onPointerDown: (e) => _onTouch(e.localPosition.dy),
              onPointerMove: (e) => _onTouch(e.localPosition.dy),
              onPointerUp: (_) => _release(),
              onPointerCancel: (_) => _touch.value = null,
              child: RawGestureDetector(
                behavior: HitTestBehavior.opaque,
                gestures: {
                  _EagerPan: GestureRecognizerFactoryWithHandlers<_EagerPan>(
                    _EagerPan.new,
                    (r) => r.onStart = (_) {},
                  ),
                },
              ),
            ),
          ),
        if (picked != null) _bubble(scheme),
      ],
    );
  }

  /// A rounded row labeled with its date, and its month on the first row
  /// and each month's first day.
  Widget _day(List<RailDay> days, int i, double h, TextStyle? style) {
    final scheme = Theme.of(context).colorScheme;
    final on = days[i].day == _current;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: on ? scheme.primary : scheme.onSurface.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(math.min(6, h / 2)),
      ),
      child: h < 12
          ? const SizedBox.expand()
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  _label(days, i),
                  style: style?.copyWith(
                    color: on ? scheme.onPrimary : scheme.onSurface,
                  ),
                ),
              ),
            ),
    );
  }

  String _label(List<RailDay> days, int i) {
    final date = dayFromNumber(days[i].day);
    return i == 0 || date.day == 1 ? _dayLabel!.format(date) : '${date.day}';
  }

  /// The tapped day grown to fill the column: its date on top, its hours
  /// as ticks, and the touch as a line across it.
  Widget _openDay(int i, double rowH, double t, TextStyle? style) {
    final scheme = Theme.of(context).colorScheme;
    final days = widget.rail.days;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(math.min(6, rowH / 2)),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Opacity(
            opacity: t,
            child: CustomPaint(
              painter: _HoursPainter(
                rail: widget.rail,
                scale: _scale!,
                from: days[i].start,
                to: _endOf(i),
                touch: _touch,
                tick: scheme.onSurface.withValues(alpha: 0.5),
                line: scheme.primary,
              ),
            ),
          ),
          Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(5, 4, 5, 0),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _dayLabel!.format(dayFromNumber(days[i].day)),
                  style: style?.copyWith(color: scheme.onSurface),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The touched time, in a pill left of the column.
  Widget _bubble(ColorScheme scheme) => ValueListenableBuilder<double?>(
    valueListenable: _touch,
    builder: (context, p, _) {
      final scale = _scale;
      if (p == null || scale == null) return const SizedBox.shrink();
      final time = widget.rail.local(scale.timeAt(p));
      return Positioned(
        right: _width + 6,
        top: _pad + p * _barH - 14,
        height: 28,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Center(
              widthFactor: 1,
              child: Text(
                _time!.format(time),
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(color: scheme.onPrimary),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _surface(ColorScheme scheme) {
    if (widget.glass) {
      // Glass rounds both corners of a side alike, so the surface runs past
      // the screen edge by its radius and only the left corners show.
      return OverflowBox(
        alignment: Alignment.centerLeft,
        minWidth: _width + _radius,
        maxWidth: _width + _radius,
        // Out of the header's backdrop group: mid-swipe the next page's rows
        // paint after this panel, and a shared read would miss them.
        child: GlassBackdropGroup(
          enabled: false,
          child: GlassSurface(
            shape: const LiquidRoundedSuperellipse(borderRadius: _radius),
            settings: kGlassPillSettings,
            child: const SizedBox.expand(),
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
        borderRadius: const BorderRadius.horizontal(
          left: Radius.circular(_radius),
        ),
        boxShadow: [
          BoxShadow(color: scheme.shadow.withValues(alpha: 0.2), blurRadius: 8),
        ],
      ),
    );
  }
}

/// An open day's hours as ticks on the left edge, every sixth one longer,
/// placed by [scale], and the touch as a line across.
class _HoursPainter extends CustomPainter {
  _HoursPainter({
    required this.rail,
    required this.scale,
    required this.from,
    required this.to,
    required this.touch,
    required this.tick,
    required this.line,
  }) : super(repaint: touch);

  final ActivityRail rail;
  final RailScale scale;
  final DateTime from;
  final DateTime to;
  final ValueListenable<double?> touch;
  final Color tick;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = tick
      ..strokeWidth = 1;
    // The first whole local hour after the day's start, then each hour.
    final local = rail.local(from);
    var t = from.add(
      Duration(minutes: 60 - local.minute, seconds: -local.second),
    );
    while (t.isBefore(to)) {
      final y = scale.positionOf(t) * size.height;
      final long = rail.local(t).hour % 6 == 0;
      canvas.drawLine(Offset(0, y), Offset(long ? 12 : 6, y), paint);
      t = t.add(const Duration(hours: 1));
    }
    final p = touch.value;
    if (p != null) {
      final y = p * size.height;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = line
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_HoursPainter old) =>
      old.scale != scale || old.tick != tick || old.line != line;
}
