import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../color_utils.dart' show streamAccent;
import '../l10n/l10n.dart';
import '../util/history_timeline.dart';
import 'chrome_menu_button.dart' show kChromeMenuMargin, kChromeMenuSize;
import 'glass_chrome.dart';

/// Time rail for the history list. A calendar rail shows [window] of plain
/// time with a grab handle and a days button above it, which slides the bar
/// left and opens a compartment of days beside it, one row per day, where a
/// tap jumps to that day. A results rail is a plain scrollbar.
///
/// It only reports times and positions; the list owner moves [thumb] while
/// the list scrolls and performs the jumps. Visibility, thumb and bubble run
/// on notifiers, so none of it rebuilds the list.
class HistoryScrubber extends StatefulWidget {
  const HistoryScrubber({
    super.key,
    required this.rail,
    required this.scale,
    required this.thumb,
    required this.visible,
    required this.peek,
    required this.panel,
    required this.oldPlace,
    required this.onDragStart,
    required this.onDrag,
    required this.onDragEnd,
    required this.onBack,
    required this.onDay,
    this.atBottom,
    this.onNewest,
    this.glass = false,
    this.reachUp = 0,
  });

  /// Plain time the bar of a calendar rail spans.
  static const Duration window = Duration(days: 3);

  final ActivityRail rail;

  /// The bar's scale. A drag past an end of a calendar bar slides it.
  final ValueNotifier<RailScale> scale;

  /// Bar position of the thumb, 0 (oldest) at the top to 1 (newest).
  final ValueNotifier<double> thumb;
  final ValueListenable<bool> visible;

  /// Shows the bubble without a drag, e.g. after tapping a day marker.
  final ValueListenable<bool> peek;

  /// Whether the days compartment is open; the owner dims the list under it
  /// and closes it on a tap there.
  final ValueNotifier<bool> panel;

  /// Where the list was before the last jump; tapping its marker goes back.
  final ValueListenable<DateTime?> oldPlace;
  final VoidCallback onDragStart;

  /// The time under the handle while dragging.
  final ValueChanged<DateTime> onDrag;

  /// A release on the bar, at this bar position.
  final ValueChanged<double> onDragEnd;
  final VoidCallback onBack;

  /// A tapped day, by its start.
  final ValueChanged<DateTime> onDay;

  /// Whether the list rests on its newest row; the dock's foot offers a way
  /// back while it does not.
  final ValueListenable<bool>? atBottom;
  final VoidCallback? onNewest;

  /// Liquid glass: the dock floats as a glass capsule instead of hugging
  /// the edge.
  final bool glass;

  /// How far above the rail the dock reaches while out, to sit behind the
  /// menu trigger it hangs from.
  final double reachUp;

  /// Whether [rail] spans more than one day, so the days can open.
  static bool hasDays(ActivityRail rail) =>
      rail.calendar && rail.days.length > 1;

  @override
  State<HistoryScrubber> createState() => _HistoryScrubberState();
}

/// The days compartment's rows: one per day, oldest at the top, sharing the
/// height up to [maxDay] each and stacked from the bottom.
class _Days {
  _Days(this.rail, double height)
    : dayH = math.min(height / math.max(1, rail.days.length), maxDay),
      bottom = height;

  static const double maxDay = 40;

  final ActivityRail rail;
  final double dayH;
  final double bottom;

  List<RailDay> get days => rail.days;
  double get top => bottom - days.length * dayH;

  /// The day at [y], or null outside the rows.
  RailDay? at(double y) {
    if (y < top || y >= bottom) return null;
    return days[((y - top) / dayH).floor().clamp(0, days.length - 1)];
  }
}

/// Claims a touch on the rail at once, so a diagonal drag scrubs instead of
/// paging channels.
class _EagerPan extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _HistoryScrubberState extends State<HistoryScrubber>
    with TickerProviderStateMixin {
  /// The dock: as wide as twice the menu trigger's axis, so the bar runs
  /// straight down from it.
  static const double _barWidth = _inset * 2;

  /// Shorter than this (stream and keyboard up), the rail cannot pick a
  /// stretch, so it hides.
  static const double _minHeight = 160;

  /// The axis the trigger, the days button, the bar, the pin and the newest
  /// tab share, in from the edge.
  static const double _inset = kChromeMenuMargin + kChromeMenuSize / 2;

  /// Day row width.
  static const double _row = 44;

  /// Width the days compartment adds, rows plus margins.
  static const double _daysWidth = _row + 12;

  /// The dock's head, the days button.
  static const double _buttonRoom = 40;

  /// The dock's corner radius.
  static const double _radius = 20;

  /// The dock's foot, the scroll-down button's height.
  static const double _tab = 56;

  /// Movement before a touch counts as a drag rather than a tap.
  static const double _slop = 6;

  /// A tap this close to the handle or the marker hits it.
  static const double _reach = 28;
  static const Duration _fade = Duration(milliseconds: 200);

  /// Height of the edge band around the thumb kept from Android's back
  /// gesture; Android honors up to 200dp per edge.
  static const double _band = 160;

  static const _device = MethodChannel('ermchat/device');

  /// The rail whose band is excluded; only it may clear the exclusion.
  static _HistoryScrubberState? _excluding;

  final ValueNotifier<bool> _dragging = ValueNotifier(false);

  /// 0 at rest, 1 while dragging or peeking: grows the bar and shows the
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

  /// 0 closed, 1 with the days compartment out.
  late final AnimationController _open = AnimationController(
    vsync: this,
    duration: _fade,
  );
  late final Animation<double> _openCurve = CurvedAnimation(
    parent: _open,
    curve: Curves.easeOutCubic,
  );

  double _height = 1;
  double _dpr = 1;
  double? _sentCenter;
  _Days? _days;

  // Touch state.
  Offset _down = Offset.zero;
  double _moved = 0;
  bool _started = false;

  DateFormat? _day;
  DateFormat? _time;
  DateFormat? _dayLabel;
  String? _locale;

  @override
  void initState() {
    super.initState();
    _dragging.addListener(_syncActive);
    widget.peek.addListener(_syncActive);
    widget.panel.addListener(_syncOpen);
    widget.visible.addListener(_syncExclusion);
    widget.thumb.addListener(_syncExclusion);
    if (widget.peek.value) _active.value = 1;
    if (widget.panel.value) _open.value = 1;
  }

  @override
  void didUpdateWidget(HistoryScrubber old) {
    super.didUpdateWidget(old);
    if (old.peek != widget.peek) {
      old.peek.removeListener(_syncActive);
      widget.peek.addListener(_syncActive);
    }
    if (old.panel != widget.panel) {
      old.panel.removeListener(_syncOpen);
      widget.panel.addListener(_syncOpen);
    }
    if (old.visible != widget.visible) {
      old.visible.removeListener(_syncExclusion);
      widget.visible.addListener(_syncExclusion);
    }
    if (old.thumb != widget.thumb) {
      old.thumb.removeListener(_syncExclusion);
      widget.thumb.addListener(_syncExclusion);
    }
    if (old.rail != widget.rail) _days = null;
  }

  @override
  void dispose() {
    widget.peek.removeListener(_syncActive);
    widget.panel.removeListener(_syncOpen);
    widget.visible.removeListener(_syncExclusion);
    widget.thumb.removeListener(_syncExclusion);
    _clearExclusion();
    _dragging.dispose();
    _active.dispose();
    _open.dispose();
    super.dispose();
  }

  void _syncActive() {
    if (_dragging.value || widget.peek.value) {
      _active.forward();
    } else {
      _active.reverse();
    }
  }

  void _syncOpen() {
    if (widget.panel.value) {
      _open.forward();
    } else {
      _open.reverse();
    }
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
    final center =
        _buttonRoom + widget.thumb.value * (box.size.height - _buttonRoom);
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
      o.dx + box.size.width - _barWidth,
      o.dy + center - _band / 2,
      _barWidth,
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

  _Days get _layout => _days ??= _Days(widget.rail, _height);

  DateTime get _handleTime => widget.scale.value.timeAt(widget.thumb.value);

  /// Bar y of the old place marker, or null when off the bar.
  double? _oldPlaceY() {
    final old = widget.oldPlace.value;
    if (old == null) return null;
    final s = widget.scale.value;
    if (old.isBefore(s.from) || old.isAfter(s.to)) return null;
    return s.positionOf(old) * _height;
  }

  void _onDown(DragStartDetails d) {
    _down = d.localPosition;
    _moved = 0;
    _started = false;
  }

  void _begin() {
    _started = true;
    _dragging.value = true;
    widget.onDragStart();
    widget.thumb.value = (_down.dy / _height).clamp(0.0, 1.0);
    widget.onDrag(_handleTime);
  }

  void _update(DragUpdateDetails d) {
    // An open compartment takes taps only.
    if (widget.panel.value) return;
    _moved += d.delta.distance;
    if (!_started) {
      if (_moved < _slop) return;
      _begin();
    }
    final before = _handleTime;
    final next = widget.thumb.value + d.delta.dy / _height;
    widget.thumb.value = next.clamp(0.0, 1.0);
    if (next < 0 || next > 1) _slide(next < 0 ? next : next - 1);
    final after = _handleTime;
    final tick = widget.rail.crossed(before, after);
    if (tick == 2) {
      HapticFeedback.mediumImpact();
    } else if (tick == 1) {
      HapticFeedback.selectionClick();
    }
    widget.onDrag(after);
  }

  /// Moves a calendar bar's stretch by [over] bars of finger travel past its
  /// end, at the pace the bar had there, up to the rail's ends. The handle
  /// stays on the end; the bar moves under it.
  void _slide(double over) {
    final r = widget.rail;
    final s = widget.scale.value;
    if (!r.calendar || identical(s, r)) return;
    // The time the overshoot covers just inside that end of the bar.
    final a = over.abs().clamp(0.0, 1.0);
    final by = over < 0
        ? -s.timeAt(a).difference(s.timeAt(0))
        : s.timeAt(1).difference(s.timeAt(1 - a));
    var from = s.from.add(by);
    var to = s.to.add(by);
    if (from.isBefore(r.from)) {
      to = to.add(r.from.difference(from));
      from = r.from;
    }
    if (to.isAfter(r.to)) {
      from = from.subtract(to.difference(r.to));
      to = r.to;
    }
    if (from == s.from && to == s.to) return;
    widget.scale.value = r.window(from, to);
  }

  void _end([DragEndDetails? _]) {
    if (_started) {
      _started = false;
      _dragging.value = false;
      widget.onDragEnd(widget.thumb.value);
      return;
    }
    if (_moved < _slop) _tap(_down);
  }

  /// A tap: a day when the compartment is out (anywhere else closes it),
  /// otherwise the old place marker.
  void _tap(Offset at) {
    if (widget.panel.value) {
      final width = _barWidth + _daysWidth;
      final day = at.dx >= width - _daysWidth ? _layout.at(at.dy) : null;
      widget.panel.value = false;
      if (day != null) {
        HapticFeedback.selectionClick();
        widget.onDay(day.start);
      }
      return;
    }
    final old = _oldPlaceY();
    if (old != null && (old - at.dy).abs() < _reach) widget.onBack();
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
    final atBottom = widget.atBottom;
    return AnimatedBuilder(
      animation: _openCurve,
      builder: (context, child) => SizedBox(
        width: _barWidth + _daysWidth * _openCurve.value,
        child: child,
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          if (box.maxHeight < _minHeight) return const SizedBox.shrink();
          final tabH = widget.onNewest == null ? 0.0 : _tab;
          final barH = box.maxHeight - _buttonRoom - tabH;
          if (barH != _height) {
            _height = barH;
            _days = null;
          }
          Widget fade(bool on, Widget child) => IgnorePointer(
            ignoring: !on,
            child: AnimatedOpacity(
              opacity: on ? 1 : 0,
              duration: _fade,
              child: child,
            ),
          );
          return ListenableBuilder(
            listenable: Listenable.merge([widget.visible, ?atBottom]),
            builder: (context, _) {
              final shown = widget.visible.value;
              final tab = tabH > 0 && !(atBottom?.value ?? true);
              final full = box.maxHeight + widget.reachUp;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  // The dock: the whole column while the bar shows, up
                  // behind the menu trigger, and just the newest tab while
                  // scrolled up and idle. Only showing and hiding animate;
                  // a resize (keyboard, a banner pushing the input) applies
                  // at once.
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: shown ? 1 : 0),
                    duration: _fade,
                    curve: Curves.easeOutCubic,
                    builder: (context, out, _) => TweenAnimationBuilder<double>(
                      tween: Tween(end: tab ? 1 : 0),
                      duration: _fade,
                      curve: Curves.easeOutCubic,
                      builder: (context, foot, _) {
                        final height = math.max(out * full, foot * tabH);
                        // An empty dock mounts no glass.
                        if (height == 0) return const SizedBox.shrink();
                        return Positioned(
                          right: 0,
                          left: 0,
                          bottom: 0,
                          height: height,
                          child: _surface(scheme, out),
                        );
                      },
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: _buttonRoom,
                        child: fade(shown, _daysButton(scheme)),
                      ),
                      Expanded(child: fade(shown, _bar(scheme))),
                      if (tabH > 0)
                        SizedBox(
                          height: tabH,
                          child: fade(tab, _newestTab(scheme)),
                        ),
                    ],
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  /// The dock's surface. Out ([out] 1) it runs square into the corner
  /// behind the menu trigger; down to the newest tab alone, its top rounds
  /// like the bottom.
  Widget _surface(ColorScheme scheme, double out) {
    if (widget.glass) {
      // Glass rounds both corners of a side alike, so the surface runs past
      // the screen edge by its radius and only the left corners show.
      return LayoutBuilder(
        builder: (context, box) => OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: box.maxWidth + _radius,
          maxWidth: box.maxWidth + _radius,
          // Out of the header's backdrop group: mid-swipe the next page's
          // rows paint after this dock, and a shared read would miss them.
          child: GlassBackdropGroup(
            enabled: false,
            child: GlassSurface(
              shape: LiquidVerticalRoundedSuperellipse(
                topRadius: _radius * (1 - out),
                bottomRadius: _radius,
              ),
              settings: kGlassPillSettings,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(_radius * (1 - out)),
          bottomLeft: const Radius.circular(_radius),
        ),
        boxShadow: [
          BoxShadow(color: scheme.shadow.withValues(alpha: 0.2), blurRadius: 8),
        ],
      ),
    );
  }

  /// Opens and closes the days, at the dock's head under the menu trigger,
  /// like the newest tab at its foot.
  Widget _daysButton(ColorScheme scheme) {
    if (!HistoryScrubber.hasDays(widget.rail)) return const SizedBox.shrink();
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          widget.panel.value = !widget.panel.value;
        },
        child: Padding(
          padding: const EdgeInsets.only(right: _inset - 10),
          child: Align(
            alignment: Alignment.centerRight,
            child: ValueListenableBuilder<bool>(
              valueListenable: widget.panel,
              builder: (context, open, _) => Icon(
                open ? Icons.close : Icons.calendar_month,
                size: 20,
                color: open ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Back to the newest row: the scroll-down button's job, at the dock's
  /// foot.
  Widget _newestTab(ColorScheme scheme) => Material(
    type: MaterialType.transparency,
    child: InkWell(
      borderRadius: const BorderRadius.horizontal(
        left: Radius.circular(_radius),
      ),
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onNewest?.call();
      },
      child: Padding(
        padding: const EdgeInsets.only(right: _inset - 12),
        child: Align(
          alignment: Alignment.centerRight,
          child: Icon(Icons.keyboard_arrow_down, color: scheme.onSurface),
        ),
      ),
    ),
  );

  Widget _bar(ColorScheme scheme) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    gestures: {
      _EagerPan: GestureRecognizerFactoryWithHandlers<_EagerPan>(
        _EagerPan.new,
        (r) => r
          ..onStart = _onDown
          ..onUpdate = _update
          ..onEnd = _end
          ..onCancel = _end,
      ),
    },
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _RailPainter(
              rail: widget.rail,
              scale: widget.scale,
              thumb: widget.thumb,
              oldPlace: widget.oldPlace,
              active: _activeCurve,
              open: _openCurve,
              inset: _inset,
              daysWidth: _daysWidth,
              track: scheme.onSurface,
              accent: scheme.primary,
              glyph: scheme.onPrimary,
              stream: streamAccent,
              shadow: scheme.shadow,
            ),
          ),
        ),
        _daysCompartment(context, scheme),
        ListenableBuilder(
          listenable: Listenable.merge([widget.thumb, widget.scale, _active]),
          builder: (context, _) => Positioned.fill(
            child: Stack(
              clipBehavior: Clip.none,
              children: [_barLabels(context, scheme), _bubble(context, scheme)],
            ),
          ),
        ),
      ],
    ),
  );

  /// The days, sliding in from the right edge: one rounded row per day,
  /// labeled with its date (and month on the first row and each month's
  /// first day), the list's day highlighted.
  Widget _daysCompartment(BuildContext context, ColorScheme scheme) =>
      ListenableBuilder(
        listenable: Listenable.merge([_openCurve, widget.thumb, widget.scale]),
        builder: (context, _) {
          final o = _openCurve.value;
          if (o == 0) return const SizedBox.shrink();
          final d = _layout;
          final current = dayNumber(widget.rail.local(_handleTime));
          final gap = math.min(3.0, d.dayH * 0.2);
          final style = Theme.of(context).textTheme.labelSmall;
          final rows = <Widget>[];
          for (var i = 0; i < d.days.length; i++) {
            final day = d.days[i];
            final on = day.day == current;
            final date = dayFromNumber(day.day);
            final label = i == 0 || date.day == 1
                ? _dayLabel!.format(date)
                : '${date.day}';
            rows.add(
              Positioned(
                right: 6,
                top: d.top + i * d.dayH + gap / 2,
                height: d.dayH - gap,
                width: _row,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: on
                        ? scheme.primary
                        : scheme.onSurface.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(
                      math.min(6, (d.dayH - gap) / 2),
                    ),
                  ),
                  child: d.dayH < 12
                      ? null
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
                ),
              ),
            );
          }
          return Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: _daysWidth,
            child: IgnorePointer(
              child: Opacity(
                opacity: o,
                child: Transform.translate(
                  offset: Offset(_daysWidth * (1 - o), 0),
                  child: Stack(clipBehavior: Clip.none, children: rows),
                ),
              ),
            ),
          );
        },
      );

  /// A small label pinned left of the bar at [y].
  Widget _label(String text, double y, ColorScheme scheme) => Positioned(
    top: y - 9,
    right: _barWidth - _inset + 10,
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
            text,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    ),
  );

  /// Day starts beside the bar while dragging it, thinned so none overlap
  /// each other or the bubble.
  Widget _barLabels(BuildContext context, ColorScheme scheme) {
    final t = _activeCurve.value;
    if (t == 0 || !_dragging.value) return const SizedBox.shrink();
    final s = widget.scale.value;
    final thumbY = widget.thumb.value * _height;
    final labels = <Widget>[];
    var last = double.negativeInfinity;
    for (final d in widget.rail.days) {
      if (!d.start.isAfter(s.from) || d.start.isAfter(s.to)) continue;
      final y = s.positionOf(d.start) * _height;
      if (y - last < 22 || (y - thumbY).abs() < 40) continue;
      last = y;
      labels.add(_label(_dayLabel!.format(dayFromNumber(d.day)), y, scheme));
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

  /// Date and time, plus the stream title when one was live, pinned to the
  /// left of the thumb.
  Widget _bubble(BuildContext context, ColorScheme scheme) {
    final t = _activeCurve.value;
    if (t == 0) return const SizedBox.shrink();
    final pos = widget.thumb.value;
    final at = widget.scale.value.timeAt(pos).toLocal();
    final stream = widget.rail.streamAt(at);
    final text = Theme.of(context).textTheme;
    const height = 56.0;
    return Positioned(
      top: (pos * _height - height / 2).clamp(-8.0, _height - height + 8),
      right: _barWidth - _inset + 14,
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

/// Paints the bar: a slim track that breaks into dots over an hour or more
/// with nothing said, stream spans in [stream], the old place marker, and a
/// round knob in [accent] for where the list is. It slides left by [daysWidth] as
/// the days come out ([open]).
class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.rail,
    required this.scale,
    required this.thumb,
    required this.oldPlace,
    required this.active,
    required this.open,
    required this.inset,
    required this.daysWidth,
    required this.track,
    required this.accent,
    required this.glyph,
    required this.stream,
    required this.shadow,
  }) : super(repaint: Listenable.merge([thumb, scale, oldPlace, active, open]));

  final ActivityRail rail;
  final ValueListenable<RailScale> scale;
  final ValueListenable<double> thumb;
  final ValueListenable<DateTime?> oldPlace;
  final Animation<double> active;
  final Animation<double> open;
  final double inset;
  final double daysWidth;
  final Color track;
  final Color accent;
  final Color glyph;
  final Color stream;
  final Color shadow;

  static const double _step = 2;
  static const double _dotStep = 6;

  /// Silence at least this long shows as dots.
  static const Duration _gap = Duration(hours: 1);

  /// Bar spans with nothing said for [_gap] or more, cached for one scale
  /// and height.
  RailScale? _gapsFor;
  double _gapsHeight = 0;
  List<RailSpan> _gaps = const [];

  List<RailSpan> _gapsOf(RailScale s, double h) {
    if (identical(_gapsFor, s) && _gapsHeight == h) return _gaps;
    _gapsFor = s;
    _gapsHeight = h;
    final n = (h / _step).ceil();
    final out = <RailSpan>[];
    int? run;
    for (var i = 0; i <= n; i++) {
      final empty =
          i < n &&
          rail.countBetween(
                s.timeAt(i * _step / h),
                s.timeAt(((i + 1) * _step / h).clamp(0.0, 1.0)),
              ) ==
              0;
      if (empty) {
        run ??= i;
        continue;
      }
      if (run != null) {
        final a = run * _step / h;
        final b = (i * _step / h).clamp(0.0, 1.0);
        if (s.timeAt(b).difference(s.timeAt(a)) >= _gap) {
          out.add(RailSpan(a, b));
        }
        run = null;
      }
    }
    return _gaps = out;
  }

  @override
  void paint(Canvas canvas, Size size) => _paintBar(canvas, size, 1);

  void _paintBar(Canvas canvas, Size size, double alpha) {
    final t = active.value;
    final h = size.height;
    final s = scale.value;
    final x = size.width - daysWidth * open.value - inset;
    final w = ui.lerpDouble(3, 5, t)!;
    final base = Paint()
      ..color = track.withValues(alpha: ui.lerpDouble(0.16, 0.24, t)! * alpha);
    final live = Paint()
      ..color = stream.withValues(alpha: ui.lerpDouble(0.75, 1, t)! * alpha);

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

    var cursor = 0.0;
    for (final g in _gapsOf(s, h)) {
      if (g.start > cursor) bar(cursor, g.start, base);
      for (
        var y = g.start * h + _dotStep / 2;
        y < g.end * h - _dotStep / 4;
        y += _dotStep
      ) {
        canvas.drawCircle(Offset(x, y), w * 0.32, base);
      }
      cursor = g.end;
    }
    if (cursor < 1) bar(cursor, 1, base);
    for (final st in rail.streams) {
      if (!st.end.isAfter(s.from) || st.start.isAfter(s.to)) continue;
      bar(s.positionOf(st.start), s.positionOf(st.end), live);
    }

    // The knob and the old place marker stop the same distance short of
    // the ends, so a marker for an end sits level with the knob there.
    final r = ui.lerpDouble(7, 9, t)!;
    double rest(double y) => y.clamp(r, h - r);
    final old = oldPlace.value;
    if (old != null && !old.isBefore(s.from) && !old.isAfter(s.to)) {
      _paintMarker(canvas, x - r - 3, rest(s.positionOf(old) * h), alpha);
    }

    final knob = Rect.fromCircle(
      center: Offset(x, rest(thumb.value * h)),
      radius: r,
    );
    if (t > 0) {
      canvas.drawShadow(
        Path()..addOval(knob),
        shadow.withValues(alpha: t * alpha),
        3,
        false,
      );
    }
    canvas.drawOval(knob, Paint()..color = accent.withValues(alpha: alpha));
  }

  /// A filled tag, a rounded box pointing at [tip]: where the list was.
  void _paintMarker(Canvas canvas, double tip, double y, double alpha) {
    final p = Paint()
      ..color = track.withValues(alpha: 0.8 * alpha)
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round;
    final tag = Path()
      ..moveTo(tip - 11, y - 4)
      ..lineTo(tip - 5, y - 4)
      ..lineTo(tip, y)
      ..lineTo(tip - 5, y + 4)
      ..lineTo(tip - 11, y + 4)
      ..close();
    canvas.drawPath(tag, p..style = PaintingStyle.fill);
    canvas.drawPath(tag, p..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.rail != rail ||
      old.scale != scale ||
      old.active != active ||
      old.open != open ||
      old.inset != inset ||
      old.daysWidth != daysWidth ||
      old.track != track ||
      old.accent != accent ||
      old.glyph != glyph ||
      old.stream != stream ||
      old.shadow != shadow;
}
