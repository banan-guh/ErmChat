enum EmoteType { twitch, bttv, ffz, sevenTv }

enum EmoteScope { global, channel }

/// Image resolution tier for emote fetching. 4x was dropped; no provider emits a 4x URL.
enum EmoteResolution {
  /// 1x for the low fetch tier (smallest available).
  low,

  /// 2x for medium/high; chat caches only ever store the 2x asset.
  medium,

  /// Adds an on-demand 3x asset (sheet/menu) on top of 2x.
  high,
}

/// url = active render URL. url1x/url3x = scale alternatives for the emote sheet and as cache-fallback placeholders. url3x only set when the provider has a true high-res asset (FFZ maps its 4x here since it lacks 3x).
class GenericEmote {
  final String id;
  final String code;
  final EmoteType type;
  final String url;

  /// 1x asset for cache fallbacks and resolution picker. Null if single-scale only.
  final String? url1x;

  /// 3x asset for emote sheet/picker. Null if no high-res available.
  final String? url3x;
  final bool isAnimated;
  final EmoteScope scope;
  final String? ownerChannel;

  /// Broadcaster id for sub emotes; used for grouping when ownerChannel is not yet resolved.
  final String? ownerId;
  final String? tier;
  final String? emoteType;
  final bool isZeroWidth;

  /// Unlisted 7TV emotes. Kept in cache; visibility filtered at read time by the allow-unlisted setting.
  final bool isUnlisted;

  /// 7TV alias: the original emote name when it differs from the top-level name.
  final String? baseName;
  final double relativeScale;
  final double aspectRatio;

  const GenericEmote({
    required this.id,
    required this.code,
    required this.type,
    required this.url,
    this.url1x,
    this.url3x,
    this.isAnimated = false,
    this.scope = EmoteScope.global,
    this.ownerChannel,
    this.ownerId,
    this.tier,
    this.emoteType,
    this.isZeroWidth = false,
    this.isUnlisted = false,
    this.baseName,
    this.relativeScale = 1.0,
    this.aspectRatio = 1.0,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'code': code,
    'type': type.name,
    'url': url,
    'url1x': url1x,
    'url3x': url3x,
    'isAnimated': isAnimated,
    'scope': scope.name,
    'ownerChannel': ownerChannel,
    'ownerId': ownerId,
    'tier': tier,
    'emoteType': emoteType,
    'isZeroWidth': isZeroWidth,
    'isUnlisted': isUnlisted,
    'baseName': baseName,
    'relativeScale': relativeScale,
    'aspectRatio': aspectRatio,
  };

  factory GenericEmote.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final code = json['code'];
    final url = json['url'];
    if (id is! String || code is! String || url is! String) {
      throw FormatException('Invalid emote json: $json');
    }
    return GenericEmote(
      id: id,
      code: code,
      type: _enumByName(EmoteType.values, json['type'], EmoteType.twitch),
      url: url,
      url1x: json['url1x'] as String?,
      // Recover legacy 'urlLarge' key so old cached emotes keep their 3x.
      url3x: (json['url3x'] ?? json['urlLarge']) as String?,
      isAnimated: json['isAnimated'] as bool? ?? false,
      scope: _enumByName(EmoteScope.values, json['scope'], EmoteScope.global),
      ownerChannel: json['ownerChannel'] as String?,
      ownerId: json['ownerId'] as String?,
      tier: json['tier'] as String?,
      emoteType: json['emoteType'] as String?,
      isZeroWidth: json['isZeroWidth'] as bool? ?? false,
      isUnlisted: json['isUnlisted'] as bool? ?? false,
      baseName: json['baseName'] as String?,
      relativeScale: (json['relativeScale'] as num?)?.toDouble() ?? 1.0,
      aspectRatio: (json['aspectRatio'] as num?)?.toDouble() ?? 1.0,
    );
  }

  static T _enumByName<T extends Enum>(
    List<T> values,
    Object? name,
    T fallback,
  ) {
    if (name is String) {
      for (final value in values) {
        if (value.name == name) return value;
      }
    }
    return fallback;
  }
}
