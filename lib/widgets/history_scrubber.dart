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
/// time with a grab handle; sliding left of it while dragging opens a month
/// panel, one row per day, to pick an older day. Letting go in the panel
/// cancels; sliding back right brings the bar back around the picked time,
/// and letting go there jumps. A results rail is a plain scrollbar.
///
/// It only reports times and positions; the list owner moves [thumb] while
/// the list scrolls and performs the jump. Visibility, thumb and bubble run
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
    required this.onCancel,
    required this.onBack,
  });

  /// Plain time the bar of a calendar rail spans.
  static const Duration window = Duration(days: 3);

  final ActivityRail rail;

  /// The bar's scale; sliding back from the month panel replaces it with
  /// [window] around the picked time.
  final ValueNotifier<RailScale> scale;

  /// Bar position of the thumb, 0 (oldest) at the top to 1 (newest).
  final ValueNotifier<double> thumb;
  final ValueListenable<bool> visible;

  /// Shows the bubble without a drag, e.g. after tapping a day marker.
  final ValueListenable<bool> peek;

  /// Whether the month panel is open, for the owner to dim the list.
  final ValueNotifier<bool> panel;

  /// Where the list was before the last drag; tapping its marker goes back.
  final ValueListenable<DateTime?> oldPlace;
  final VoidCallback onDragStart;

  /// The time under the handle while dragging.
  final ValueChanged<DateTime> onDrag;

  /// A release on the bar, at this bar position.
  final ValueChanged<double> onDragEnd;

  /// A release in the month panel, or a tap away from the marker.
  final VoidCallback onCancel;
  final VoidCallback onBack;

  /// Whether [rail] holds more than the bar shows, so the panel can open.
  static bool hasMonth(ActivityRail rail) =>
      rail.calendar && rail.to.difference(rail.from) > window;

  @override
  State<HistoryScrubber> createState() => _HistoryScrubberState();
}

/// The month panel's rows: one per day, oldest at the top, sharing the
/// height up to [maxDay] each and stacked from the bottom.
class _Month {
  _Month(this.rail, double height)
    : dayH = math.min(height / math.max(1, rail.days.length), maxDay),
      bottom = height;

  static const double maxDay = 40;

  final ActivityRail rail;
  final double dayH;
  final double bottom;

  List<RailDay> get days => rail.days;
  double get top => bottom - days.length * dayH;

  DateTime _end(int i) => i + 1 < days.length ? days[i + 1].start : rail.to;

  /// Panel y of [t].
  double yOf(DateTime t) {
    var i = days.length - 1;
    while (i > 0 && t.isBefore(days[i].start)) {
      i--;
    }
    final start = days[i].start;
    final span = _end(i).difference(start).inMilliseconds;
    final frac = span <= 0
        ? 0.0
        : (t.difference(start).inMilliseconds / span).clamp(0.0, 1.0);
    return top + (i + frac) * dayH;
  }

  /// Time at panel y.
  DateTime timeAt(double y) {
    final rows = (y - top) / dayH;
    final i = rows.floor().clamp(0, days.length - 1);
    final frac = (rows - i).clamp(0.0, 1.0);
    final start = days[i].start;
    final span = _end(i).difference(start).inMilliseconds;
    return start.add(Duration(milliseconds: (frac * span).round()));
  }
}

/// Claims a touch on the rail at once, so a sideways slide opens the month
/// panel instead of paging channels.
class _EagerPan extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _HistoryScrubberState extends State<HistoryScrubber>
    with TickerProviderStateMixin {
  static const double _width = 48;

  /// Shorter than this (stream and keyboard up), the rail cannot pick a
  /// stretch, so it hides.
  static const double _minHeight = 160;

  /// Bar center, in from the right edge.
  static const double _inset = 12;

  /// Month panel row widths: an empty day to the busiest.
  static const double _rowMin = 20;
  static const double _rowMax = 40;

  /// Panel rows end this far in from the right edge.
  static const double _panelInset = 2;

  /// Sliding this far left of the bar opens the panel; back within
  /// [_closeAt] closes it.
  static const double _openAt = 64;
  static const double _closeAt = 32;

  /// Movement before a touch counts as a drag rather than a tap.
  static const double _slop = 6;
  static const Duration _fade = Duration(milliseconds: 200);

  /// Height of the edge band around the thumb kept from Android's back
  /// gesture; Android honors up to 200dp per edge.
  static const double _band = 160;

  static const _device = MethodChannel('ermchat/device');

  /// The rail whose band is excluded; only it may clear the exclusion.
  static _HistoryScrubberState? _excluding;

  final ValueNotifier<bool> _dragging = ValueNotifier(false);

  /// Handle y in the month panel, while it is open.
  final ValueNotifier<double> _panelY = ValueNotifier(0);
  final ValueNotifier<bool> _cancelled = ValueNotifier(false);

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

  /// 0 for the bar, 1 for the month panel.
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
  _Month? _month;

  // Touch state.
  double _downY = 0;
  double _moved = 0;
  bool _started = false;
  bool _inPanel = false;
  RailScale? _startScale;

  DateFormat? _day;
  DateFormat? _time;
  DateFormat? _dayLabel;
  DateFormat? _rowLabel;
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
    if (old.rail != widget.rail) _month = null;
  }

  @override
  void dispose() {
    widget.peek.removeListener(_syncActive);
    widget.visible.removeListener(_syncExclusion);
    widget.thumb.removeListener(_syncExclusion);
    _clearExclusion();
    _dragging.dispose();
    _panelY.dispose();
    _cancelled.dispose();
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

  _Month get _layout => _month ??= _Month(widget.rail, _height);

  /// The time under the handle.
  DateTime get _handleTime => _inPanel
      ? _layout.timeAt(_panelY.value)
      : widget.scale.value.timeAt(widget.thumb.value);

  /// Bar y of the old place marker, or null when off the bar.
  double? _oldPlaceY() {
    final old = widget.oldPlace.value;
    if (old == null) return null;
    if (_inPanel) return _layout.yOf(old);
    final s = widget.scale.value;
    if (old.isBefore(s.from) || old.isAfter(s.to)) return null;
    return s.positionOf(old) * _height;
  }

  void _down(DragStartDetails d) {
    _downY = d.localPosition.dy;
    _moved = 0;
    _started = false;
  }

  void _begin() {
    _started = true;
    _inPanel = false;
    _cancelled.value = false;
    _startScale = widget.scale.value;
    _dragging.value = true;
    widget.onDragStart();
    widget.thumb.value = (_downY / _height).clamp(0.0, 1.0);
    widget.onDrag(_handleTime);
  }

  void _update(DragUpdateDetails d) {
    _moved += d.delta.distance;
    if (!_started) {
      if (_moved < _slop) return;
      _begin();
    }
    final away = (_width - _inset) - d.localPosition.dx;
    if (!_inPanel && away >= _openAt && HistoryScrubber.hasMonth(widget.rail)) {
      _panelY.value = _layout.yOf(_handleTime);
      _inPanel = true;
      widget.panel.value = true;
      _open.forward();
      HapticFeedback.mediumImpact();
    } else if (_inPanel && away < _closeAt) {
      final t = _layout.timeAt(_panelY.value);
      final r = widget.rail;
      final s = TimeWindow.around(t, HistoryScrubber.window, r.from, r.to);
      _inPanel = false;
      widget.scale.value = s;
      widget.thumb.value = s.positionOf(t);
      widget.panel.value = false;
      _open.reverse();
      HapticFeedback.mediumImpact();
    }
    final before = _handleTime;
    if (_inPanel) {
      _panelY.value = (_panelY.value + d.delta.dy).clamp(
        _layout.top,
        _layout.bottom,
      );
    } else {
      widget.thumb.value = (widget.thumb.value + d.delta.dy / _height).clamp(
        0.0,
        1.0,
      );
    }
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
    if (!_started) {
      final y = _oldPlaceY();
      if (y != null && (y - _downY).abs() < 24) widget.onBack();
      return;
    }
    _started = false;
    _dragging.value = false;
    if (_inPanel) {
      _inPanel = false;
      _cancelled.value = true;
      final start = _startScale;
      if (start != null) widget.scale.value = start;
      widget.panel.value = false;
      _open.reverse();
      widget.onCancel();
      return;
    }
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
      _rowLabel = DateFormat('EEE d', locale);
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
            if (box.maxHeight != _height) {
              _height = box.maxHeight;
              _month = null;
            }
            return RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: {
                _EagerPan: GestureRecognizerFactoryWithHandlers<_EagerPan>(
                  _EagerPan.new,
                  (r) => r
                    ..onStart = _down
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
                        month: _layout,
                        thumb: widget.thumb,
                        panelY: _panelY,
                        oldPlace: widget.oldPlace,
                        active: _activeCurve,
                        open: _openCurve,
                        inPanel: () => _inPanel,
                        inset: _inset,
                        panelInset: _panelInset,
                        rowMin: _rowMin,
                        rowMax: _rowMax,
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
                      widget.scale,
                      _active,
                      _open,
                      _panelY,
                      _cancelled,
                    ]),
                    builder: (context, _) => Positioned.fill(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          _barLabels(context, scheme),
                          _panelLabels(context, scheme),
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

  /// A small label pinned left of the rail at [y].
  Widget _label(String text, double y, double right, ColorScheme scheme) =>
      Positioned(
        top: y - 9,
        right: right,
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
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      );

  /// Day starts beside the bar while dragging it, thinned so none overlap
  /// each other or the bubble.
  Widget _barLabels(BuildContext context, ColorScheme scheme) {
    final t = _activeCurve.value * (1 - _openCurve.value);
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
      labels.add(
        _label(
          _dayLabel!.format(dayFromNumber(d.day)),
          y,
          _width - _inset + 10,
          scheme,
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

  /// Day names beside the panel rows, and above them what the handle
  /// picks and how to go there.
  Widget _panelLabels(BuildContext context, ColorScheme scheme) {
    final t = _openCurve.value;
    if (t == 0) return const SizedBox.shrink();
    final m = _layout;
    final right = _panelInset + _rowMax + 8;
    final labels = <Widget>[];
    var last = double.negativeInfinity;
    for (var i = 0; i < m.days.length; i++) {
      final y = m.top + (i + 0.5) * m.dayH;
      if (y - last < 20) continue;
      last = y;
      labels.add(
        _label(
          _rowLabel!.format(dayFromNumber(m.days[i].day)),
          y,
          right,
          scheme,
        ),
      );
    }
    final text = Theme.of(context).textTheme;
    final at = _handleTime.toLocal();
    final header = Positioned(
      top: 0,
      right: right,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: _cancelled.value
                ? [
                    Text(
                      context.l10n.historyRailCancelled,
                      style: text.titleSmall?.copyWith(color: scheme.onSurface),
                    ),
                  ]
                : [
                    Text(
                      context.l10n.historyScrubberBubble(
                        _day!.format(at),
                        _time!.format(at),
                      ),
                      style: text.titleSmall?.copyWith(
                        color: scheme.onSurface,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.historyRailGoHere,
                      style: text.bodyMedium?.copyWith(color: scheme.primary),
                    ),
                    Text(
                      context.l10n.historyRailCancelHint,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
          ),
        ),
      ),
    );
    return Positioned.fill(
      child: IgnorePointer(
        child: Opacity(
          opacity: t,
          child: Stack(clipBehavior: Clip.none, children: [...labels, header]),
        ),
      ),
    );
  }

  /// Date and time, plus the stream title when one was live, pinned to the
  /// left of the thumb. At the top of a bar with older days past it, a hint
  /// at the month panel.
  Widget _bubble(BuildContext context, ColorScheme scheme) {
    final t = _activeCurve.value * (1 - _openCurve.value);
    if (t == 0) return const SizedBox.shrink();
    final pos = widget.thumb.value;
    final at = widget.scale.value.timeAt(pos).toLocal();
    final stream = widget.rail.streamAt(at);
    final older =
        _dragging.value &&
        pos < 0.05 &&
        HistoryScrubber.hasMonth(widget.rail) &&
        widget.scale.value.from.isAfter(widget.rail.from);
    final text = Theme.of(context).textTheme;
    const height = 56.0;
    return Positioned(
      top: (pos * _height - height / 2).clamp(-8.0, _height - height + 8),
      right: _width - _inset + 14,
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

/// Paints the bar and the month panel, crossfading by [open].
///
/// The bar is a waveform of message activity over its scale, dotted where
/// nothing was said, with stream spans in [stream]. The panel is one row per
/// day, its width the day's share of the busiest day. Both carry a grab
/// handle in [accent] and the old place marker.
class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.rail,
    required this.scale,
    required this.month,
    required this.thumb,
    required this.panelY,
    required this.oldPlace,
    required this.active,
    required this.open,
    required this.inPanel,
    required this.inset,
    required this.panelInset,
    required this.rowMin,
    required this.rowMax,
    required this.track,
    required this.accent,
    required this.glyph,
    required this.stream,
    required this.shadow,
  }) : super(
         repaint: Listenable.merge([
           thumb,
           scale,
           panelY,
           oldPlace,
           active,
           open,
         ]),
       );

  final ActivityRail rail;
  final ValueListenable<RailScale> scale;
  final _Month month;
  final ValueListenable<double> thumb;
  final ValueListenable<double> panelY;
  final ValueListenable<DateTime?> oldPlace;
  final Animation<double> active;
  final Animation<double> open;
  final bool Function() inPanel;
  final double inset;
  final double panelInset;
  final double rowMin;
  final double rowMax;
  final Color track;
  final Color accent;
  final Color glyph;
  final Color stream;
  final Color shadow;

  static const double _step = 2;
  static const double _dotStep = 6;

  /// Per-step counts over the bar, cached for one scale and height.
  RailScale? _wavesFor;
  double _wavesHeight = 0;
  List<int> _waves = const [];
  int _waveMax = 1;

  void _measure(RailScale s, double h) {
    if (identical(_wavesFor, s) && _wavesHeight == h) return;
    _wavesFor = s;
    _wavesHeight = h;
    final n = (h / _step).ceil();
    _waves = [
      for (var i = 0; i < n; i++)
        rail.countBetween(
          s.timeAt(i * _step / h),
          s.timeAt(((i + 1) * _step / h).clamp(0.0, 1.0)),
        ),
    ];
    _waveMax = math.max(1, _waves.fold<int>(0, math.max));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final o = open.value;
    final t = active.value;
    if (o < 1) _paintBar(canvas, size, t, 1 - o);
    if (o > 0) _paintPanel(canvas, size, o);
    _paintMarker(canvas, size, o);
    _paintHandle(canvas, size, t, o);
  }

  void _paintBar(Canvas canvas, Size size, double t, double alpha) {
    final s = scale.value;
    final h = size.height;
    final x = size.width - inset;
    _measure(s, h);
    final base = Paint()
      ..color = track.withValues(alpha: ui.lerpDouble(0.16, 0.26, t)! * alpha);
    final w0 = ui.lerpDouble(3, 4, t)!;
    var dotY = -_dotStep;
    for (var i = 0; i < _waves.length; i++) {
      final y = i * _step;
      final c = _waves[i];
      if (c == 0) {
        if (y - dotY >= _dotStep) {
          canvas.drawCircle(Offset(x, y + 1), w0 * 0.32, base);
          dotY = y;
        }
        continue;
      }
      final w = w0 + 6 * math.sqrt(c / _waveMax);
      canvas.drawRect(
        Rect.fromLTWH(x - w / 2, y, w, math.min(_step, h - y)),
        base,
      );
    }
    final live = Paint()
      ..color = stream.withValues(alpha: ui.lerpDouble(0.75, 1, t)! * alpha);
    for (final st in rail.streams) {
      if (!st.end.isAfter(s.from) || st.start.isAfter(s.to)) continue;
      final top = s.positionOf(st.start) * h;
      final bottom = s.positionOf(st.end) * h;
      if (bottom - top < 0.5) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(x - w0 / 2, top, x + w0 / 2, bottom),
          Radius.circular(w0 / 2),
        ),
        live,
      );
    }
  }

  void _paintPanel(Canvas canvas, Size size, double o) {
    final m = month;
    final right = size.width - panelInset;
    final busiest = math.max(
      1,
      m.days.fold<int>(0, (a, d) => math.max(a, d.count)),
    );
    final row = Paint()..color = track.withValues(alpha: 0.3 * o);
    final live = Paint()..color = stream.withValues(alpha: 0.85 * o);
    final pick = Paint()..color = accent.withValues(alpha: 0.35 * o);
    final pickY = panelY.value;
    final gap = math.min(2.0, m.dayH * 0.15);
    for (var i = 0; i < m.days.length; i++) {
      final d = m.days[i];
      final top = m.top + i * m.dayH;
      final w = (rowMin + (rowMax - rowMin) * d.count / busiest) * o;
      final rect = Rect.fromLTRB(
        right - w,
        top + gap / 2,
        right,
        top + m.dayH - gap / 2,
      );
      final rr = RRect.fromRectAndRadius(rect, const Radius.circular(4));
      canvas.drawRRect(rr, row);
      if (inPanel() && pickY >= top && pickY < top + m.dayH) {
        canvas.drawRRect(rr, pick);
      }
    }
    for (final st in rail.streams) {
      if (!st.end.isAfter(rail.from)) continue;
      final top = m.yOf(st.start);
      final bottom = m.yOf(st.end);
      if (bottom - top < 0.5) continue;
      canvas.drawRect(Rect.fromLTRB(right - 4 * o, top, right, bottom), live);
    }
  }

  void _paintMarker(Canvas canvas, Size size, double o) {
    final old = oldPlace.value;
    if (old == null) return;
    final double y;
    final double edge;
    if (o >= 0.5) {
      y = month.yOf(old);
      edge = size.width - panelInset - rowMax;
    } else {
      final s = scale.value;
      if (old.isBefore(s.from) || old.isAfter(s.to)) return;
      y = s.positionOf(old) * size.height;
      edge = size.width - inset - 8;
    }
    // A box with an arrow into the bar: where the list was.
    final p = Paint()
      ..color = track.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(edge - 16, y - 4, 8, 8),
        const Radius.circular(2),
      ),
      p,
    );
    canvas.drawPath(
      Path()
        ..moveTo(edge - 6, y - 4)
        ..lineTo(edge - 1, y)
        ..lineTo(edge - 6, y + 4)
        ..close(),
      p..style = PaintingStyle.fill,
    );
  }

  void _paintHandle(Canvas canvas, Size size, double t, double o) {
    final h = size.height;
    final barX = size.width - inset;
    final panelX = size.width - panelInset - rowMax / 2;
    final x = ui.lerpDouble(barX, panelX, o)!;
    final y = inPanel() ? panelY.value : thumb.value * h;
    final tw = ui.lerpDouble(20, 26, t)!;
    final th = ui.lerpDouble(44, 52, t)!;
    final cy = y.clamp(th / 2, h - th / 2);
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(x, cy), width: tw, height: th),
      Radius.circular(tw / 2),
    );
    if (t > 0) {
      canvas.drawShadow(
        Path()..addRRect(rect),
        shadow.withValues(alpha: t),
        3,
        false,
      );
    }
    canvas.drawRRect(rect, Paint()..color = accent);
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
      old.scale != scale ||
      old.month != month ||
      old.active != active ||
      old.open != open ||
      old.track != track ||
      old.accent != accent ||
      old.glyph != glyph ||
      old.stream != stream ||
      old.shadow != shadow;
}
