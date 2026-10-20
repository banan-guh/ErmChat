import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../l10n/l10n.dart';
import '../util/history_timeline.dart';
import 'glass_chrome.dart';

/// The days of a history list, opened from the menu's calendar: a full-height
/// drawer that slides in from the right edge over the whole app, one row per
/// day, oldest at the top and stacked from the bottom. A tapped day opens as
/// a chat-activity waveform over that day's time; a touch on it picks a
/// time, and letting go jumps there.
class HistoryDays extends StatefulWidget {
  const HistoryDays({
    super.key,
    required this.rail,
    required this.open,
    required this.viewTime,
    required this.onPick,
    required this.kept,
    required this.onLongPress,
    this.takeOpenTime,
    this.onStreams,
    this.glass = false,
  });

  /// Read on open: a time whose day opens straight away with the time
  /// marked, or null for the list.
  final DateTime? Function()? takeOpenTime;

  /// Opens the list of every stream; null hides its button.
  final VoidCallback? onStreams;

  final ActivityRail rail;

  /// Whether the days are out. The drawer dims everything under it and
  /// closes on a tap there.
  final ValueNotifier<bool> open;

  /// The list's time, whose day is highlighted.
  final DateTime? Function() viewTime;

  /// A picked time.
  final ValueChanged<DateTime> onPick;

  /// The day numbers kept past retention, marked on their rows.
  final ValueListenable<Set<int>> kept;

  /// A long press on the row of a day number.
  final ValueChanged<int> onLongPress;

  /// Liquid glass surface instead of an opaque one.
  final bool glass;

  /// Whether [rail] has days to pick from.
  static bool hasDays(ActivityRail rail) => rail.days.isNotEmpty;

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
  static const double _rowH = 56;

  /// Space above the open day's waveform (its date) and below it.
  static const double _header = 48;
  static const double _pad = 12;
  static const double _radius = 24;
  static const Duration _duration = Duration(milliseconds: 200);

  final OverlayPortalController _portal = OverlayPortalController();

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: _duration,
    value: widget.open.value ? 1 : 0,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _anim,
    curve: Curves.easeOutCubic,
  );

  /// 0 with the days listed, 1 with [_picked] shown.
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

  /// The open day's index and its scale, weighted by activity so busy
  /// stretches get room and quiet ones shrink.
  int? _picked;
  RailScale? _scale;
  _WavePainter? _wave;

  /// The touch on the open day's waveform, as a position 0..1.
  final ValueNotifier<double?> _touch = ValueNotifier(null);
  int _lastHour = -1;

  /// The drawer's width, and the waveform's top and height inside it, set at
  /// layout.
  double _drawerW = 0;
  double _barTop = 0;
  double _barH = 1;

  @override
  void initState() {
    super.initState();
    widget.open.addListener(_sync);
    widget.kept.addListener(_onKept);
    _anim.addStatusListener(_onAnim);
    // Built already open (the first calendar open of a channel builds its
    // rail first): open as a tap would, so a pending stream time lands.
    if (widget.open.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.open.value) _sync();
      });
    }
  }

  void _onKept() => setState(() {});

  void _onAnim(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _portal.isShowing) {
      _portal.hide();
    }
  }

  @override
  void didUpdateWidget(HistoryDays old) {
    super.didUpdateWidget(old);
    if (old.open != widget.open) {
      old.open.removeListener(_sync);
      widget.open.addListener(_sync);
      _sync();
    }
    if (old.rail != widget.rail) {
      // A rail rebuilt while a day is open keeps that day open.
      final picked = _picked;
      final day = picked == null ? null : old.rail.days[picked].day;
      final touch = _touch.value;
      final at = touch == null ? null : _scale?.timeAt(touch);
      _reset();
      final i = widget.rail.days.indexWhere((d) => d.day == day);
      if (i >= 0) {
        _pick(i);
        _expand.value = 1;
        if (at != null) _touch.value = _scale!.positionOf(at);
      }
    }
  }

  @override
  void dispose() {
    widget.open.removeListener(_sync);
    widget.kept.removeListener(_onKept);
    _anim.dispose();
    _expand.dispose();
    _wave?.dispose();
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
      if (!_portal.isShowing) _portal.show();
      _anim.forward();
      final time = widget.takeOpenTime?.call();
      final day = time == null ? null : dayNumber(widget.rail.local(time));
      final i = widget.rail.days.indexWhere((d) => d.day == day);
      if (i >= 0) {
        _open(i);
        _touch.value = _scale!.positionOf(time!);
      }
    } else {
      _anim.reverse();
    }
  }

  void _reset() {
    _picked = null;
    _scale = null;
    _wave?.dispose();
    _wave = null;
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
    setState(() => _pick(i));
    _expand.forward();
  }

  /// Makes [i] the open day, without rebuilding.
  void _pick(int i) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final scale = widget.rail.window(widget.rail.days[i].start, _endOf(i));
    _picked = i;
    _scale = scale;
    _wave = _WavePainter(
      rail: widget.rail,
      scale: scale,
      from: widget.rail.days[i].start,
      to: _endOf(i),
      touch: _touch,
      time: _time!,
      quiet: (d) => l10n.historyQuiet(
        d.inMinutes >= 90 ? '${d.inHours}h' : '${d.inMinutes}m',
      ),
      curve: scheme.primary.withValues(alpha: 0.5),
      tint: scheme.primary.withValues(alpha: 0.16),
      line: scheme.primary,
      muted: scheme.onSurfaceVariant.withValues(alpha: 0.7),
      labelStyle: (theme.textTheme.labelSmall ?? const TextStyle()).copyWith(
        color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
        fontSize: 10,
      ),
    );
  }

  void _onTouch(double y) {
    final p = ((y - _barTop) / _barH).clamp(0.0, 1.0);
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

  void _close() => widget.open.value = false;

  /// From the open day back to the list of days.
  void _back() {
    _touch.value = null;
    _expand.reverse().whenComplete(() {
      if (mounted && _picked != null && _expand.value == 0) {
        setState(_reset);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    if (_locale != locale) {
      _locale = locale;
      _dayLabel = DateFormat('MMM d', locale);
      _time = DateFormat.Hm(locale);
    }
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _overlay,
      child: const SizedBox.shrink(),
    );
  }

  /// The scrim over the whole app and the drawer on it. It lives in the
  /// navigator's overlay, so it dims the tab strip and the composer too.
  Widget _overlay(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inset = MediaQueryData.fromView(View.of(context)).padding;
    // System back steps out: the open day to the list, the list to chat.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _picked != null ? _back() : _close();
      },
      child: Material(
        type: MaterialType.transparency,
        child: LayoutBuilder(
          builder: (context, box) {
            _drawerW = math.min(
              box.maxWidth,
              (box.maxWidth * 0.45).clamp(200.0, 340.0),
            );
            _barTop = inset.top + _header;
            _barH = math.max(1, box.maxHeight - _barTop - inset.bottom - _pad);
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _curve,
                    builder: (context, _) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _close,
                      child: ColoredBox(
                        color: scheme.scrim.withValues(
                          alpha: 0.55 * _curve.value,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  width: _drawerW,
                  child: AnimatedBuilder(
                    animation: _curve,
                    builder: (context, child) => Transform.translate(
                      offset: Offset(
                        (_drawerW + _radius) * (1 - _curve.value),
                        0,
                      ),
                      child: child,
                    ),
                    child: AnimatedBuilder(
                      animation: _expandCurve,
                      builder: (context, _) => _drawer(scheme, inset),
                    ),
                  ),
                ),
                if (_picked != null) _bubble(scheme),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _drawer(ColorScheme scheme, EdgeInsets inset) {
    final t = _expandCurve.value;
    final picked = _picked;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: _surface(scheme)),
        if (t < 1)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: picked != null,
              child: Opacity(opacity: 1 - t, child: _list(scheme, inset)),
            ),
          ),
        if (picked != null) ...[
          Positioned(
            left: 0,
            right: 0,
            top: _barTop,
            height: _barH,
            child: Opacity(
              opacity: t,
              child: RepaintBoundary(
                child: CustomPaint(painter: _wave, size: Size.infinite),
              ),
            ),
          ),
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
          // Above the pick surface, so its back arrow takes the tap.
          Positioned(
            left: 4,
            right: 20,
            top: inset.top,
            height: _header,
            child: Opacity(
              opacity: t,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    onPressed: _back,
                  ),
                  Text(
                    _dayLabel!.format(
                      dayFromNumber(widget.rail.days[picked].day),
                    ),
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(color: scheme.onSurface),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// The days, newest at the bottom; scrolls when they do not fit.
  Widget _list(ColorScheme scheme, EdgeInsets inset) {
    final n = widget.rail.days.length;
    final onStreams = widget.onStreams;
    final days = ListView.builder(
      reverse: true,
      itemExtent: _rowH,
      itemCount: n,
      padding: EdgeInsets.fromLTRB(
        10,
        onStreams == null ? inset.top + 8 : 0,
        10,
        inset.bottom + 8,
      ),
      itemBuilder: (context, k) => _day(scheme, n - 1 - k),
    );
    if (onStreams == null) return days;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(10, inset.top + 4, 10, 4),
          child: TextButton.icon(
            onPressed: () {
              _close();
              onStreams();
            },
            icon: const Icon(Icons.video_library_outlined),
            label: Text(context.l10n.historyAllStreams),
          ),
        ),
        Expanded(child: days),
      ],
    );
  }

  /// A day's date as plain text on a rounded row; the list's day is tinted
  /// and a kept day carries a bookmark.
  Widget _day(ColorScheme scheme, int i) {
    final days = widget.rail.days;
    final on = days[i].day == _current;
    final kept = widget.kept.value.contains(days[i].day);
    final style = Theme.of(context).textTheme.bodyLarge;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: on ? scheme.primary.withValues(alpha: 0.16) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _picked == null ? () => _open(i) : null,
          onLongPress: _picked == null
              ? () => widget.onLongPress(days[i].day)
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _dayLabel!.format(dayFromNumber(days[i].day)),
                        style: style?.copyWith(
                          color: on ? scheme.primary : scheme.onSurface,
                          fontWeight: on ? FontWeight.w600 : null,
                        ),
                      ),
                      if (_streamsLine(i) case final line?)
                        Text(
                          line,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                if (kept)
                  Icon(
                    Icons.bookmark,
                    size: 18,
                    color: on ? scheme.primary : scheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The streams that ran on day [i]: one by its game (or title) and
  /// length, several by count and total length. Null on a day without one.
  String? _streamsLine(int i) {
    final from = widget.rail.days[i].start;
    final to = _endOf(i);
    final streams = [
      for (final s in widget.rail.streams)
        if (s.end.isAfter(from) && s.start.isBefore(to)) s,
    ];
    if (streams.isEmpty) return null;
    // Only the part on this day, so a stream across midnight (or one that
    // never ends) counts once.
    final length = formatStreamLength(
      streams.fold(
        Duration.zero,
        (sum, s) =>
            sum +
            (s.end.isBefore(to) ? s.end : to).difference(
              s.start.isAfter(from) ? s.start : from,
            ),
      ),
    );
    final l10n = context.l10n;
    if (streams.length > 1) {
      return l10n.historyDayStreams(streams.length, length);
    }
    final s = streams.single;
    final name = s.game.isNotEmpty ? s.game : s.title;
    return name.isEmpty ? length : l10n.historyDayStream(name, length);
  }

  /// The touched time, in a pill left of the drawer.
  Widget _bubble(ColorScheme scheme) => ValueListenableBuilder<double?>(
    valueListenable: _touch,
    builder: (context, p, _) {
      final scale = _scale;
      if (p == null || scale == null) return const SizedBox.shrink();
      final time = widget.rail.local(scale.timeAt(p));
      return Positioned(
        right: _drawerW + 8,
        top: _barTop + p * _barH - 14,
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
        minWidth: _drawerW + _radius,
        maxWidth: _drawerW + _radius,
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
        color: scheme.surfaceContainer,
        borderRadius: const BorderRadius.horizontal(
          left: Radius.circular(_radius),
        ),
      ),
    );
  }
}

/// An open day: chat activity as a filled curve on the right edge, growing
/// left with the message count, time running down by [scale]. Streams tint
/// the rows they cover, long quiet stretches fold into a dashed segment, and
/// times label where activity starts and stops. Geometry builds once per
/// size; painting only draws the cached paths and the touch line.
class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.rail,
    required this.scale,
    required this.from,
    required this.to,
    required this.touch,
    required this.time,
    required this.quiet,
    required this.curve,
    required this.tint,
    required this.line,
    required this.muted,
    required this.labelStyle,
  }) : super(repaint: touch);

  final ActivityRail rail;
  final RailScale scale;
  final DateTime from;
  final DateTime to;
  final ValueListenable<double?> touch;
  final DateFormat time;
  final String Function(Duration) quiet;
  final Color curve;
  final Color tint;
  final Color line;
  final Color muted;
  final TextStyle labelStyle;

  /// Room left of the curve's widest point for the time labels.
  static const double _gutter = 44;

  /// Empty time that folds into a dashed segment.
  static const Duration _quietMin = Duration(hours: 1);

  Size? _built;
  final Path _area = Path();
  final Path _tints = Path();
  final Path _dashes = Path();
  final List<(TextPainter, Offset)> _labels = [];
  late final Paint _fill = Paint()..color = curve;
  late final Paint _tintPaint = Paint()..color = tint;
  late final Paint _dashPaint = Paint()
    ..color = muted
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
  late final Paint _touchPaint = Paint()
    ..color = line
    ..strokeWidth = 2.5
    ..strokeCap = StrokeCap.round;

  void dispose() {
    _built = null;
    _clear();
  }

  void _clear() {
    _area.reset();
    _tints.reset();
    _dashes.reset();
    for (final (tp, _) in _labels) {
      tp.dispose();
    }
    _labels.clear();
  }

  void _build(Size size) {
    _built = size;
    _clear();
    final w = size.width;
    final h = size.height;
    final bucketMs = rail.bucket.inMilliseconds;
    final n = math.max(
      1,
      (to.difference(from).inMilliseconds / bucketMs).ceil(),
    );
    DateTime at(int k) {
      final t = from.add(Duration(milliseconds: k * bucketMs));
      return t.isAfter(to) ? to : t;
    }

    final counts = Float64List(n);
    for (var k = 0; k < n; k++) {
      counts[k] = rail.countBetween(at(k), at(k + 1)).toDouble();
    }
    // Quiet runs: empty buckets lasting at least [_quietMin].
    final minRun = math.max(2, _quietMin.inMilliseconds ~/ bucketMs);
    final quietRuns = <(int, int)>[];
    for (var k = 0; k < n;) {
      if (counts[k] != 0) {
        k++;
        continue;
      }
      var e = k;
      while (e < n && counts[e] == 0) {
        e++;
      }
      if (e - k >= minRun) quietRuns.add((k, e));
      k = e;
    }
    final smooth = Float64List(n);
    var max = 0.0;
    for (var k = 0; k < n; k++) {
      final a = counts[k > 0 ? k - 1 : k];
      final b = counts[k + 1 < n ? k + 1 : k];
      smooth[k] = (a + 2 * counts[k] + b) / 4;
    }
    for (final (a, b) in quietRuns) {
      for (var k = a; k < b; k++) {
        smooth[k] = 0;
      }
    }
    for (final v in smooth) {
      if (v > max) max = v;
    }
    final reach = math.max(1.0, w - _gutter - 4);
    double amp(int k) => max == 0 ? 0 : math.sqrt(smooth[k] / max) * reach;

    // Knots (y, x): x is the curve's reach from the right edge, y strictly
    // increasing.
    final ys = <double>[0];
    final xs = <double>[amp(0)];
    for (var k = 0; k < n; k++) {
      final mid = from.add(
        Duration(milliseconds: ((k + 0.5) * bucketMs).round()),
      );
      final y = scale.positionOf(mid.isAfter(to) ? to : mid) * h;
      if (y - ys.last < 0.5) continue;
      ys.add(y);
      xs.add(amp(k));
    }
    if (h - ys.last < 0.5) {
      ys[ys.length - 1] = h;
    } else {
      ys.add(h);
      xs.add(xs.last);
    }
    final m = ys.length;
    if (m > 1) {
      final d = List<double>.filled(m - 1, 0);
      for (var k = 0; k < m - 1; k++) {
        d[k] = (xs[k + 1] - xs[k]) / (ys[k + 1] - ys[k]);
      }
      // Monotone tangents, so the curve never overshoots its neighbours.
      final tan = List<double>.filled(m, 0);
      tan[0] = d[0];
      tan[m - 1] = d[m - 2];
      for (var k = 1; k < m - 1; k++) {
        final a = d[k - 1];
        final b = d[k];
        tan[k] = a * b <= 0 ? 0 : 2 * a * b / (a + b);
      }
      _area.moveTo(w, ys[0]);
      _area.lineTo(w - xs[0], ys[0]);
      for (var k = 0; k < m - 1; k++) {
        final dy = (ys[k + 1] - ys[k]) / 3;
        _area.cubicTo(
          w - (xs[k] + tan[k] * dy),
          ys[k] + dy,
          w - (xs[k + 1] - tan[k + 1] * dy),
          ys[k + 1] - dy,
          w - xs[k + 1],
          ys[k + 1],
        );
      }
      _area.lineTo(w, ys[m - 1]);
      _area.close();
    }

    for (final s in rail.streams) {
      if (!s.end.isAfter(from) || !s.start.isBefore(to)) continue;
      final y0 = scale.positionOf(s.start) * h;
      final y1 = scale.positionOf(s.end) * h;
      if (y1 - y0 >= 1) _tints.addRect(Rect.fromLTRB(0, y0, w, y1));
    }

    // Quiet stretches: a dashed segment with end caps and its length.
    final dashX = w - 10;
    for (final (a, b) in quietRuns) {
      final y0 = scale.positionOf(at(a)) * h;
      final y1 = scale.positionOf(at(b)) * h;
      for (var y = y0; y < y1; y += 8) {
        _dashes.moveTo(dashX, y);
        _dashes.lineTo(dashX, math.min(y + 4, y1));
      }
      _dashes.moveTo(dashX - 4, y0);
      _dashes.lineTo(dashX + 4, y0);
      _dashes.moveTo(dashX - 4, y1);
      _dashes.lineTo(dashX + 4, y1);
      final tp = _text(quiet(at(b).difference(at(a))));
      if (y1 - y0 >= tp.height + 2) {
        _labels.add((
          tp,
          Offset(dashX - 10 - tp.width, (y0 + y1 - tp.height) / 2),
        ));
      } else {
        tp.dispose();
      }
    }

    // Times at the edges of each active stretch, skipping any that would
    // touch the label above.
    var lastBottom = -4.0;
    void edge(int bucket, bool start) {
      final tp = _text(time.format(rail.local(at(bucket))));
      final y = scale.positionOf(at(bucket)) * h;
      final top = (start ? y : y - tp.height)
          .clamp(0.0, math.max(0.0, h - tp.height))
          .toDouble();
      if (top < lastBottom + 2) {
        tp.dispose();
        return;
      }
      lastBottom = top + tp.height;
      _labels.add((tp, Offset(8, top)));
    }

    var active = 0;
    for (final (a, b) in [...quietRuns, (n, n)]) {
      if (a > active) {
        edge(active, true);
        edge(a, false);
      }
      active = b;
    }
  }

  TextPainter _text(String s) => TextPainter(
    text: TextSpan(text: s, style: labelStyle),
    textDirection: ui.TextDirection.ltr,
    maxLines: 1,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    if (_built != size) _build(size);
    canvas.drawPath(_tints, _tintPaint);
    canvas.drawPath(_area, _fill);
    canvas.drawPath(_dashes, _dashPaint);
    for (final (tp, offset) in _labels) {
      tp.paint(canvas, offset);
    }
    final p = touch.value;
    if (p != null) {
      final y = p * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), _touchPaint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => !identical(old, this);
}
