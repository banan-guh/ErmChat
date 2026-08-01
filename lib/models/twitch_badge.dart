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
