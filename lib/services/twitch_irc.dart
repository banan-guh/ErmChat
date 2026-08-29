import 'dart:async';
import 'dart:ui' show Color;
import 'package:flutter/foundation.dart';
import '../color_utils.dart';
import '../models/twitch_badge.dart';
import '../models/twitch_message.dart';
import '../util/duration_format.dart';
import '../util/log.dart';
import 'base_irc_connection.dart';

export 'base_irc_connection.dart'
    show
        IrcConnection,
        IrcReadService,
        IrcConnectionStatus,
        IrcJoinFailureEvent,
        JoinFailureReason,
        IrcMessage,
        IrcRoomStateEvent,
        parseIrcMessage;

final _replyPrefixRe = RegExp(r'^\s*@\S+\s+');

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

/// Row accent for a USERNOTICE. Announcements use banner color; everything
/// else uses PRIMARY purple.
Color userNoticeAccent(String msgId, {String? announcementColorParam}) {
  if (msgId == 'announcement') {
    return announcementColorFor(announcementColorParam) ??
        announcementColors['PRIMARY']!;
  }
  return announcementColors['PRIMARY']!;
}

/// Composite label id for USERNOTICE. Namespaced so system label and chat
/// message stay distinct.
String? userNoticeLabelId(String? rawId) {
  if (rawId == null || rawId.isEmpty) return null;
  return '$rawId:label';
}

/// System-message text for USERNOTICE. Announcements use bare
/// "Announcement" label; others use Twitch system-msg.
String buildUserNoticeText({
  required String msgId,
  required String displayName,
  String? systemMsg,
}) {
  if (msgId == 'announcement') return 'Announcement';
  final base = systemMsg;
  if (base == null || base.isEmpty) return '$displayName $msgId.';
  return base;
}

/// Builds the system-message text for a CLEARCHAT ban/timeout.
String buildBanText({
  required String user,
  required bool isTimeout,
  int? durationSec,
}) {
  if (isTimeout) {
    return '$user was timed out${durationSec != null ? ' for ${formatSeconds(durationSec)}' : ''}.';
  }
  return '$user was banned.';
}

/// Parses IRC `emotes` tag into [EmotePosition]s. Positions are relative to
/// [originalText]; [prefixLen] adjusts for reply prefix.
List<EmotePosition>? parseIrcEmotePositions(
  String? emotesTag, {
  required String originalText,
  required String strippedText,
  int prefixLen = 0,
}) {
  if (emotesTag == null || emotesTag.isEmpty) return null;
  // ACTION wrapper: Twitch sends emote positions relative to the message
  // body (after "\x01ACTION "), so use the body as the position base.
  final baseText =
      originalText.startsWith('\x01ACTION ') && originalText.endsWith('\x01')
      ? originalText.substring(8)
      : originalText;
  final positions = <EmotePosition>[];
  for (final emoteEntry in emotesTag.split('/')) {
    final colonIdx = emoteEntry.indexOf(':');
    if (colonIdx == -1) continue;
    final emoteId = emoteEntry.substring(0, colonIdx);
    final positionsStr = emoteEntry.substring(colonIdx + 1);
    for (final posStr in positionsStr.split(',')) {
      final dashIdx = posStr.indexOf('-');
      if (dashIdx == -1) continue;
      final start = int.tryParse(posStr.substring(0, dashIdx));
      final end = int.tryParse(posStr.substring(dashIdx + 1));
      if (start == null || end == null) continue;
      final utf16Start = _tagToUtf16(baseText, start);
      final utf16End = _tagToUtf16(baseText, end + 1);
      if (utf16Start < 0 || utf16End > baseText.length) continue;
      final emoteCode = baseText.substring(utf16Start, utf16End);
      final adjStart = utf16Start - prefixLen;
      final adjEnd = utf16End - prefixLen;
      if (adjStart < 0 || adjEnd > strippedText.length) continue;
      positions.add(
        EmotePosition(
          emoteId: emoteId,
          startIndex: adjStart,
          endIndex: adjEnd,
          emoteCode: emoteCode,
        ),
      );
    }
  }
  return positions.isEmpty ? null : positions;
}

/// Converts an IRC emote-tag codepoint offset to a UTF-16 index in [text].
/// Returns -1 if out of bounds.
int _tagToUtf16(String text, int tagOffset) {
  if (tagOffset <= 0) return tagOffset;
  var utf16 = 0;
  var codePoints = 0;
  while (utf16 < text.length && codePoints < tagOffset) {
    final unit = text.codeUnitAt(utf16);
    codePoints++;
    utf16++;
    // High surrogate: this supplementary character occupies two UTF-16 units.
    if (unit >= 0xD800 && unit <= 0xDBFF) utf16++;
  }
  return codePoints == tagOffset ? utf16 : -1;
}

/// Parses the IRC `badges` tag into [MessageBadge]s.
List<MessageBadge>? parseIrcBadges(String? badgesTag) {
  if (badgesTag == null || badgesTag.isEmpty) return null;
  final badges = <MessageBadge>[];
  for (final entry in badgesTag.split(',')) {
    final slashIdx = entry.indexOf('/');
    if (slashIdx == -1) continue;
    final setId = entry.substring(0, slashIdx);
    final versionId = entry.substring(slashIdx + 1);
    if (setId.isNotEmpty && versionId.isNotEmpty) {
      badges.add(MessageBadge(setId: setId, versionId: versionId));
    }
  }
  return badges.isEmpty ? null : badges;
}

class IrcService extends IrcConnection {
  final _banController = StreamController<IrcBanEvent>.broadcast();
  final _noticeController = StreamController<IrcNoticeEvent>.broadcast();
  final _jtvController = StreamController<IrcNoticeEvent>.broadcast();
  final _deleteController =
      StreamController<IrcMessageDeletedEvent>.broadcast();
  final _messageController = StreamController<TwitchMessage>.broadcast(
    sync: true,
  );
  final _userNoticeController = StreamController<UserNoticeEvent>.broadcast(
    sync: true,
  );
  final _clearController = StreamController<IrcChannelClearEvent>.broadcast(
    sync: true,
  );
  final _roomStateController = StreamController<IrcRoomStateEvent>.broadcast(
    sync: true,
  );
  final _whisperController = StreamController<TwitchMessage>.broadcast(
    sync: true,
  );
  // Channel-scoped emote sets: USERSTATE = channel, GLOBALUSERSTATE =
  // account-wide (null).
  final _emoteSetsController =
      StreamController<(String?, List<String>)>.broadcast(sync: true);
  final _authFailedController = StreamController<void>.broadcast();

  // Own badge set-ids per channel. Feeds slow-mode bypass checks.
  final selfBadges = <String?, Set<String>>{};

  /// Per-account badges; dropped on account switch to avoid stale bypass.
  void clearSelfBadges() => selfBadges.clear();

  Stream<IrcBanEvent> get onBan => _banController.stream;
  Stream<IrcNoticeEvent> get onNotice => _noticeController.stream;
  Stream<IrcNoticeEvent> get onJtvMessage => _jtvController.stream;
  Stream<IrcChannelClearEvent> get onChannelClear => _clearController.stream;
  Stream<IrcRoomStateEvent> get onRoomState => _roomStateController.stream;
  Stream<IrcMessageDeletedEvent> get onMessageDeleted =>
      _deleteController.stream;
  Stream<TwitchMessage> get onMessage => _messageController.stream;
  Stream<UserNoticeEvent> get onUserNotice => _userNoticeController.stream;
  Stream<TwitchMessage> get onWhisper => _whisperController.stream;
  Stream<(String?, List<String>)> get onUserEmoteSets =>
      _emoteSetsController.stream;
  Stream<void> get onAuthFailed => _authFailedController.stream;

  @override
  String get debugPrefix => 'IRC';

  IrcService({super.connectivityService, super.joinBudget});

  void sendMessage(
    String channelName,
    String text, {
    String? replyParentMessageId,
  }) {
    if (channel == null || username == null) return;

    final tag = replyParentMessageId != null
        ? '@reply-parent-msg-id=$replyParentMessageId '
        : '';
    final msg = '${tag}PRIVMSG #$channelName :$text';
    sendLine(msg);
  }

  @override
  void dispatchLine(IrcMessage msg) {
    switch (msg.command) {
      case 'CLEARCHAT':
        _handleClearChat(msg);
        return;
      case 'CLEARMSG':
        _handleClearMsg(msg);
        return;
      case 'USERNOTICE':
        _handleUserNotice(msg);
        return;
      case 'NOTICE':
        _handleNotice(msg);
        return;
      case 'WHISPER':
        _handleWhisper(msg);
        return;
      // Both carry the emote-sets tag (authoritative; Helix endpoint omits
      // some grants).
      case 'USERSTATE':
      case 'GLOBALUSERSTATE':
        _handleUserState(msg);
        return;
      case 'ROOMSTATE':
        _handleRoomState(msg);
        return;
      case 'PRIVMSG':
        if (msg.prefix != null && msg.prefix!.contains('jtv.tmi.twitch.tv')) {
          _handleJtvMessage(msg);
        } else {
          _handleChatMessage(msg);
        }
        return;
    }
  }

  void _handleClearChat(IrcMessage msg) {
    final channelName = msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    if (channelName == null) return;

    final targetUser = msg.trailing;
    // No target = full channel clear (/clear).
    if (targetUser == null || targetUser.isEmpty) {
      _clearController.add(IrcChannelClearEvent(channel: channelName));
      return;
    }

    final banDuration = msg.tags['ban-duration'];
    final targetUserId = msg.tags['target-user-id'];
    final isTimeout = banDuration != null;
    final duration = isTimeout ? int.tryParse(banDuration) : null;

    _banController.add(
      IrcBanEvent(
        channel: channelName,
        user: targetUser,
        userId: targetUserId,
        isTimeout: isTimeout,
        duration: duration,
      ),
    );
  }

  void _handleClearMsg(IrcMessage msg) {
    final channelName = msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    if (channelName == null) return;

    final messageId = msg.tags['target-msg-id'];
    final user = msg.tags['login'] ?? 'unknown';
    final deletedText = msg.trailing ?? '';
    if (messageId == null || messageId.isEmpty) return;

    _deleteController.add(
      IrcMessageDeletedEvent(
        channel: channelName,
        messageId: messageId,
        user: user,
        deletedMessageText: deletedText,
      ),
    );
  }

  void _handleNotice(IrcMessage msg) {
    final channelParam = msg.params.isNotEmpty ? msg.params[0] : null;
    // NOTICE * is connection-level (e.g. login failure), not channel-scoped.
    if (channelParam == null || channelParam == '*') {
      final trailing = msg.trailing;
      if (trailing != null &&
          trailing.contains('Login authentication failed')) {
        _authFailedController.add(null);
        signalFatalAuthFailure();
      }
      return;
    }
    final channelName = channelParam.startsWith('#')
        ? channelParam.substring(1)
        : channelParam;
    if (msg.trailing == null) return;

    _noticeController.add(
      IrcNoticeEvent(
        channel: channelName,
        message: msg.trailing!,
        msgId: msg.tags['msg-id'],
      ),
    );
  }

  void _handleJtvMessage(IrcMessage msg) {
    if (msg.trailing == null) return;
    final channelName = msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    if (channelName == null) return;

    _jtvController.add(
      IrcNoticeEvent(channel: channelName, message: msg.trailing!),
    );
  }

  void _handleUserState(IrcMessage msg) {
    final emoteSets = msg.tags['emote-sets'];
    final badges = parseIrcBadges(msg.tags['badges']);
    if ((emoteSets == null || emoteSets.isEmpty) && badges == null) return;
    // USERSTATE = channel-scoped; GLOBALUSERSTATE = account-wide (null
    // channel).
    final channel = msg.command == 'USERSTATE' && msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    if (emoteSets != null && emoteSets.isNotEmpty) {
      final ids = emoteSets
          .split(',')
          .where((id) => id.trim().isNotEmpty)
          .toList();
      if (ids.isNotEmpty) {
        _emoteSetsController.add((channel, ids));
      }
    }
    if (badges != null) {
      selfBadges[channel] = badges.map((b) => b.setId).toSet();
    }
  }

  void _handleRoomState(IrcMessage msg) {
    final channelName = msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    if (channelName == null) return;
    PerfLog.I.record('JOINQ', '[IRC] confirm #$channelName');

    _roomStateController.add(
      IrcRoomStateEvent(channel: channelName, tags: msg.tags),
    );
  }

  void _handleUserNotice(IrcMessage msg) {
    final channelName = msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    if (channelName == null) return;

    // Shared chat mirrors foreign USERNOTICEs as `sharedchatnotice`; only
    // announcements are kept.
    var msgId = msg.tags['msg-id'] ?? '';
    if (msgId == 'sharedchatnotice') {
      final sourceMsgId = msg.tags['source-msg-id'];
      if (sourceMsgId != 'announcement') return;
      msgId = 'announcement';
    }

    final ircPrefLogin = msg.prefix != null && msg.prefix!.contains('!')
        ? msg.prefix!.substring(0, msg.prefix!.indexOf('!'))
        : null;
    final login = (msg.tags['login'] ?? ircPrefLogin ?? '').toLowerCase();
    final displayName = msg.tags['display-name'] ?? login;
    final systemMsg = msg.tags['system-msg'];
    final text = msg.trailing;

    _userNoticeController.add(
      UserNoticeEvent(
        channel: channelName,
        msgId: msgId,
        login: login,
        displayName: displayName,
        systemMsg: systemMsg,
        text: text,
        announcementColor: msg.tags['msg-param-color'],
        userId: msg.tags['user-id'],
        messageId: msg.tags['id'],
        color: msg.tags['color'],
        badges: parseIrcBadges(msg.tags['badges']),
        emotePositions: text != null
            ? parseIrcEmotePositions(
                msg.tags['emotes'],
                originalText: text,
                strippedText: text,
              )
            : null,
      ),
    );
  }

  void _handleChatMessage(IrcMessage msg) {
    if (msg.trailing == null) return;
    final channelName = msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    if (channelName == null) return;

    final prefixLogin = msg.prefix != null && msg.prefix!.contains('!')
        ? msg.prefix!.substring(0, msg.prefix!.indexOf('!')).toLowerCase()
        : null;
    // Own messages are echoed on the read-only socket instead.
    if (prefixLogin == null || username == null || prefixLogin == username) {
      return;
    }

    _messageController.add(parseIrcChatMessage(msg, channel: channelName));
  }

  void _handleWhisper(IrcMessage msg) {
    if (msg.trailing == null) return;
    _whisperController.add(parseIrcChatMessage(msg, channel: null));
  }

  @visibleForTesting
  void emitChatMessage(TwitchMessage msg) => _messageController.add(msg);

  @visibleForTesting
  void emitWhisper(TwitchMessage msg) => _whisperController.add(msg);

  @visibleForTesting
  void emitUserNotice(UserNoticeEvent event) =>
      _userNoticeController.add(event);

  @visibleForTesting
  void emitRoomState(String channel, Map<String, String> tags) =>
      _roomStateController.add(IrcRoomStateEvent(channel: channel, tags: tags));

  @override
  void dispose() {
    _banController.close();
    _noticeController.close();
    _jtvController.close();
    _deleteController.close();
    _messageController.close();
    _userNoticeController.close();
    _clearController.close();
    _roomStateController.close();
    _whisperController.close();
    _emoteSetsController.close();
    _authFailedController.close();
    super.dispose();
  }
}

/// Parses an IRC PRIVMSG into a [TwitchMessage]. Defaults fill in for own
/// echoes; timestamp/isHistory override for history.
TwitchMessage parseIrcChatMessage(
  IrcMessage ircMsg, {
  required String? channel,
  String? defaultLogin,
  String? defaultDisplayName,
  String? defaultUserId,
  DateTime? timestamp,
  bool isHistory = false,
}) {
  final displayName =
      ircMsg.tags['display-name']?.trim() ?? defaultDisplayName ?? '';
  final ircPrefLogin = ircMsg.prefix != null && ircMsg.prefix!.contains('!')
      ? ircMsg.prefix!.substring(0, ircMsg.prefix!.indexOf('!'))
      : null;
  final user = TwitchMessage.resolveUser(
    login: ircPrefLogin ?? defaultLogin ?? displayName,
    displayName: displayName.isNotEmpty ? displayName : null,
  );

  final messageId = ircMsg.tags['id'] ?? ircMsg.tags['message-id'];
  // Text is in trailing; no-colon messages use param[1].
  final text =
      ircMsg.trailing ?? (ircMsg.params.length > 1 ? ircMsg.params[1] : '');
  final ircReplyParentId = ircMsg.tags['reply-parent-msg-id'];
  final ircReplyThreadRootId =
      ircMsg.tags['reply-thread-parent-msg-id'] ?? ircReplyParentId;

  // IRC ACTION messages (/me) are wrapped in \x01ACTION ... \x01.
  var isAction = false;
  String strippedText = text;
  var prefixLen = 0;
  if (strippedText.startsWith('\x01ACTION ') && strippedText.endsWith('\x01')) {
    isAction = true;
    strippedText = strippedText.substring(8, strippedText.length - 1);
    // Emote positions are relative to the ACTION body, not the wrapper.
  }

  // Strip "@username " prefix from reply echoes; adjust emote positions by
  // prefixLen.
  if (ircReplyParentId != null) {
    final prefixMatch = _replyPrefixRe.firstMatch(strippedText);
    if (prefixMatch != null) {
      prefixLen += prefixMatch.end;
      strippedText = strippedText.substring(prefixMatch.end);
    }
  }
  final ircReplyUser = ircMsg.tags['reply-parent-display-name'];
  final ircReplyText = ircMsg.tags['reply-parent-msg-body'];

  final tsMs = ircMsg.tags['tmi-sent-ts'];
  final effectiveTimestamp =
      timestamp ??
      (tsMs != null
          ? DateTime.fromMillisecondsSinceEpoch(int.parse(tsMs), isUtc: true)
          : DateTime.now().toUtc());

  final userId = ircMsg.tags['user-id'] ?? defaultUserId;
  final color = ircMsg.tags['color'] != null && ircMsg.tags['color']!.isNotEmpty
      ? ircMsg.tags['color']!
      : pickColor(user.login);

  // source-room-id != room-id means mirrored (foreign) message.
  final sourceRoomId = ircMsg.tags['source-room-id'];
  final sourceBroadcasterId =
      (sourceRoomId != null &&
          sourceRoomId.isNotEmpty &&
          sourceRoomId != ircMsg.tags['room-id'])
      ? sourceRoomId
      : null;
  // source-id: stable across mirrored copies; `id` is room-local.
  final sourceMessageId = ircMsg.tags['source-id'];

  // Bits tag highlights like sub notices.
  final bitsAmount = int.tryParse(ircMsg.tags['bits'] ?? '');

  // Tags for ping evaluation: msg-id, custom-reward-id,
  // pinned-chat-paid-amount.
  final msgId = ircMsg.tags['msg-id'];
  final customRewardId = ircMsg.tags['custom-reward-id'];
  final pinnedPaidAmount = ircMsg.tags['pinned-chat-paid-amount'];

  return TwitchMessage(
    login: user.login,
    displayName: user.displayName,
    text: strippedText,
    channel: channel,
    messageId: messageId,
    timestamp: effectiveTimestamp,
    userId: userId,
    color: color,
    isAction: isAction,
    replyToParentId: ircReplyParentId,
    replyToUser: ircReplyUser,
    replyToText: ircReplyText,
    replyThreadRootId: ircReplyThreadRootId,
    emotePositions: parseIrcEmotePositions(
      ircMsg.tags['emotes'],
      originalText: text,
      strippedText: strippedText,
      prefixLen: prefixLen,
    ),
    badges: parseIrcBadges(ircMsg.tags['badges']),
    sourceBroadcasterId: sourceBroadcasterId,
    sourceMessageId:
        (sourceBroadcasterId != null &&
            sourceMessageId != null &&
            sourceMessageId.isNotEmpty)
        ? sourceMessageId
        : null,
    isFirstMessage: ircMsg.tags['first-msg'] == '1',
    msgId: msgId,
    customRewardId: customRewardId,
    pinnedPaidAmount: pinnedPaidAmount,
    bitsAmount: bitsAmount,
    systemAccent: bitsAmount != null ? announcementColors['PRIMARY'] : null,
    isHistory: isHistory,
  );
}
