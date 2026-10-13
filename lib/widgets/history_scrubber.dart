import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
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

class _HistoryScrubberState extends State<HistoryScrubber> {
  static const double _width = 40;
  static const Duration _fade = Duration(milliseconds: 200);

  final ValueNotifier<bool> _dragging = ValueNotifier(false);
  double _height = 1;
  late final Listenable _bubbleSource = Listenable.merge([
    widget.thumb,
    widget.peek,
    _dragging,
  ]);
  DateFormat? _day;
  DateFormat? _time;
  String? _locale;

  @override
  void dispose() {
    _dragging.dispose();
    super.dispose();
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
            _height = box.maxHeight <= 0 ? 1 : box.maxHeight;
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
                        track: scheme.outline,
                        stream: scheme.primary,
                        handle: scheme.primary,
                        surface: scheme.surface,
                      ),
                    ),
                  ),
                  ListenableBuilder(
                    listenable: _bubbleSource,
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

  Widget _bubble(BuildContext context, ColorScheme scheme) {
    if (!_dragging.value && !widget.peek.value) return const SizedBox.shrink();
    final l10n = context.l10n;
    final pos = widget.thumb.value;
    final t = widget.rail.timeAt(pos).toLocal();
    final day = _day!.format(t);
    final time = _time!.format(t);
    final stream = widget.rail.streamAt(t);
    final text = stream == null
        ? l10n.historyScrubberBubble(day, time)
        : l10n.historyScrubberBubbleStream(day, stream.title, time);
    return Positioned(
      top: (pos * _height - 16).clamp(0.0, _height - 32),
      right: _width + 4,
      child: IgnorePointer(
        child: Material(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              text,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(fontSize: 13, color: scheme.onInverseSurface),
            ),
          ),
        ),
      ),
    );
  }
}

class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.rail,
    required this.thumb,
    required this.track,
    required this.stream,
    required this.handle,
    required this.surface,
  }) : super(repaint: thumb);

  final ActivityRail rail;
  final ValueNotifier<double> thumb;
  final Color track;
  final Color stream;
  final Color handle;
  final Color surface;

  static const double _trackWidth = 4;
  static const double _thumbHeight = 40;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width - 12;
    final h = size.height;
    final fill = Paint()..color = track.withValues(alpha: 0.55);
    final hollow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = track.withValues(alpha: 0.7);
    final live = Paint()..color = stream;
    Rect span(RailSpan s, double w) =>
        Rect.fromLTRB(x - w / 2, s.start * h, x + w / 2, s.end * h);

    // Filled track between the hollow gaps.
    var cursor = 0.0;
    for (final g in rail.gaps) {
      if (g.start > cursor) {
        canvas.drawRect(span(RailSpan(cursor, g.start), _trackWidth), fill);
      }
      canvas.drawRect(span(g, _trackWidth).deflate(0.5), hollow);
      cursor = g.end;
    }
    if (cursor < 1) {
      canvas.drawRect(span(RailSpan(cursor, 1), _trackWidth), fill);
    }
    for (final s in rail.streamSpans) {
      canvas.drawRect(span(s, _trackWidth + 3), live);
    }

    final cy = (thumb.value * h).clamp(_thumbHeight / 2, h - _thumbHeight / 2);
    final thumbRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(x, cy), width: 10, height: _thumbHeight),
      const Radius.circular(5),
    );
    canvas.drawRRect(
      thumbRect.inflate(1.5),
      Paint()..color = surface.withValues(alpha: 0.8),
    );
    canvas.drawRRect(thumbRect, Paint()..color = handle);
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.rail != rail ||
      old.track != track ||
      old.stream != stream ||
      old.handle != handle ||
      old.surface != surface;
}
