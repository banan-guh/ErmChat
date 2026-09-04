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

  Map<String, dynamic> toJson() => {
    'emoteId': emoteId,
    'startIndex': startIndex,
    'endIndex': endIndex,
    'emoteCode': emoteCode,
  };

  factory EmotePosition.fromJson(Map<String, dynamic> json) => EmotePosition(
    emoteId: json['emoteId'] as String? ?? '',
    startIndex: (json['startIndex'] as num?)?.toInt() ?? 0,
    endIndex: (json['endIndex'] as num?)?.toInt() ?? 0,
    emoteCode: json['emoteCode'] as String? ?? '',
  );
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

  // Full-log persistence for saved threads. Highlight and span caches are
  // session state: highlights re-evaluate on load, spans rebuild lazily.
  Map<String, dynamic> toJson() => {
    'login': login,
    'displayName': displayName,
    'text': text,
    'color': color,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'isSystem': isSystem,
    'systemAccent': systemAccent?.toARGB32(),
    'isAction': isAction,
    'isBanNotice': isBanNotice,
    'messageId': messageId,
    'channel': channel,
    'deleted': deleted,
    'isHistory': isHistory,
    'isBackfill': isBackfill,
    'replyToParentId': replyToParentId,
    'replyToUser': replyToUser,
    'replyToText': replyToText,
    'replyThreadRootId': replyThreadRootId,
    'userId': userId,
    'isFirstMessage': isFirstMessage,
    'msgId': msgId,
    'customRewardId': customRewardId,
    'pinnedPaidAmount': pinnedPaidAmount,
    'bitsAmount': bitsAmount,
    'emotePositions': emotePositions?.map((e) => e.toJson()).toList(),
    'badges': badges
        ?.map((b) => {'setId': b.setId, 'versionId': b.versionId})
        .toList(),
    'sourceBroadcasterId': sourceBroadcasterId,
    'sourceMessageId': sourceMessageId,
  };

  factory TwitchMessage.fromJson(Map<String, dynamic> json) => TwitchMessage(
    login: json['login'] as String? ?? '',
    displayName: json['displayName'] as String?,
    text: json['text'] as String? ?? '',
    color: json['color'] as String?,
    timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '')?.toLocal(),
    isSystem: json['isSystem'] as bool? ?? false,
    systemAccent: (json['systemAccent'] as num?) != null
        ? Color((json['systemAccent'] as num).toInt())
        : null,
    isAction: json['isAction'] as bool? ?? false,
    isBanNotice: json['isBanNotice'] as bool? ?? false,
    messageId: json['messageId'] as String?,
    channel: json['channel'] as String?,
    deleted: json['deleted'] as bool? ?? false,
    isHistory: json['isHistory'] as bool? ?? false,
    isBackfill: json['isBackfill'] as bool? ?? false,
    replyToParentId: json['replyToParentId'] as String?,
    replyToUser: json['replyToUser'] as String?,
    replyToText: json['replyToText'] as String?,
    replyThreadRootId: json['replyThreadRootId'] as String?,
    userId: json['userId'] as String?,
    isFirstMessage: json['isFirstMessage'] as bool? ?? false,
    msgId: json['msgId'] as String?,
    customRewardId: json['customRewardId'] as String?,
    pinnedPaidAmount: json['pinnedPaidAmount'] as String?,
    bitsAmount: (json['bitsAmount'] as num?)?.toInt(),
    emotePositions: (json['emotePositions'] as List?)
        ?.whereType<Map>()
        .map((e) => EmotePosition.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    badges: (json['badges'] as List?)
        ?.whereType<Map>()
        .map(
          (e) => MessageBadge(
            setId: e['setId'] as String? ?? '',
            versionId: e['versionId'] as String? ?? '',
          ),
        )
        .toList(),
    sourceBroadcasterId: json['sourceBroadcasterId'] as String?,
    sourceMessageId: json['sourceMessageId'] as String?,
  );
}
