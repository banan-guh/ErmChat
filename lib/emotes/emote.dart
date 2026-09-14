enum EmoteType { twitch, bttv, ffz, sevenTv }

enum EmoteScope { global, channel, personal }

/// Image resolution tier for emote fetching. There is no 4x tier: providers
/// expose at most a 3x slot, and FFZ's 4x asset is carried in [Emote.url3x].
enum EmoteResolution {
  /// 1x for the low fetch tier (smallest available).
  low,

  /// 2x for medium/high; chat caches only ever store the 2x asset.
  medium,

  /// Adds an on-demand 3x asset (sheet/menu) on top of 2x.
  high,
}

/// First enum value matching [name], or [fallback] when absent/unknown.
T enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  if (name is String) {
    for (final value in values) {
      if (value.name == name) return value;
    }
  }
  return fallback;
}

/// One token from [EmoteManager.tokenize]: either an emote or plain text.
class EmoteToken {
  final Emote? emote;
  final String text;
  final int start;
  final int end;

  const EmoteToken({
    this.emote,
    required this.text,
    required this.start,
    required this.end,
  });

  bool get isEmote => emote != null;
}

/// url = active render URL. url1x/url3x = scale alternatives for the emote sheet and as cache-fallback placeholders. url3x only set when the provider has a true high-res asset (FFZ maps its 4x here since it lacks 3x).
class Emote {
  final String id;
  final String code;
  final EmoteScope scope;
  final String url;

  /// 1x asset for cache fallbacks and resolution picker. Null if single-scale only.
  final String? url1x;

  /// 3x asset for emote sheet/picker. Null if no high-res available.
  final String? url3x;
  final bool isAnimated;

  /// Overlay emote composited over the preceding base emote.
  final bool isZeroWidth;
  final EmoteMeta meta;

  const Emote({
    required this.id,
    required this.code,
    required this.meta,
    required this.url,
    this.scope = EmoteScope.global,
    this.url1x,
    this.url3x,
    this.isAnimated = false,
    this.isZeroWidth = false,
  });

  EmoteType get type => meta.type;

  Emote copyWith({String? code, EmoteScope? scope}) => Emote(
    id: id,
    code: code ?? this.code,
    meta: meta,
    url: url,
    scope: scope ?? this.scope,
    url1x: url1x,
    url3x: url3x,
    isAnimated: isAnimated,
    isZeroWidth: isZeroWidth,
  );

  /// 7TV alias name, or null for every other provider.
  String? get baseName => switch (meta) {
    SevenTvMeta m => m.baseName,
    _ => null,
  };

  /// 7TV vertical scale, 1.0 for every other provider.
  double get relativeScale => switch (meta) {
    SevenTvMeta m => m.relativeScale,
    _ => 1.0,
  };

  /// 7TV width/height ratio, 1.0 for every other provider.
  double get aspectRatio => switch (meta) {
    SevenTvMeta m => m.aspectRatio,
    _ => 1.0,
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'code': code,
    'scope': scope.name,
    'url': url,
    'url1x': url1x,
    'url3x': url3x,
    'isAnimated': isAnimated,
    'isZeroWidth': isZeroWidth,
    'meta': meta.toJson(),
  };

  factory Emote.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final code = json['code'];
    final url = json['url'];
    if (id is! String || code is! String || url is! String) {
      throw FormatException('Invalid emote json: $json');
    }
    final meta = json['meta'];
    return Emote(
      id: id,
      code: code,
      url: url,
      scope: enumByName(EmoteScope.values, json['scope'], EmoteScope.global),
      url1x: json['url1x'] as String?,
      url3x: json['url3x'] as String?,
      isAnimated: json['isAnimated'] as bool? ?? false,
      isZeroWidth: json['isZeroWidth'] as bool? ?? false,
      meta: meta is Map<String, dynamic>
          ? EmoteMeta.fromJson(meta)
          : const BttvMeta(),
    );
  }
}

/// Twitch's status gate for an emote. Only [standard] emotes are word-matchable;
/// the rest render solely from the IRC `emotes` tag.
enum TwitchEmoteKind { standard, sub, follower, bits }

/// True subscription emotes, stored with the channel's Twitch list rather than
/// the channel's provider lists or disk. Shared by every sub filter so they
/// cannot drift.
bool isTwitchSub(Emote e) => switch (e.meta) {
  TwitchMeta(kind: TwitchEmoteKind.sub) => true,
  _ => false,
};

/// Provider-specific facts for an [Emote]. [type] identifies the provider;
/// [owner] is the display name of the creator when one is known.
sealed class EmoteMeta {
  const EmoteMeta();

  EmoteType get type;

  String? get owner;

  Map<String, dynamic> toJson();

  static EmoteMeta fromJson(Map<String, dynamic> json) {
    final type = enumByName(EmoteType.values, json['type'], EmoteType.twitch);
    return switch (type) {
      EmoteType.twitch => TwitchMeta(
        kind: enumByName(
          TwitchEmoteKind.values,
          json['kind'],
          TwitchEmoteKind.standard,
        ),
        subTier: (json['subTier'] as num?)?.toInt(),
        ownerChannel: json['ownerChannel'] as String?,
        ownerId: json['ownerId'] as String?,
      ),
      EmoteType.bttv => const BttvMeta(),
      EmoteType.ffz => FfzMeta(ownerChannel: json['ownerChannel'] as String?),
      EmoteType.sevenTv => SevenTvMeta(
        creator: json['creator'] as String?,
        baseName: json['baseName'] as String?,
        unlisted: json['unlisted'] as bool? ?? false,
        relativeScale: (json['relativeScale'] as num?)?.toDouble() ?? 1.0,
        aspectRatio: (json['aspectRatio'] as num?)?.toDouble() ?? 1.0,
      ),
    };
  }
}

final class TwitchMeta extends EmoteMeta {
  const TwitchMeta({
    required this.kind,
    this.subTier,
    this.ownerChannel,
    this.ownerId,
  });

  final TwitchEmoteKind kind;

  /// Parsed from the API `tier` string; null when absent or unparseable.
  final int? subTier;

  /// Channel display name for channel emotes.
  final String? ownerChannel;

  /// Broadcaster id for sub emotes, used for grouping until the login resolves.
  final String? ownerId;

  @override
  EmoteType get type => EmoteType.twitch;

  @override
  String? get owner => ownerChannel;

  @override
  Map<String, dynamic> toJson() => {
    'type': type.name,
    'kind': kind.name,
    'subTier': subTier,
    'ownerChannel': ownerChannel,
    'ownerId': ownerId,
  };
}

final class BttvMeta extends EmoteMeta {
  const BttvMeta();

  @override
  EmoteType get type => EmoteType.bttv;

  @override
  String? get owner => null;

  @override
  Map<String, dynamic> toJson() => {'type': type.name};
}

final class FfzMeta extends EmoteMeta {
  const FfzMeta({this.ownerChannel});

  /// FFZ creator display name for channel emotes; null for globals.
  final String? ownerChannel;

  @override
  EmoteType get type => EmoteType.ffz;

  @override
  String? get owner => ownerChannel;

  @override
  Map<String, dynamic> toJson() => {
    'type': type.name,
    'ownerChannel': ownerChannel,
  };
}

final class SevenTvMeta extends EmoteMeta {
  const SevenTvMeta({
    this.creator,
    this.baseName,
    this.unlisted = false,
    this.relativeScale = 1.0,
    this.aspectRatio = 1.0,
  });

  final String? creator;

  /// Original emote name when the top-level code is an alias.
  final String? baseName;

  /// Unlisted emotes stay cached; visibility is filtered at read time.
  final bool unlisted;
  final double relativeScale;
  final double aspectRatio;

  @override
  EmoteType get type => EmoteType.sevenTv;

  @override
  String? get owner => creator;

  @override
  Map<String, dynamic> toJson() => {
    'type': type.name,
    'creator': creator,
    'baseName': baseName,
    'unlisted': unlisted,
    'relativeScale': relativeScale,
    'aspectRatio': aspectRatio,
  };
}
