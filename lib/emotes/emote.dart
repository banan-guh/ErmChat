enum EmoteType { twitch, bttv, ffz, sevenTv }

enum EmoteScope { global, channel, personal }

/// Quality role an emote image is fetched at. Providers map their native
/// scales onto these roles; [large] is the provider's maximum (7TV's 4x).
enum EmoteScale { small, medium, large }

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

/// [scales] holds the render URL per quality role. Providers fill every role
/// their API exposes, independent of the fetch tier; the render layer picks.
class Emote {
  final String id;
  final String code;
  final EmoteScope scope;

  /// Image URL per quality role. Only scales the provider has are present.
  final Map<EmoteScale, String> scales;
  final bool isAnimated;

  /// Overlay emote composited over the preceding base emote.
  final bool isZeroWidth;
  final EmoteMeta meta;

  const Emote({
    required this.id,
    required this.code,
    required this.meta,
    required this.scales,
    this.scope = EmoteScope.global,
    this.isAnimated = false,
    this.isZeroWidth = false,
  });

  /// URL for [scale], or null when the provider lacks it.
  String? urlFor(EmoteScale scale) => scales[scale];

  EmoteType get type => meta.type;

  Emote copyWith({String? code, EmoteScope? scope}) => Emote(
    id: id,
    code: code ?? this.code,
    meta: meta,
    scales: scales,
    scope: scope ?? this.scope,
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
    'scales': {for (final entry in scales.entries) entry.key.name: entry.value},
    'isAnimated': isAnimated,
    'isZeroWidth': isZeroWidth,
    'meta': meta.toJson(),
  };

  factory Emote.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final code = json['code'];
    if (id is! String || code is! String) {
      throw FormatException('Invalid emote json: $json');
    }
    final meta = json['meta'];
    return Emote(
      id: id,
      code: code,
      scales: _decodeScales(json['scales']),
      scope: enumByName(EmoteScope.values, json['scope'], EmoteScope.global),
      isAnimated: json['isAnimated'] as bool? ?? false,
      isZeroWidth: json['isZeroWidth'] as bool? ?? false,
      meta: meta is Map<String, dynamic>
          ? EmoteMeta.fromJson(meta)
          : const BttvMeta(),
    );
  }

  static Map<EmoteScale, String> _decodeScales(Object? raw) {
    final out = <EmoteScale, String>{};
    if (raw is! Map) return out;
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! String || value.isEmpty) continue;
      for (final scale in EmoteScale.values) {
        if (scale.name == entry.key) {
          out[scale] = value;
          break;
        }
      }
    }
    return out;
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
