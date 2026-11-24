import 'package:flutter/material.dart';
import 'seven_tv_paint_service.dart';

/// Shadows are immutable and catalog paints are shared, so one list per paint
/// serves every name wearing it. The expando drops it with the paint.
final Expando<List<Shadow>> _shadowCache = Expando<List<Shadow>>();

/// Flutter text shadows for [paint], reversed so the API's first shadow sits
/// on top as CSS draws it. Parallel draws skip the chain's outer halo growth.
/// The returned list is shared, so callers must not mutate it.
List<Shadow> paintTextShadows(SevenTvPaint paint) {
  final cached = _shadowCache[paint];
  if (cached != null) return cached;
  return _shadowCache[paint] = [
    for (final shadow in paint.shadows.reversed)
      Shadow(
        color: shadow.color,
        offset: Offset(shadow.offsetX, shadow.offsetY),
        blurRadius: _flutterBlur(shadow.blur),
      ),
  ];
}

/// CSS drop-shadow blur radius -> Flutter [Shadow.blurRadius] with the same
/// Gaussian sigma (CSS uses radius/2, Flutter radius*0.57735+0.5).
double _flutterBlur(double radius) =>
    radius <= 1 ? 0 : (radius - 1) * 0.8660254037844386;

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

  /// Name color under transparent fills, 7TV's background-color: currentColor.
  final Color baseColor;

  const PaintedUsernameText({
    super.key,
    required this.service,
    required this.paint,
    required this.text,
    required this.baseStyle,
    required this.fallbackColor,
    required this.baseColor,
  });

  @override
  Widget build(BuildContext context) {
    // The texture tick repaints the name alone while the row is on screen.
    // Its first frame lands on that same tick, so no rebuild is needed.
    return _buildText(
      context,
      TickerMode.valuesOf(context).enabled ? service.frameTicker(paint) : null,
    );
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
        baseColor: baseColor,
        shadows: paintTextShadows(paint),
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
    required this.baseColor,
    required this.shadows,
    required this.textDirection,
    required this.textScaler,
    super.repaint,
  }) : _animated = namePaint.layers.firstOrNull is SevenTvImagePaintLayer;

  final SevenTvPaintService service;
  final SevenTvPaint namePaint;
  final String text;
  final TextStyle style;
  final Color fallbackColor;
  final Color baseColor;
  final List<Shadow> shadows;
  final TextDirection textDirection;
  final TextScaler textScaler;

  /// Only image paints advance a shader on the ticker. Other shaders depend
  /// solely on the paint and size, both fixed for this painter's lifetime.
  final bool _animated;

  Paint? _foreground;
  TextStyle? _fallbackStyle;
  TextStyle? _shaderStyle;
  TextSpan? _fallbackSpan;
  TextSpan? _shaderSpan;
  Shader? _staticShader;
  Size? _shaderSize;

  @override
  void paint(Canvas canvas, Size size) {
    final Shader? shader;
    if (_animated || _shaderSize != size) {
      shader = service.shaderFor(namePaint, size);
      if (!_animated) {
        _staticShader = shader;
        _shaderSize = size;
      }
    } else {
      shader = _staticShader;
    }

    final TextSpan span;
    if (shader == null) {
      span = _fallbackSpan ??= TextSpan(
        text: text,
        style: _fallbackStyle ??= style.copyWith(
          color: fallbackColor,
          shadows: shadows.isEmpty ? null : shadows,
        ),
      );
    } else {
      final foreground = _foreground ??= Paint()
        // Texture and gradient alpha shows the name color, matching 7TV's
        // background-color under the layer fill.
        ..colorFilter = ColorFilter.mode(baseColor, BlendMode.dstOver);
      foreground.shader = shader;
      span = _shaderSpan ??= TextSpan(
        text: text,
        style: _shaderStyle ??= style.copyWith(
          foreground: foreground,
          shadows: shadows.isEmpty ? null : shadows,
        ),
      );
    }
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
      old.namePaint != namePaint ||
      old.text != text ||
      old.style != style ||
      old.fallbackColor != fallbackColor ||
      old.baseColor != baseColor ||
      old.textDirection != textDirection ||
      old.textScaler != textScaler;
}
