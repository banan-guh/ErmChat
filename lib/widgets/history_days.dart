import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../util/history_timeline.dart';
import 'glass_chrome.dart';

/// The days of a history list, opened from the menu's calendar: a column
/// that slides in from the right edge, one row per day, oldest at the top
/// and stacked from the bottom. A tap jumps to that day and closes it.
class HistoryDays extends StatefulWidget {
  const HistoryDays({
    super.key,
    required this.rail,
    required this.open,
    required this.viewTime,
    required this.onDay,
    this.glass = false,
  });

  final ActivityRail rail;

  /// Whether the days are out; the owner dims the list under them and
  /// closes them on a tap there.
  final ValueNotifier<bool> open;

  /// The list's time, whose day is highlighted.
  final DateTime? Function() viewTime;

  /// A tapped day, by its start.
  final ValueChanged<DateTime> onDay;

  /// Liquid glass surface instead of an opaque one.
  final bool glass;

  /// Whether [rail] spans more than one day, so the days can open.
  static bool hasDays(ActivityRail rail) =>
      rail.calendar && rail.days.length > 1;

  @override
  State<HistoryDays> createState() => _HistoryDaysState();
}

class _HistoryDaysState extends State<HistoryDays>
    with SingleTickerProviderStateMixin {
  /// Day row size, at most.
  static const double _row = 44;
  static const double _maxDay = 40;

  /// Space around the rows inside the surface.
  static const double _pad = 6;
  static const double _width = _row + _pad * 2;
  static const double _radius = 20;

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: widget.open.value ? 1 : 0,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _anim,
    curve: Curves.easeOutCubic,
  );

  DateFormat? _dayLabel;
  String? _locale;

  /// The list's day when the days opened, highlighted.
  int? _current;

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
  }

  @override
  void dispose() {
    widget.open.removeListener(_sync);
    _anim.dispose();
    super.dispose();
  }

  void _sync() {
    if (widget.open.value) {
      // Read on open, outside layout: the list's rows are laid out by then.
      final view = widget.viewTime();
      setState(
        () =>
            _current = view == null ? null : dayNumber(widget.rail.local(view)),
      );
      _anim.forward();
    } else {
      _anim.reverse();
    }
  }

  void _tap(RailDay day) {
    HapticFeedback.selectionClick();
    widget.open.value = false;
    widget.onDay(day.start);
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    if (_locale != locale) {
      _locale = locale;
      _dayLabel = DateFormat('MMM d', locale);
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
        child: LayoutBuilder(builder: (context, box) => _panel(box.maxHeight)),
      ),
    );
  }

  Widget _panel(double height) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall;
    final days = widget.rail.days;
    final dayH = math.min(
      (height - _pad * 2) / math.max(1, days.length),
      _maxDay,
    );
    if (dayH <= 0) return const SizedBox.shrink();
    final gap = math.min(3.0, dayH * 0.2);
    return Align(
      alignment: Alignment.bottomRight,
      child: SizedBox(
        height: days.length * dayH + _pad * 2,
        child: Stack(
          children: [
            Positioned.fill(child: _surface(scheme)),
            Padding(
              padding: const EdgeInsets.all(_pad),
              child: Column(
                children: [
                  for (var i = 0; i < days.length; i++)
                    SizedBox(
                      height: dayH,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _tap(days[i]),
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: gap / 2),
                          child: _day(days, i, dayH - gap, style),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A rounded row labeled with its date, and its month on the first row
  /// and each month's first day.
  Widget _day(List<RailDay> days, int i, double h, TextStyle? style) {
    final scheme = Theme.of(context).colorScheme;
    final on = days[i].day == _current;
    final date = dayFromNumber(days[i].day);
    final label = i == 0 || date.day == 1
        ? _dayLabel!.format(date)
        : '${date.day}';
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
                  label,
                  style: style?.copyWith(
                    color: on ? scheme.onPrimary : scheme.onSurface,
                  ),
                ),
              ),
            ),
    );
  }

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
