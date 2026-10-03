import 'package:flutter/material.dart';
import 'seven_tv_paint_service.dart';

/// Username filled with a gradient or image 7TV paint. Draws one paragraph
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
    final shader = service.shaderFor(paint, _measure(context));
    final style = shader == null
        ? baseStyle.copyWith(color: fallbackColor, shadows: shadows)
        : baseStyle.copyWith(
            foreground: Paint()..shader = shader,
            shadows: shadows,
          );
    return Text.rich(TextSpan(text: text, style: style));
  }

  /// The box [Text.rich] lays out to, so the shader spans the same bounds a
  /// ShaderMask would receive.
  Size _measure(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: DefaultTextStyle.of(context).style.merge(baseStyle),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final size = painter.size;
    painter.dispose();
    return size;
  }
}
