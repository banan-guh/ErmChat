import 'package:flutter/material.dart';
import 'highlight_state.dart';
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

  /// True for CLEARCHAT ban/timeout messages, so history sweep distinguishes them from announcements.
  final bool isBanNotice;
  String? messageId;
  final String? channel;
  bool deleted;
  final bool isHistory;

  /// Backfilled from history after a reconnect gap; UI greys these out.
  bool isBackfill;
  String? replyToParentId;
  final String? replyToUser;
  final String? replyToText;
  String? replyThreadRootId;

  /// Set by the ping engine when rules matched; null = unhighlighted.
  HighlightState? highlight;

  /// Whether the message is highlighted.
  bool get isHighlighted => highlight != null;

  String? userId;
  final bool isFirstMessage;

  /// PRIVMSG `msg-id` tag (e.g. `highlighted-message`); null on most messages.
  final String? msgId;

  /// Channel point redemption id (`custom-reward-id`), if any.
  final String? customRewardId;

  /// `pinned-chat-paid-amount` value on elevated (Hype Chat) messages.
  final String? pinnedPaidAmount;

  /// Bits cheered (PRIVMSG bits tag), or null for non-cheers.
  final int? bitsAmount;
  final List<EmotePosition>? emotePositions;
  final List<MessageBadge>? badges;
  final String? sourceBroadcasterId;

  /// Source-channel message id (source-id tag). Stable across mirrored copies, unlike [messageId].
  final String? sourceMessageId;
  List<InlineSpan>? cachedSpans;
  // EmoteManager.version when cachedSpans was built; rebuilt on next render when version bumps.
  int? cachedSpansVersion;
  // Text scale when cachedSpans was built; scale change forces rebuild (emotes are absolute-size).
  double? cachedSpansScale;
  List<WidgetSpan>? cachedBadgeSpans;
  int? cachedBadgeSpansVersion;

  /// Badge scale when cachedBadgeSpans was built; scale change forces rebuild.
  double? cachedBadgeSpansScale;
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
    this.highlight,
    this.isFirstMessage = false,
    this.msgId,
    this.customRewardId,
    this.pinnedPaidAmount,
    this.bitsAmount,
    this.userId,
    this.emotePositions,
    this.badges,
    this.sourceBroadcasterId,
    this.sourceMessageId,
  }) : timestamp = timestamp ?? DateTime.now(),
       displayName = displayName ?? login;
}
