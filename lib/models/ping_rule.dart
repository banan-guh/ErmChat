import 'dart:convert';

/// Which list a highlight rule belongs to.
enum PingRuleKind { message, user, badge, blacklist }

/// Highlight rule, persisted as JSON in SharedPreferences (ping_rules_v1). Kinds: message (builtin+custom keywords), user, badge, blacklist.
class PingRule {
  final String id;
  final PingRuleKind kind;

  /// Builtin/custom type for message rules; unused for other kinds.
  final String type;
  final String pattern;
  final bool isRegex;
  final bool caseSensitive;

  /// Literal patterns match on word boundaries; ignored for regex.
  final bool wordBoundary;
  final bool enabled;
  final bool notify;
  final int? colorArgb;

  const PingRule({
    required this.id,
    required this.kind,
    this.type = 'custom',
    this.pattern = '',
    this.isRegex = false,
    this.caseSensitive = false,
    this.wordBoundary = false,
    this.enabled = true,
    this.notify = false,
    this.colorArgb,
  });

  PingRule copyWith({
    String? pattern,
    bool? isRegex,
    bool? caseSensitive,
    bool? wordBoundary,
    bool? enabled,
    bool? notify,
    int? colorArgb,
    bool clearColor = false,
  }) {
    return PingRule(
      id: id,
      kind: kind,
      type: type,
      pattern: pattern ?? this.pattern,
      isRegex: isRegex ?? this.isRegex,
      caseSensitive: caseSensitive ?? this.caseSensitive,
      wordBoundary: wordBoundary ?? this.wordBoundary,
      enabled: enabled ?? this.enabled,
      notify: notify ?? this.notify,
      colorArgb: clearColor ? null : (colorArgb ?? this.colorArgb),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    if (kind == PingRuleKind.message) 'type': type,
    'pattern': pattern,
    'isRegex': isRegex,
    'caseSensitive': caseSensitive,
    'wordBoundary': wordBoundary,
    'enabled': enabled,
    'notify': notify,
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
      isRegex: json['isRegex'] == true,
      caseSensitive: json['caseSensitive'] == true,
      wordBoundary: json['wordBoundary'] == true,
      enabled: json['enabled'] != false,
      notify: json['notify'] == true,
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
