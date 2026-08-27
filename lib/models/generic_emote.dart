enum EmoteType { twitch, bttv, ffz, sevenTv }

enum EmoteScope { global, channel }

/// Image-resolution tier for emote fetching. Only used when a fetch actually
/// happens (the `nothing` fetch tier never fetches at all). The 4x tier is
/// scrapped entirely: no provider ever emits a 4x URL.
enum EmoteResolution {
  /// 1x for the low fetch tier (smallest available).
  low,

  /// 2x for medium/high; chat caches only ever store the 2x asset.
  medium,

  /// Adds an on-demand 3x asset (sheet/menu) on top of 2x.
  high,
}

/// Note on the scale fields (`url1x`/`url3x`):
/// `url` is the active render URL (what chat/autocomplete render at ~28dp).
/// `url1x`/`url3x` are the scale alternatives used by the emote sheet/menu
/// resolution picker ("best scale still in cache") and as cached-fallback
/// placeholders while the required resolution is fetching. `url3x` is only set
/// where the provider has a true high-res asset (7TV/BTTV/Twitch 3x; FFZ maps
/// its largest 4x size here since it has no 3x).
class GenericEmote {
  final String id;
  final String code;
  final EmoteType type;
  final String url;

  /// Smallest-scale asset (1x) for cached-fallback placeholders and resolution
  /// pickers. Null when the provider only exposes a single scale.
  final String? url1x;

  /// Higher-resolution asset for larger render surfaces (emote sheet, picker
  /// grid). Null when the provider only exposes one tier or has no 3x.
  final String? url3x;
  final bool isAnimated;
  final EmoteScope scope;
  final String? ownerChannel;

  /// Stable broadcaster (owner) id for subscription emotes. Carried alongside
  /// the emote so grouping never collapses when [ownerChannel] (the resolved
  /// login) is still unknown — the manager groups by `ownerChannel ?? ownerId`.
  final String? ownerId;
  final String? tier;
  final String? emoteType;
  final bool isZeroWidth;

  /// 7TV emotes whose owner marked them unlisted. They are always parsed and
  /// kept in the caches; [EmoteManager] filters their visibility at read time
  /// so the "allow unlisted" setting flips instantly without a refetch.
  final bool isUnlisted;

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
      // Legacy caches (pre-scale-model) stored the high-res asset under
      // 'urlLarge'; recover it so old persisted emotes still upgrade in the
      // sheet instead of silently losing the 3x until a refetch.
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
