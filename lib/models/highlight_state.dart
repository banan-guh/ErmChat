import 'package:flutter/material.dart';

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

  HighlightType get primary {
    for (final t in _priority.reversed) {
      if (types.contains(t)) return t;
    }
    return types.first;
  }

  /// Row color: custom rule color wins, else per-type default. Blended against [surface] at [opacity].
  Color rowColor(Color surface, {double opacity = 1.0}) {
    opacity = opacity.clamp(0.0, 1.0);
    final isDark = surface.computeLuminance() < 0.5;
    final base =
        customColor ??
        switch (primary) {
          HighlightType.username ||
          HighlightType.reply ||
          HighlightType.user ||
          HighlightType.badge ||
          HighlightType.custom =>
            isDark ? const Color(0xFF8C3A3B) : const Color(0xFFCF5050),
          HighlightType.redemption =>
            isDark ? const Color(0xFF00606B) : const Color(0xFF458B93),
          HighlightType.elevated =>
            isDark ? const Color(0xFF6B5800) : const Color(0xFFB08D2A),
          HighlightType.firstMsg =>
            isDark ? const Color(0xFF3A6600) : const Color(0xFF558B2F),
        };
    return Color.alphaBlend(base.withValues(alpha: opacity), surface);
  }
}
