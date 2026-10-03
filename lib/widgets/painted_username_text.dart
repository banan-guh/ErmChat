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
    // lands.
    if (paint.layers.firstOrNull is SevenTvImagePaintLayer) {
      return ListenableBuilder(
        listenable: service.imageRevision,
        builder: (context, _) => _buildText(context),
      );
    }
    return _buildText(context);
  }

  Widget _buildText(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(baseStyle);
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final size = _measure(style, textDirection, textScaler);
    final shader = service.shaderFor(paint, size);
    final painted = shader == null
        ? style.copyWith(color: fallbackColor, shadows: shadows)
        : style.copyWith(
            foreground: Paint()..shader = shader,
            shadows: shadows,
          );
    // A paragraph paints at its parent offset without moving the canvas, so
    // a foreground shader would sit at the row origin and show only its end
    // stops. CustomPaint translates first, aligning the shader with the name.
    return Semantics(
      label: text,
      child: CustomPaint(
        size: size,
        painter: _NamePainter(
          TextSpan(text: text, style: painted),
          textDirection,
          textScaler,
        ),
      ),
    );
  }

  Size _measure(
    TextStyle style,
    TextDirection textDirection,
    TextScaler textScaler,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();
    final size = painter.size;
    painter.dispose();
    return size;
  }
}

class _NamePainter extends CustomPainter {
  _NamePainter(this.span, this.textDirection, this.textScaler);

  final TextSpan span;
  final TextDirection textDirection;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final painter = TextPainter(
      text: span,
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();
    painter.paint(canvas, Offset.zero);
    painter.dispose();
  }

  @override
  bool shouldRepaint(_NamePainter old) =>
      old.span != span ||
      old.textDirection != textDirection ||
      old.textScaler != textScaler;
}
