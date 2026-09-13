import 'emote.dart';

/// Twitch's status gate for an emote. Only [standard] emotes are word-matchable;
/// the rest render solely from the IRC `emotes` tag.
enum TwitchEmoteKind { standard, sub, follower, bits }

/// True subscription emotes, stored with the channel's Twitch list rather than
/// the provider stash or disk. Shared by every sub filter so they cannot drift.
bool isTwitchSub(Emote e) =>
    e.meta is TwitchMeta && (e.meta as TwitchMeta).kind == TwitchEmoteKind.sub;

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
