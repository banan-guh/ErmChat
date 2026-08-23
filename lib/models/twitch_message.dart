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

  /// Set by the ping engine when one or more highlight rules matched.
  /// Null means unhighlighted.
  HighlightState? highlight;

  /// Convenience for call sites that only care whether the message is
  /// highlighted at all.
  bool get isHighlighted => highlight != null;

  String? userId;
  final bool isFirstMessage;

  /// PRIVMSG `msg-id` tag (e.g. `highlighted-message`); null on most messages.
  final String? msgId;

  /// Channel point redemption id (`custom-reward-id`), if any.
  final String? customRewardId;

  /// `pinned-chat-paid-amount` value on elevated (Hype Chat) messages.
  final String? pinnedPaidAmount;

  /// Amount of bits cheered with this message (PRIVMSG `bits` tag), or null
  /// for non-cheer messages.
  final int? bitsAmount;
  final List<EmotePosition>? emotePositions;
  final List<MessageBadge>? badges;
  final String? sourceBroadcasterId;
  final String? sourceBroadcasterName;

  /// The original message id from the shared-chat source channel
  /// (PRIVMSG/USERNOTICE `source-id` tag). Stable across every mirrored copy,
  /// unlike [messageId] which is unique per receiving room.
  final String? sourceMessageId;
  List<InlineSpan>? cachedSpans;
  // EmoteManager.version at which cachedSpans was computed; when the manager
  // notifies a higher version, the spans are rebuilt lazily on next render.
  int? cachedSpansVersion;
  // The text scale that cachedSpans were built for. Cached spans embed
  // absolute emote pixel sizes, so a scale change must rebuild them (text
  // resizes and emotes follow).
  double? cachedSpansScale;
  List<WidgetSpan>? cachedBadgeSpans;
  int? cachedBadgeSpansVersion;
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
    this.sourceBroadcasterName,
    this.sourceMessageId,
  }) : timestamp = timestamp ?? DateTime.now(),
       displayName = displayName ?? login;
}
