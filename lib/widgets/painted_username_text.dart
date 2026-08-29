import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../services/seven_tv_paint_service.dart';

/// Username with 7TV paint fill. Listens for late resolution. Shadows render as separate underlay.
class PaintedUsernameText extends StatelessWidget {
  final SevenTvPaintService service;
  final String? userId;
  final String text;
  final TextStyle baseStyle;
  final GestureRecognizer? recognizer;

  const PaintedUsernameText({
    super.key,
    required this.service,
    required this.userId,
    required this.text,
    required this.baseStyle,
    this.recognizer,
  });

  @override
  Widget build(BuildContext context) {
    if (userId == null) return _buildText(baseStyle);
    final notifier = service.lookupNotifier(userId);
    return ListenableBuilder(
      listenable: notifier,
      builder: (_, _) {
    // Lookup triggers batched fetch for unknown users.
        final paint = notifier.value ?? service.lookup(userId);
        if (paint == null || paint.layers.isEmpty) {
          return _buildText(baseStyle);
        }

        final solid = paint.solidColor;
        final shadows = [
          for (final shadow in paint.shadows)
            Shadow(
              color: shadow.color,
              offset: Offset(shadow.offsetX, shadow.offsetY),
              blurRadius: shadow.blur * 3,
            ),
        ];

        if (solid != null && shadows.isEmpty) {
          return _buildText(baseStyle.copyWith(color: solid));
        }
        if (solid != null) {
          return Stack(
            clipBehavior: Clip.none,
            children: [
              _buildText(
                baseStyle.copyWith(color: solid.withValues(alpha: 0)),
                shadows: shadows,
              ),
              _masked(paint, baseStyle.copyWith(color: solid)),
            ],
          );
        }

        final fallback =
            paint.fallbackColor ?? baseStyle.color ?? const Color(0xFF808080);
        // Underlay for shadows; masked overlay for gradient.
        return Stack(
          clipBehavior: Clip.none,
          children: [
            _buildText(baseStyle.copyWith(color: fallback), shadows: shadows),
            _masked(paint, baseStyle.copyWith(color: fallback)),
          ],
        );
      },
    );
  }

  Widget _masked(SevenTvPaint paint, TextStyle style) {
    return ShaderMask(
      shaderCallback: (bounds) {
        final shader = service.shaderFor(paint, bounds.size);
        // Empty gradient hides overlay until image textures decode.
        return shader ??
            ui.Gradient.linear(Offset.zero, Offset.zero, [
              const Color(0x00000000),
              const Color(0x00000000),
            ]);
      },
      blendMode: BlendMode.srcIn,
      child: _buildText(style),
    );
  }

  Widget _buildText(TextStyle style, {List<Shadow>? shadows}) {
    return Text.rich(
      TextSpan(
        text: text,
        style: shadows == null ? style : style.copyWith(shadows: shadows),
        recognizer: recognizer,
      ),
    );
  }
}
