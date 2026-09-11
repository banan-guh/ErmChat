import '../../models/point_rewards.dart';

/// A channel.moderate v2 event. `action` is ban, timeout, delete, mod, etc.
/// Mode toggles (slow, followers, ...) and term decisions carry no target;
/// term actions carry [terms]; everything else follows the old fields.
class ModerationEvent {
  final String channel;
  final String action;
  final String moderatorName;
  final String? targetName;
  final String? reason;
  final int? durationSeconds;
  final String? messageId;
  final String? messageBody;
  final List<String> terms;

  ModerationEvent({
    required this.channel,
    required this.action,
    required this.moderatorName,
    this.targetName,
    this.reason,
    this.durationSeconds,
    this.messageId,
    this.messageBody,
    this.terms = const [],
  });
}

/// An AutoMod queue event. [status] is held (new) or the resolution that
/// removed it from the queue: approved, denied, expired.
class AutomodHeldEvent {
  final String channel;
  final String messageId;
  final String userLogin;
  final String text;
  final String category;
  final String status;

  AutomodHeldEvent({
    required this.channel,
    required this.messageId,
    required this.userLogin,
    required this.text,
    required this.category,
    required this.status,
  });
}

/// A shield mode toggle. [active] is true on begin, false on end.
class ShieldModeEvent {
  final String channel;
  final bool active;
  final String moderatorName;

  ShieldModeEvent({
    required this.channel,
    required this.active,
    required this.moderatorName,
  });
}

/// A shoutout. [kind] is create (this channel shouted someone out) or
/// receive (this channel was shouted out).
class ShoutoutEvent {
  final String channel;
  final String kind;
  final String fromLogin;
  final String toLogin;
  final String moderatorName;

  ShoutoutEvent({
    required this.channel,
    required this.kind,
    required this.fromLogin,
    required this.toLogin,
    required this.moderatorName,
  });
}

/// A warning lifecycle event. [kind] is send or acknowledge.
class WarningEvent {
  final String channel;
  final String kind;
  final String moderatorName;
  final String userLogin;
  final String? reason;

  WarningEvent({
    required this.channel,
    required this.kind,
    required this.moderatorName,
    required this.userLogin,
    this.reason,
  });
}

/// An unban request event. [kind] is create or resolve.
class UnbanRequestEvent {
  final String channel;
  final String kind;
  final String userLogin;
  final String moderatorName;
  final String? resolutionText;

  UnbanRequestEvent({
    required this.channel,
    required this.kind,
    required this.userLogin,
    required this.moderatorName,
    this.resolutionText,
  });
}

/// A public AutoMod terms change. Private-term changes never arrive.
class AutomodTermsEvent {
  final String channel;

  /// add or remove.
  final String action;

  /// blocked or permitted.
  final String list;
  final List<String> terms;
  final String moderatorName;

  AutomodTermsEvent({
    required this.channel,
    required this.action,
    required this.list,
    required this.terms,
    required this.moderatorName,
  });
}

/// An AutoMod settings change.
class AutomodSettingsEvent {
  final String channel;
  final String moderatorName;

  AutomodSettingsEvent({required this.channel, required this.moderatorName});
}

/// A suspicious-user sighting or flag change. [kind] is message or update.
class SuspiciousUserEvent {
  final String channel;
  final String kind;
  final String userLogin;
  final String status;
  final List<String> types;
  final String? banEvasion;
  final List<String> sharedBanChannelIds;
  final String moderatorName;

  SuspiciousUserEvent({
    required this.channel,
    required this.kind,
    required this.userLogin,
    required this.status,
    this.types = const [],
    this.banEvasion,
    this.sharedBanChannelIds = const [],
    required this.moderatorName,
  });
}

/// A custom reward change. [kind] is add, update, or remove.
class PointRewardEvent {
  final String channel;
  final String kind;
  final PointReward reward;

  PointRewardEvent({
    required this.channel,
    required this.kind,
    required this.reward,
  });
}

/// A custom-reward redemption. [kind] is add or update.
class PointRedemptionEvent {
  final String channel;
  final String kind;
  final PointRedemption redemption;

  PointRedemptionEvent({
    required this.channel,
    required this.kind,
    required this.redemption,
  });
}

/// A hype train event. [kind] is begin, progress, or end.
class HypeTrainEvent {
  final String channel;
  final String kind;
  final int level;
  final int progress;
  final int total;
  final DateTime? expiresAt;
  final List<HypeTrainContribution> topContributions;

  HypeTrainEvent({
    required this.channel,
    required this.kind,
    required this.level,
    required this.progress,
    required this.total,
    this.expiresAt,
    this.topContributions = const [],
  });
}

class HypeTrainContribution {
  final String userName;
  final String type;
  final int total;

  HypeTrainContribution({
    required this.userName,
    required this.type,
    required this.total,
  });
}

/// A channel poll event. [kind] is begin, progress, or end.
class PollEvent {
  final String channel;
  final String kind;
  final String title;
  final List<PollChoice> choices;
  final String status;

  PollEvent({
    required this.channel,
    required this.kind,
    required this.title,
    required this.choices,
    required this.status,
  });
}

class PollChoice {
  final String title;
  final int votes;

  PollChoice({required this.title, required this.votes});
}

/// A channel prediction event. [kind] is begin, progress, lock, or end.
class PredictionEvent {
  final String channel;
  final String kind;
  final String title;
  final List<PredictionOutcome> outcomes;
  final String status;

  PredictionEvent({
    required this.channel,
    required this.kind,
    required this.title,
    required this.outcomes,
    required this.status,
  });
}

class PredictionOutcome {
  final String title;
  final int users;
  final int channelPoints;

  PredictionOutcome({
    required this.title,
    required this.users,
    required this.channelPoints,
  });
}
