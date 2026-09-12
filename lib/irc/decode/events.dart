import '../../models/twitch_badge.dart';
import '../../models/twitch_message.dart';

class IrcBanEvent {
  final String channel;
  final String user;
  final String? userId;
  final bool isTimeout;
  final int? duration;

  IrcBanEvent({
    required this.channel,
    required this.user,
    this.userId,
    required this.isTimeout,
    this.duration,
  });
}

class IrcNoticeEvent {
  final String channel;
  final String message;
  final String? msgId;

  IrcNoticeEvent({required this.channel, required this.message, this.msgId});
}

/// Full channel clear (/clear): CLEARCHAT with no target.
class IrcChannelClearEvent {
  final String channel;

  IrcChannelClearEvent({required this.channel});
}

/// Room-mode state (slow, followers-only, emote-only, subs-only, r9k). Sent
/// on join and on change.
class IrcMessageDeletedEvent {
  final String channel;
  final String messageId;
  final String user;
  final String deletedMessageText;

  IrcMessageDeletedEvent({
    required this.channel,
    required this.messageId,
    required this.user,
    required this.deletedMessageText,
  });
}

/// A USERNOTICE event (sub, resub, raid, announcement, etc.). systemMsg is
/// empty for announcements (where text holds the message).
class UserNoticeEvent {
  final String channel;
  final String msgId;
  final String login;
  final String displayName;
  final String? systemMsg;
  final String? text;
  final String? announcementColor;
  final String? userId;
  final String? messageId;
  final String? color;
  final List<MessageBadge>? badges;
  final List<EmotePosition>? emotePositions;

  UserNoticeEvent({
    required this.channel,
    required this.msgId,
    required this.login,
    required this.displayName,
    this.systemMsg,
    this.text,
    this.announcementColor,
    this.userId,
    this.messageId,
    this.color,
    this.badges,
    this.emotePositions,
  });
}

class IrcRoomStateEvent {
  final String channel;

  /// Raw tag map; updates are partial (only changed tags), so callers that
  /// need the full state must merge with the previous event.
  final Map<String, String> tags;

  IrcRoomStateEvent({required this.channel, required this.tags});
}
