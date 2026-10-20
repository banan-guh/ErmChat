import 'dart:async';

import 'package:flutter/material.dart';
import 'design_tokens.dart';
import '../util/haptics.dart';

/// A switch with one stop per name, the first being off. Two stops act as a
/// plain switch. Once on, the track takes [color]. Tap a stop or drag to it;
/// with three or more, a bubble names the stop while it moves.
class LevelSwitch extends StatefulWidget {
  const LevelSwitch({
    super.key,
    required this.level,
    required this.names,
    required this.color,
    required this.onChanged,
    this.plainLevel,
    this.thumbIcon,
    this.blockedFrom,
    this.onBlocked,
  });

  final int level;

  /// The stops' names, off first.
  final List<String> names;
  final Color color;
  final ValueChanged<int> onChanged;

  /// A stop drawn on a neutral track instead of [color].
  final int? plainLevel;

  /// An icon inside the thumb at a stop, drawn in the track color.
  final Widget? Function(int level, Color color)? thumbIcon;

  /// Stops from here up need something else turned on first; picking one
  /// calls [onBlocked] instead.
  final int? blockedFrom;
  final VoidCallback? onBlocked;

  @override
  State<LevelSwitch> createState() => _LevelSwitchState();
}

class _LevelSwitchState extends State<LevelSwitch> {
  static const _height = 32.0;
  static const _pad = 4.0;
  static const _border = 2.0;
  static const _thumb = 24.0;
  static const _offThumb = 16.0;
  static const _duration = Motion.fast;

  final _bubble = OverlayPortalController();
  final _link = LayerLink();
  Timer? _hideBubble;

  // Whether this drag already reported a blocked stop.
  bool _blockedShown = false;

  int get _level => widget.level;
  int get _levels => widget.names.length;
  double get _width => 52 + 32.0 * (_levels - 2);

  String get _name => _nameOf(_level);

  String _nameOf(int level) => widget.names[level];

  @override
  void dispose() {
    _hideBubble?.cancel();
    super.dispose();
  }

  /// Shows the bubble on three-stop switches until [linger] after the last
  /// move; a null [linger] keeps it up (mid-drag).
  void _showBubble({Duration? linger = const Duration(milliseconds: 900)}) {
    if (_levels < 3) return;
    _hideBubble?.cancel();
    _bubble.show();
    if (linger != null) {
      _hideBubble = Timer(linger, () {
        if (mounted) _bubble.hide();
      });
    }
  }

  void _pick(int next, {bool dragging = false}) {
    next = next.clamp(0, _levels - 1);
    if (next == _level) return;
    final blockedFrom = widget.blockedFrom;
    if (blockedFrom != null &&
        next >= blockedFrom &&
        widget.onBlocked != null) {
      if (!dragging || !_blockedShown) widget.onBlocked!();
      _blockedShown = dragging;
      return;
    }
    Haptics.select();
    widget.onChanged(next);
    _showBubble(linger: dragging ? null : const Duration(milliseconds: 900));
  }

  int _stopAt(double dx) =>
      (dx / _width * _levels).floor().clamp(0, _levels - 1);

  /// Thumb center as a fraction of the track, for anchoring the bubble.
  static const _inset = _pad + _border + (_thumb - 4) / 2;

  double _thumbAlign(int level) {
    const inset = _inset;
    final travel = _width - 2 * inset;
    final x = inset + (_levels == 1 ? 0 : level / (_levels - 1) * travel);
    return x / _width * 2 - 1;
  }

  Widget _bubbleBuilder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Switches sit at the screen's right edge, so at the last stop the bubble
    // grows leftward from the switch's edge instead of centering.
    final last = _level == _levels - 1;
    final anchor = last ? Alignment.bottomRight : Alignment.bottomCenter;
    return CompositedTransformFollower(
      link: _link,
      targetAnchor: last
          ? Alignment.topRight
          : Alignment(_thumbAlign(_level), -1),
      followerAnchor: anchor,
      offset: const Offset(0, -2),
      child: Align(
        alignment: anchor,
        child: IgnorePointer(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: last
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.center,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.inverseSurface,
                  borderRadius: BorderRadius.circular(Radii.medium),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  child: Text(
                    _name,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onInverseSurface,
                    ),
                  ),
                ),
              ),
              Padding(
                // Keeps the point under the thumb when right-aligned.
                padding: EdgeInsets.only(right: last ? _inset - 5 : 0),
                child: CustomPaint(
                  size: const Size(10, 5),
                  painter: _TailPainter(scheme.inverseSurface),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plain = _level == widget.plainLevel;
    final color = plain ? scheme.surfaceContainerHighest : widget.color;
    final on = _level > 0;
    final onDark =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark;
    final thumbColor = !on
        ? scheme.outline
        : plain
        ? scheme.onSurfaceVariant
        : onDark
        ? Colors.white
        : Colors.black87;
    final thumbSize = on ? _thumb : _offThumb;
    final x = _levels == 1 ? 0.0 : _level / (_levels - 1) * 2 - 1;
    final three = _levels > 2;
    final top = _levels - 1;
    return Semantics(
      container: true,
      slider: three,
      toggled: three ? null : on,
      value: three ? _name : null,
      increasedValue: three && _level < top ? _nameOf(_level + 1) : null,
      decreasedValue: three && _level > 0 ? _nameOf(_level - 1) : null,
      onIncrease: three && _level < top ? () => _pick(_level + 1) : null,
      onDecrease: three && _level > 0 ? () => _pick(_level - 1) : null,
      onTap: three ? null : () => _pick(on ? 0 : 1),
      child: OverlayPortal(
        controller: _bubble,
        overlayChildBuilder: _bubbleBuilder,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Two stops toggle on any tap, like a plain switch.
          onTapUp: (d) =>
              _pick(three ? _stopAt(d.localPosition.dx) : (on ? 0 : 1)),
          onHorizontalDragStart: (_) {
            _blockedShown = false;
            _showBubble(linger: null);
          },
          onHorizontalDragUpdate: (d) =>
              _pick(_stopAt(d.localPosition.dx), dragging: true),
          onHorizontalDragEnd: (_) => _showBubble(),
          onHorizontalDragCancel: _showBubble,
          child: SizedBox(
            width: _width,
            height: 48,
            child: Center(
              child: CompositedTransformTarget(
                link: _link,
                child: AnimatedContainer(
                  duration: _duration,
                  width: _width,
                  height: _height,
                  padding: const EdgeInsets.all(_pad),
                  decoration: BoxDecoration(
                    color: on ? color : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(_height / 2),
                    border: Border.all(
                      color: on && !plain ? color : scheme.outline,
                      width: _border,
                    ),
                  ),
                  child: Stack(
                    children: [
                      // Dots mark the stops the thumb isn't on.
                      if (three)
                        for (var i = 0; i < _levels; i++)
                          if (i != _level)
                            Align(
                              alignment: Alignment(
                                i / (_levels - 1) * 2 - 1,
                                0,
                              ),
                              child: SizedBox(
                                width: _thumb - 4,
                                child: Center(
                                  child: Container(
                                    width: 4,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: thumbColor.withValues(alpha: 0.5),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                      AnimatedAlign(
                        duration: _duration,
                        curve: Motion.enter,
                        alignment: Alignment(x, 0),
                        child: SizedBox(
                          width: _thumb - 4,
                          height: _thumb - 4,
                          child: OverflowBox(
                            maxWidth: _thumb,
                            maxHeight: _thumb,
                            child: AnimatedContainer(
                              duration: _duration,
                              width: thumbSize,
                              height: thumbSize,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: thumbColor,
                              ),
                              child: widget.thumbIcon?.call(_level, color),
                            ),
                          ),
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
    );
  }
}

/// The bubble's downward point.
class _TailPainter extends CustomPainter {
  const _TailPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TailPainter old) => old.color != color;
}
