import 'package:flutter/material.dart';

import '../color_utils.dart';

/// Highlight type. First five are mention-tier (count toward unread/push); rest only tint the row.
enum HighlightType {
  username,
  reply,
  custom,
  user,
  badge,
  redemption,
  firstMsg,
  elevated,
}

/// Immutable highlight result attached to a message by the ping engine.
class HighlightState {
  final Set<HighlightType> types;

  /// Custom row color from the matching rule; null = default palette.
  final Color? customColor;

  /// Whether any matching rule asked for a system notification.
  final bool notify;

  const HighlightState({
    required this.types,
    this.customColor,
    this.notify = false,
  });

  static const _mentionTypes = {
    HighlightType.username,
    HighlightType.reply,
    HighlightType.custom,
    HighlightType.user,
    HighlightType.badge,
  };

  bool get hasMention => types.any(_mentionTypes.contains);

  /// Priority order, lowest first. Mention-tier types always rank above these.
  static const _priority = [
    HighlightType.firstMsg,
    HighlightType.redemption,
    HighlightType.elevated,
    HighlightType.badge,
    HighlightType.user,
    HighlightType.custom,
    HighlightType.reply,
    HighlightType.username,
  ];

  // Per-theme base palette lives in color_utils (highlightPaletteDark/Light);
  // the contrast anchor there is the most-vivid built-in so equalization never
  // dulls a highlight below its natural prominence.

  HighlightType get primary {
    for (final t in _priority.reversed) {
      if (types.contains(t)) return t;
    }
    return types.first;
  }

  /// Row color: custom rule color wins, else per-type default. Every base is
  /// lightness-normalized to the vivid anchor so the blended result has the
  /// same perceived contrast against [surface] at any [opacity].
  Color rowColor(Color surface, {double opacity = 1.0}) {
    opacity = opacity.clamp(0.0, 1.0);
    final isDark = surface.computeLuminance() < 0.5;
    final palette = isDark ? highlightPaletteDark : highlightPaletteLight;
    final anchor = highlightAnchor(surface);
    final base =
        customColor ??
        switch (primary) {
          HighlightType.username ||
          HighlightType.reply ||
          HighlightType.user ||
          HighlightType.badge ||
          HighlightType.custom => palette[0],
          HighlightType.redemption => palette[1],
          HighlightType.elevated => palette[2],
          HighlightType.firstMsg => palette[3],
        };
    final tint = matchTintContrast(base, surface, anchor);
    return Color.alphaBlend(tint.withValues(alpha: opacity), surface);
  }
}
