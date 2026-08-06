enum EmoteType { twitch, bttv, ffz, sevenTv }

enum EmoteScope { global, channel }

class GenericEmote {
  final String id;
  final String code;
  final EmoteType type;
  final String url;
  final bool isAnimated;
  final EmoteScope scope;
  final String? ownerChannel;
  final String? tier;
  final String? emoteType;
  final bool isZeroWidth;

  /// For 7TV alias emotes: the name of the emote this one aliases
  /// (`data.name` when it differs from the top-level `name`).
  final String? baseName;
  final double relativeScale;
  final double aspectRatio;

  const GenericEmote({
    required this.id,
    required this.code,
    required this.type,
    required this.url,
    this.isAnimated = false,
    this.scope = EmoteScope.global,
    this.ownerChannel,
    this.tier,
    this.emoteType,
    this.isZeroWidth = false,
    this.baseName,
    this.relativeScale = 1.0,
    this.aspectRatio = 1.0,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'code': code,
    'type': type.name,
    'url': url,
    'isAnimated': isAnimated,
    'scope': scope.name,
    'ownerChannel': ownerChannel,
    'tier': tier,
    'emoteType': emoteType,
    'isZeroWidth': isZeroWidth,
    'baseName': baseName,
    'relativeScale': relativeScale,
    'aspectRatio': aspectRatio,
  };

  factory GenericEmote.fromJson(Map<String, dynamic> json) => GenericEmote(
    id: json['id'] as String,
    code: json['code'] as String,
    type: EmoteType.values.byName(json['type'] as String),
    url: json['url'] as String,
    isAnimated: json['isAnimated'] as bool? ?? false,
    scope: EmoteScope.values.byName(json['scope'] as String? ?? 'global'),
    ownerChannel: json['ownerChannel'] as String?,
    tier: json['tier'] as String?,
    emoteType: json['emoteType'] as String?,
    isZeroWidth: json['isZeroWidth'] as bool? ?? false,
    baseName: json['baseName'] as String?,
    relativeScale: (json['relativeScale'] as num?)?.toDouble() ?? 1.0,
    aspectRatio: (json['aspectRatio'] as num?)?.toDouble() ?? 1.0,
  );
}
