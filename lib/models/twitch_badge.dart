class BadgeVersion {
  final String imageUrl;

  const BadgeVersion({required this.imageUrl});
}

class BadgeSet {
  final Map<String, BadgeVersion> versions;

  const BadgeSet({required this.versions});
}

class MessageBadge {
  final String setId;
  final String versionId;

  const MessageBadge({required this.setId, required this.versionId});
}

/// Badge resolved for non-chat surfaces (user card). Same order and
/// fallback rules as the chat row: shared-chat avatar, Twitch sets in tag
/// order, one third-party badge.
class CardBadge {
  final String url;
  final String label;
  final bool circular;

  const CardBadge({
    required this.url,
    required this.label,
    this.circular = false,
  });
}
