import 'package:flutter/material.dart';

/// What kind of highlight a message received. The first five are
/// mention-tier: they ping like a direct mention (unread counters, the
/// mentions tab, push notifications). Event types only tint the row.
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

  /// Row color override from the matching rule; null uses the default
  /// palette. The first colored rule encountered wins.
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

  /// Priority order among event types, lowest first. Mention-tier types sit
  /// above all of these, with [HighlightType.username] winning overall.
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

  /// Row background for this highlight: the rule's custom color wins, else
  /// the per-type default. Blends against [surface] so light/dark themes
  /// both land on readable tints.
  Color rowColor(Color surface) {
    if (customColor != null) return customColor!;
    final isDark = surface.computeLuminance() < 0.5;
    return switch (primary) {
      HighlightType.username ||
      HighlightType.reply ||
      HighlightType.user ||
      HighlightType.badge ||
      HighlightType.custom =>
        isDark ? const Color(0xFF773031) : const Color(0xFFEF9A9A),
      HighlightType.redemption => Color.alphaBlend(
        Colors.teal.withValues(alpha: 0.25),
        surface,
      ),
      HighlightType.elevated => Color.alphaBlend(
        Colors.amber.withValues(alpha: 0.30),
        surface,
      ),
      HighlightType.firstMsg => Color.alphaBlend(
        Colors.green.withValues(alpha: 0.2),
        surface,
      ),
    };
  }
}
