class BadgeVersion {
  final String imageUrl;

  /// Display name from Helix, like "6-Month Subscriber".
  final String? title;

  const BadgeVersion({required this.imageUrl, this.title});
}

class BadgeSet {
  final Map<String, BadgeVersion> versions;

  const BadgeSet({required this.versions});
}

class MessageBadge {
  final String setId;
  final String versionId;

  /// The image and title an archived row had; null draws today's.
  final BadgeVersion? drawn;

  const MessageBadge({
    required this.setId,
    required this.versionId,
    this.drawn,
  });
}

/// Badge resolved for non-chat surfaces (user card). Same order and
/// fallback rules as the chat row: shared-chat avatar, Twitch sets in tag
/// order, one third-party badge.
class CardBadge {
  final String url;

  /// Empty when the badge has no name; the card supplies a localized fallback.
  final String label;
  final bool circular;

  const CardBadge({
    required this.url,
    required this.label,
    this.circular = false,
  });

  bool get isSvg => Uri.tryParse(url)?.path.endsWith('.svg') ?? false;
}
