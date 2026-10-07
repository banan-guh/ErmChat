import 'dart:ui' show Color;

/// Highlight type. First four are mention-tier (count toward unread/push); rest only tint the row.
enum HighlightType {
  username,
  reply,
  custom,
  user,
  badge,

  /// A keyword or user rule set to tint only.
  tint,
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

  /// The [types] whose rules color the row; null means all of them. Empty
  /// when every match notifies without tinting.
  final Set<HighlightType>? tinting;

  const HighlightState({
    required this.types,
    this.customColor,
    this.notify = false,
    this.tinting,
  });

  bool get tinted => (tinting ?? types).isNotEmpty;

  static const _mentionTypes = {
    HighlightType.username,
    HighlightType.reply,
    HighlightType.custom,
    HighlightType.user,
  };

  bool get hasMention => types.any(_mentionTypes.contains);

  /// Priority order, lowest first: user rules, then chat events, then
  /// mentions of you.
  static const _priority = [
    HighlightType.tint,
    HighlightType.badge,
    HighlightType.user,
    HighlightType.custom,
    HighlightType.firstMsg,
    HighlightType.redemption,
    HighlightType.elevated,
    HighlightType.reply,
    HighlightType.username,
  ];

  HighlightType get primary => _primaryOf(types);

  /// The type whose palette entry colors the row.
  HighlightType get tintPrimary => _primaryOf(tinting ?? types);

  static HighlightType _primaryOf(Set<HighlightType> types) {
    for (final t in _priority.reversed) {
      if (types.contains(t)) return t;
    }
    return types.first;
  }
}
