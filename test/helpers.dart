import 'package:ermchat/models/generic_emote.dart';

GenericEmote makeTestEmote({
  required String id,
  required String code,
  EmoteType type = EmoteType.bttv,
  bool isZeroWidth = false,
  bool isUnlisted = false,
  EmoteScope scope = EmoteScope.global,
  String? ownerChannel,
  String? baseName,
  double relativeScale = 1.0,
}) => GenericEmote(
  id: id,
  code: code,
  type: type,
  url: 'https://example.com/$id.png',
  isZeroWidth: isZeroWidth,
  isUnlisted: isUnlisted,
  scope: scope,
  ownerChannel: ownerChannel,
  baseName: baseName,
  relativeScale: relativeScale,
);
