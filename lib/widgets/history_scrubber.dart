import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../color_utils.dart' show streamAccent;
import '../l10n/l10n.dart';
import '../util/history_timeline.dart';

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
  });

  /// Plain time the bar of a calendar rail spans.
  static const Duration window = Duration(days: 3);

  final ActivityRail rail;

  /// The bar's scale.
  final ValueListenable<RailScale> scale;

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
  static const double _barWidth = 48;

  /// Shorter than this (stream and keyboard up), the rail cannot pick a
  /// stretch, so it hides.
  static const double _minHeight = 160;

  /// Bar center, in from the bar's right edge.
  static const double _inset = 12;

  /// Day row width.
  static const double _row = 44;

  /// Width the days compartment adds, rows plus margins.
  static const double _daysWidth = _row + 12;

  /// The days button, and the room above the bar it sits in.
  static const double _buttonSize = 24;
  static const double _buttonRoom = 36;

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
    widget.thumb.value = (widget.thumb.value + d.delta.dy / _height).clamp(
      0.0,
      1.0,
    );
    final after = _handleTime;
    final tick = widget.rail.crossed(before, after);
    if (tick == 2) {
      HapticFeedback.mediumImpact();
    } else if (tick == 1) {
      HapticFeedback.selectionClick();
    }
    widget.onDrag(after);
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
      child: AnimatedBuilder(
        animation: _openCurve,
        builder: (context, child) => SizedBox(
          width: _barWidth + _daysWidth * _openCurve.value,
          child: child,
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            if (box.maxHeight < _minHeight) return const SizedBox.shrink();
            final barH = box.maxHeight - _buttonRoom;
            if (barH != _height) {
              _height = barH;
              _days = null;
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: _buttonRoom, child: _daysButton(scheme)),
                Expanded(child: _bar(scheme)),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Opens and closes the days, beside the bar's top end.
  Widget _daysButton(ColorScheme scheme) {
    if (!HistoryScrubber.hasDays(widget.rail)) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _openCurve,
      builder: (context, _) => Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: EdgeInsets.only(
            right: _daysWidth * _openCurve.value + _inset - _buttonSize / 2,
          ),
          child: SizedBox.square(
            dimension: _buttonSize,
            child: Material(
              color: widget.panel.value
                  ? scheme.primary
                  : scheme.surfaceContainerHighest,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () {
                  HapticFeedback.selectionClick();
                  widget.panel.value = !widget.panel.value;
                },
                child: Icon(
                  Icons.calendar_month,
                  size: 16,
                  color: widget.panel.value
                      ? scheme.onPrimary
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

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
  /// left of the thumb. At the top of a bar with older days past it, a hint
  /// at the days.
  Widget _bubble(BuildContext context, ColorScheme scheme) {
    final t = _activeCurve.value;
    if (t == 0) return const SizedBox.shrink();
    final pos = widget.thumb.value;
    final at = widget.scale.value.timeAt(pos).toLocal();
    final stream = widget.rail.streamAt(at);
    final older =
        _dragging.value &&
        pos < 0.05 &&
        HistoryScrubber.hasDays(widget.rail) &&
        widget.scale.value.from.isAfter(widget.rail.from);
    final text = Theme.of(context).textTheme;
    const height = 56.0;
    return Positioned(
      top: (pos * _height - height / 2).clamp(-8.0, _height - height + 8),
      right: _barWidth - _inset + 14,
      height: older ? height + 18 : height,
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
                        if (older)
                          Text(
                            context.l10n.historyRailOlder,
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

/// Paints the bar: a slim track that breaks into dots over an hour or more
/// with nothing said, stream spans in [stream], the old place marker, and a
/// grab handle in [accent]. It slides left by [daysWidth] as the days
/// compartment comes out ([open]).
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
  void paint(Canvas canvas, Size size) {
    final t = active.value;
    final h = size.height;
    final s = scale.value;
    final x = size.width - daysWidth * open.value - inset;
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

    final old = oldPlace.value;
    if (old != null && !old.isBefore(s.from) && !old.isAfter(s.to)) {
      _paintMarker(canvas, x - 7, s.positionOf(old) * h);
    }

    // A map pin on its side, its point on the bar and its head toward the
    // list.
    final r = ui.lerpDouble(7, 9, t)!;
    final cy = (thumb.value * h).clamp(r, h - r);
    const reach = 2.2;
    final hx = x - r * reach;
    final a = math.acos(1 / reach);
    final pin = Path()
      ..moveTo(x, cy)
      ..lineTo(hx + r * math.cos(a), cy + r * math.sin(a))
      ..arcTo(
        Rect.fromCircle(center: Offset(hx, cy), radius: r),
        a,
        2 * math.pi - 2 * a,
        false,
      )
      ..close();
    if (t > 0) {
      canvas.drawShadow(pin, shadow.withValues(alpha: t), 3, false);
    }
    canvas.drawPath(pin, Paint()..color = accent);
    canvas.drawCircle(Offset(hx, cy), r * 0.38, Paint()..color = glyph);
  }

  /// A filled tag, a rounded box pointing at [tip]: where the list was.
  void _paintMarker(Canvas canvas, double tip, double y) {
    final p = Paint()
      ..color = track.withValues(alpha: 0.8)
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
