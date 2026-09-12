// Moderation value types shared by the EventSub layer and the chat kernel.
// They live here (not in lib/chat) so both layers plus pure formatters can
// use them without layering inversions.

/// One AutoMod-held message awaiting a moderation decision.
class HeldMessage {
  final String messageId;
  final String channel;
  final String userLogin;
  final String text;
  final String category;

  const HeldMessage({
    required this.messageId,
    required this.channel,
    required this.userLogin,
    required this.text,
    required this.category,
  });
}

/// One moderation action for the per-channel activity feed.
class ModActivityEntry {
  final DateTime at;
  final String channel;
  final String action;
  final String moderator;
  final String? target;
  final String? reason;
  final int? durationSeconds;
  final List<String> terms;

  const ModActivityEntry({
    required this.at,
    required this.channel,
    required this.action,
    required this.moderator,
    this.target,
    this.reason,
    this.durationSeconds,
    this.terms = const [],
  });
}

/// One warning sent to a chatter. No Helix list endpoint exists, so the log
/// is local and session-scoped.
class WarnEntry {
  final DateTime at;
  final String channel;
  final String target;
  final String moderator;
  final String? reason;

  const WarnEntry({
    required this.at,
    required this.channel,
    required this.target,
    required this.moderator,
    this.reason,
  });
}

/// One active ban or timeout. Timeouts carry [expiresAt]; bans are permanent.
class BanEntry {
  final DateTime at;
  final String channel;
  final String login;
  final DateTime? expiresAt;
  final String? reason;
  final String moderator;

  const BanEntry({
    required this.at,
    required this.channel,
    required this.login,
    this.expiresAt,
    this.reason,
    required this.moderator,
  });
}

/// Last-seen suspicious-user context for one chatter.
class SuspiciousInfo {
  final DateTime at;
  final String channel;
  final String login;
  final String status;
  final List<String> types;
  final String? banEvasion;
  final List<String> sharedBanChannelIds;

  const SuspiciousInfo({
    required this.at,
    required this.channel,
    required this.login,
    required this.status,
    this.types = const [],
    this.banEvasion,
    this.sharedBanChannelIds = const [],
  });
}
