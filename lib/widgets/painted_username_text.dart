import 'package:flutter/material.dart';
import 'seven_tv_paint_service.dart';

/// Username filled with a gradient or image 7TV paint. Paints one paragraph
/// whose foreground carries the shader, so no ShaderMask layer and no
/// shadow underlay. Solid paints never reach here: they ride a TextSpan.
class PaintedUsernameText extends StatelessWidget {
  final SevenTvPaintService service;
  final SevenTvPaint paint;
  final String text;

  /// Font size/weight only; color comes from the paint or [fallbackColor].
  final TextStyle baseStyle;
  final Color fallbackColor;
  final List<Shadow>? shadows;

  const PaintedUsernameText({
    super.key,
    required this.service,
    required this.paint,
    required this.text,
    required this.baseStyle,
    required this.fallbackColor,
    this.shadows,
  });

  @override
  Widget build(BuildContext context) {
    // Image textures decode late; the service bumps a revision when one
    // lands. Animated ones then advance on the shared emote tick while the
    // row is on screen (TickerMode), as repaints of the name alone.
    if (paint.layers.firstOrNull is SevenTvImagePaintLayer) {
      return ListenableBuilder(
        listenable: service.imageRevision,
        builder: (context, _) => _buildText(
          context,
          TickerMode.valuesOf(context).enabled
              ? service.frameTicker(paint)
              : null,
        ),
      );
    }
    return _buildText(context, null);
  }

  Widget _buildText(BuildContext context, Listenable? ticker) {
    final style = DefaultTextStyle.of(context).style.merge(baseStyle);
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final size = _measure(style, textDirection, textScaler);
    // A paragraph paints at its parent offset without moving the canvas, so
    // a foreground shader would sit at the row origin and show only its end
    // stops. CustomPaint translates first, aligning the shader with the name.
    Widget name = CustomPaint(
      size: size,
      painter: _NamePainter(
        service: service,
        namePaint: paint,
        text: text,
        style: style,
        fallbackColor: fallbackColor,
        shadows: shadows,
        textDirection: textDirection,
        textScaler: textScaler,
        repaint: ticker,
      ),
    );
    // A frame change repaints this layer only, not the row around it.
    if (ticker != null) name = RepaintBoundary(child: name);
    return Semantics(label: text, child: name);
  }

  // Measured sizes by text, style and scaler: a texture revision rebuilds the
  // name but never changes its size.
  static final _sizes =
      <(String, TextStyle, TextDirection, TextScaler), Size>{};

  Size _measure(
    TextStyle style,
    TextDirection textDirection,
    TextScaler textScaler,
  ) {
    final key = (text, style, textDirection, textScaler);
    final known = _sizes[key];
    if (known != null) return known;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();
    final size = painter.size;
    painter.dispose();
    if (_sizes.length >= 512) _sizes.clear();
    return _sizes[key] = size;
  }
}

/// Paints the name with the paint's current shader, read at paint time so
/// an animated texture advances through [repaint] without a rebuild.
class _NamePainter extends CustomPainter {
  _NamePainter({
    required this.service,
    required this.namePaint,
    required this.text,
    required this.style,
    required this.fallbackColor,
    required this.shadows,
    required this.textDirection,
    required this.textScaler,
    super.repaint,
  });

  final SevenTvPaintService service;
  final SevenTvPaint namePaint;
  final String text;
  final TextStyle style;
  final Color fallbackColor;
  final List<Shadow>? shadows;
  final TextDirection textDirection;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final shader = service.shaderFor(namePaint, size);
    final painted = shader == null
        ? style.copyWith(color: fallbackColor, shadows: shadows)
        : style.copyWith(
            foreground: Paint()..shader = shader,
            shadows: shadows,
          );
    final painter = TextPainter(
      text: TextSpan(text: text, style: painted),
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();
    painter.paint(canvas, Offset.zero);
    painter.dispose();
  }

  @override
  bool shouldRepaint(_NamePainter old) =>
      old.namePaint != namePaint ||
      old.text != text ||
      old.style != style ||
      old.fallbackColor != fallbackColor ||
      old.shadows != shadows ||
      old.textDirection != textDirection ||
      old.textScaler != textScaler;
}
