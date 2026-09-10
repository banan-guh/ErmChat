import 'dart:ui' show Color;

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
}
