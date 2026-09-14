import 'package:ermchat/emotes/emote.dart';

/// Twitch render status from the API tier/emote_type pair, mirroring the
/// provider mapping.
TwitchEmoteKind twitchKindOf(String? tier, String? emoteType) {
  if (tier != null || emoteType == 'subscriptions') {
    return TwitchEmoteKind.sub;
  }
  if (emoteType == 'follower') return TwitchEmoteKind.follower;
  if (emoteType == 'bitstier') return TwitchEmoteKind.bits;
  return TwitchEmoteKind.standard;
}

Emote makeTestEmote({
  required String id,
  required String code,
  EmoteType type = EmoteType.bttv,
  bool isZeroWidth = false,
  bool isUnlisted = false,
  EmoteScope scope = EmoteScope.global,
  String? ownerChannel,
  String? ownerId,
  String? tier,
  String? emoteType,
  String? baseName,
  double relativeScale = 1.0,
}) => Emote(
  id: id,
  code: code,
  meta: switch (type) {
    EmoteType.twitch => TwitchMeta(
      kind: twitchKindOf(tier, emoteType),
      subTier: tier == null ? null : int.tryParse(tier),
      ownerChannel: ownerChannel,
      ownerId: ownerId,
    ),
    EmoteType.bttv => const BttvMeta(),
    EmoteType.ffz => FfzMeta(ownerChannel: ownerChannel),
    EmoteType.sevenTv => SevenTvMeta(
      creator: ownerChannel,
      baseName: baseName,
      unlisted: isUnlisted,
      relativeScale: relativeScale,
    ),
  },
  url: 'https://example.com/$id.png',
  isZeroWidth: isZeroWidth,
  scope: scope,
);
