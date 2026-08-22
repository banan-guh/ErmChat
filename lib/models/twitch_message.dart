import 'package:flutter/material.dart';
import 'twitch_badge.dart';

class EmotePosition {
  final String emoteId;
  final int startIndex;
  final int endIndex;
  final String emoteCode;

  const EmotePosition({
    required this.emoteId,
    required this.startIndex,
    required this.endIndex,
    required this.emoteCode,
  });
}

class TwitchMessage {
  final DateTime timestamp;
  final String login;
  final String displayName;
  String text;
  String? color;
  final bool isSystem;
  final Color? systemAccent;
  final bool isAction;

  /// Set on ban/timeout system messages from CLEARCHAT so the robotty
  /// history sweep can tell them apart from other system messages that
  /// legitimately carry a login (e.g. announcements).
  final bool isBanNotice;
  String? messageId;
  final String? channel;
  bool deleted;
  final bool isHistory;

  /// True for messages backfilled from history after a disconnect/reconnect
  /// gap, so the UI can grey them out to distinguish catch-up from live chat.
  bool isBackfill;
  String? replyToParentId;
  final String? replyToUser;
  final String? replyToText;
  String? replyThreadRootId;
  bool isHighlighted;
  String? userId;
  final bool isFirstMessage;

  /// Amount of bits cheered with this message (PRIVMSG `bits` tag), or null
  /// for non-cheer messages.
  final int? bitsAmount;
  final List<EmotePosition>? emotePositions;
  final List<MessageBadge>? badges;
  final String? sourceBroadcasterId;
  final String? sourceBroadcasterName;
  List<InlineSpan>? cachedSpans;
  // EmoteManager.version at which cachedSpans was computed; when the manager
  // notifies a higher version, the spans are rebuilt lazily on next render.
  int? cachedSpansVersion;
  List<WidgetSpan>? cachedBadgeSpans;
  late final String formattedTimestamp =
      '${timestamp.toLocal().hour.toString().padLeft(2, '0')}:${timestamp.toLocal().minute.toString().padLeft(2, '0')}';
  late final String formattedUsername =
      displayName.toLowerCase() == login.toLowerCase()
      ? displayName
      : '$login($displayName)';

  static ({String login, String displayName}) resolveUser({
    required String login,
    String? displayName,
  }) {
    final lowerLogin = login.toLowerCase();
    final display = (displayName != null && displayName.isNotEmpty)
        ? displayName
        : lowerLogin;
    return (login: lowerLogin, displayName: display);
  }

  TwitchMessage({
    required this.login,
    required this.text,
    String? displayName,
    this.color,
    DateTime? timestamp,
    this.isSystem = false,
    this.systemAccent,
    this.isAction = false,
    this.isBanNotice = false,
    this.messageId,
    this.channel,
    this.deleted = false,
    this.isHistory = false,
    this.isBackfill = false,
    this.replyToParentId,
    this.replyToUser,
    this.replyToText,
    this.replyThreadRootId,
    this.isHighlighted = false,
    this.isFirstMessage = false,
    this.bitsAmount,
    this.userId,
    this.emotePositions,
    this.badges,
    this.sourceBroadcasterId,
    this.sourceBroadcasterName,
  }) : timestamp = timestamp ?? DateTime.now(),
       displayName = displayName ?? login;
}
