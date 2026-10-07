import 'dart:convert';

/// Which list a highlight rule belongs to.
enum PingRuleKind { message, user, badge, blacklist }

/// Highlight rule, persisted as JSON in SharedPreferences (ping_rules_v1). Kinds: message (builtin+custom keywords), user, badge, blacklist.
class PingRule {
  final String id;
  final PingRuleKind kind;

  /// Builtin/custom type for message rules; unused for other kinds.
  final String type;

  /// Plain text, matched case-insensitively.
  final String pattern;

  /// Keyword matches only as a whole word, not inside other words.
  final bool wordBoundary;
  final bool enabled;

  /// Keyword and user rules: false only tints, true also fills @mentions.
  final bool mention;
  final bool notify;

  /// Matches color the row; false notifies without tinting chat.
  final bool tint;
  final int? colorArgb;

  const PingRule({
    required this.id,
    required this.kind,
    this.type = 'custom',
    this.pattern = '',
    this.wordBoundary = false,
    this.enabled = true,
    this.mention = true,
    this.notify = false,
    this.tint = true,
    this.colorArgb,
  });

  PingRule copyWith({
    String? pattern,
    bool? wordBoundary,
    bool? enabled,
    bool? mention,
    bool? notify,
    bool? tint,
    int? colorArgb,
    bool clearColor = false,
  }) {
    return PingRule(
      id: id,
      kind: kind,
      type: type,
      pattern: pattern ?? this.pattern,
      wordBoundary: wordBoundary ?? this.wordBoundary,
      enabled: enabled ?? this.enabled,
      mention: mention ?? this.mention,
      notify: notify ?? this.notify,
      tint: tint ?? this.tint,
      colorArgb: clearColor ? null : (colorArgb ?? this.colorArgb),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    if (kind == PingRuleKind.message) 'type': type,
    'pattern': pattern,
    'wordBoundary': wordBoundary,
    'enabled': enabled,
    'mention': mention,
    'notify': notify,
    if (!tint) 'tint': false,
    if (colorArgb != null) 'color': colorArgb,
  };

  factory PingRule.fromJson(Map<String, dynamic> json) {
    return PingRule(
      id:
          json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      kind: PingRuleKind.values.firstWhere(
        (k) => k.name == json['kind'],
        orElse: () => PingRuleKind.message,
      ),
      type: json['type'] as String? ?? 'custom',
      pattern: json['pattern'] as String? ?? '',
      wordBoundary: json['wordBoundary'] == true,
      enabled: json['enabled'] != false,
      mention: json['mention'] != false,
      notify: json['notify'] == true,
      tint: json['tint'] != false,
      colorArgb: json['color'] is int ? json['color'] as int : null,
    );
  }
}

String encodeRules(List<PingRule> rules) =>
    jsonEncode([for (final r in rules) r.toJson()]);

List<PingRule> decodeRules(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return [
      for (final entry in decoded)
        if (entry is Map) PingRule.fromJson(Map<String, dynamic>.from(entry)),
    ];
  } catch (_) {
    return [];
  }
}
