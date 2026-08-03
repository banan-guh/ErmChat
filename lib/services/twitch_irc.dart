import 'dart:async';
import 'package:flutter/foundation.dart';
import '../color_utils.dart';
import '../models/twitch_badge.dart';
import '../models/twitch_message.dart';
import '../util/irc_utils.dart';
import 'base_irc_connection.dart';

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

/// A full channel clear (`/clear`): CLEARCHAT with no target user. Unlike
/// bans/timeouts, there is no target — every chat message is removed.
class IrcChannelClearEvent {
  final String channel;

  IrcChannelClearEvent({required this.channel});
}

/// Room-mode state (slow mode, followers-only, emote-only, subs-only, r9k).
/// Sent on join and again whenever a mode changes. `followersOnly` is "-1"
/// when off, "0" when always on, otherwise the minutes.
class IrcRoomStateEvent {
  final String channel;
  final int? slowSeconds;
  final String? followersOnly;
  final bool emoteOnly;
  final bool subsOnly;
  final bool r9k;

  /// Raw tag map; updates are partial (only changed tags), so callers that
  /// need the full state must merge with the previous event.
  final Map<String, String> tags;

  IrcRoomStateEvent({
    required this.channel,
    this.slowSeconds,
    this.followersOnly,
    required this.emoteOnly,
    required this.subsOnly,
    required this.r9k,
    required this.tags,
  });
}

/// Own user state per channel (badges at JOIN). Global badges arrive once
/// via GLOBALUSERSTATE instead.
class IrcUserStateEvent {
  final String channel;
  final List<MessageBadge>? badges;

  IrcUserStateEvent({required this.channel, this.badges});
}

class IrcGlobalUserStateEvent {
  final List<MessageBadge>? badges;

  IrcGlobalUserStateEvent({this.badges});
}

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

/// A USERNOTICE event (sub, resub, subgift, raid, announcement, etc.).
/// `systemMsg` is Twitch's pre-formatted notice text (e.g. "x has subscribed
/// for 6 months!"); it is always empty for announcements, where `text` holds
/// the announcement message. `emotePositions` are parsed from the `emotes`
/// tag relative to `text` (only announcements carry a meaningful message).
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

/// Builds the system-message text for a USERNOTICE event. Announcements are
/// the bare "Announcement" label (DankChat-style; the announcement text is
/// rendered as a separate child chat message); everything else uses Twitch's
/// `system-msg` (with the user's own message appended for sub/resub).
String buildUserNoticeText({
  required String msgId,
  required String displayName,
  String? systemMsg,
  String? text,
}) {
  if (msgId == 'announcement') return 'Announcement';
  final base = systemMsg;
  if (base == null || base.isEmpty) return '$displayName $msgId.';
  if ((msgId == 'sub' || msgId == 'resub') && (text?.isNotEmpty ?? false)) {
    return '$base "${text!.trim()}"';
  }
  return base;
}

/// Builds the system-message text for a CLEARCHAT ban/timeout.
String buildBanText({
  required String user,
  required bool isTimeout,
  int? durationSec,
}) {
  if (isTimeout) {
    return '$user was timed out${durationSec != null ? ' for ${durationSec}s' : ''}.';
  }
  return '$user was banned.';
}

/// Parses the IRC `emotes` tag into [EmotePosition]s. Tag positions are
/// relative to [originalText]; [prefixLen] is the number of characters
/// stripped from the front (ACTION wrapper, reply prefix) and [strippedText]
/// is the text those adjusted positions are measured against.
List<EmotePosition>? parseIrcEmotePositions(
  String? emotesTag, {
  required String originalText,
  required String strippedText,
  int prefixLen = 0,
}) {
  if (emotesTag == null || emotesTag.isEmpty) return null;
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
      if (start < 0 || end >= originalText.length) continue;
      final emoteCode = originalText.substring(start, end + 1);
      final adjStart = start - prefixLen;
      final adjEnd = (end + 1) - prefixLen;
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

class IrcService extends BaseIrcConnection {
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
  final _userStateController = StreamController<IrcUserStateEvent>.broadcast(
    sync: true,
  );
  final _globalUserStateController =
      StreamController<IrcGlobalUserStateEvent>.broadcast(sync: true);

  Stream<IrcBanEvent> get onBan => _banController.stream;
  Stream<IrcNoticeEvent> get onNotice => _noticeController.stream;
  Stream<IrcNoticeEvent> get onJtvMessage => _jtvController.stream;
  Stream<IrcChannelClearEvent> get onChannelClear => _clearController.stream;
  Stream<IrcRoomStateEvent> get onRoomState => _roomStateController.stream;
  Stream<IrcUserStateEvent> get onUserState => _userStateController.stream;
  Stream<IrcGlobalUserStateEvent> get onGlobalUserState =>
      _globalUserStateController.stream;
  Stream<IrcMessageDeletedEvent> get onMessageDeleted =>
      _deleteController.stream;
  Stream<TwitchMessage> get onMessage => _messageController.stream;
  Stream<UserNoticeEvent> get onUserNotice => _userNoticeController.stream;

  @override
  String get debugPrefix => 'IRC';

  IrcService({super.connectivity});

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
  void dispatchLine(String line) {
    if (line.contains('CLEARCHAT ')) {
      _handleClearChat(line);
      return;
    }
    if (line.contains('CLEARMSG ')) {
      _handleClearMsg(line);
      return;
    }
    if (line.contains('USERNOTICE ')) {
      _handleUserNotice(line);
      return;
    }
    // GLOBALUSERSTATE contains "USERSTATE " as a substring — check first.
    // It also carries no params, so the command ends the line (no trailing
    // space like the other handlers expect).
    if (line.contains('GLOBALUSERSTATE ') || line.endsWith('GLOBALUSERSTATE')) {
      _handleGlobalUserState(line);
      return;
    }
    if (line.contains('USERSTATE ')) {
      _handleUserState(line);
      return;
    }
    if (line.contains('ROOMSTATE ')) {
      _handleRoomState(line);
      return;
    }
    if (line.contains('NOTICE ')) {
      _handleNotice(line);
      return;
    }
    if (line.contains('PRIVMSG ')) {
      if (line.contains(':jtv ')) {
        _handleJtvMessage(line);
      } else {
        _handleChatMessage(line);
      }
    }
  }

  void _handleClearChat(String line) {
    final msg = parseIrcMessage(line);
    if (msg == null || msg.command != 'CLEARCHAT') return;

    final channelName = msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    if (channelName == null) return;

    final targetUser = msg.trailing;
    // CLEARCHAT without a target is a full channel clear (/clear) — every
    // message is removed, there is no user to ban.
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

  void _handleClearMsg(String line) {
    final msg = parseIrcMessage(line);
    if (msg == null || msg.command != 'CLEARMSG') return;

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

  void _handleNotice(String line) {
    final msg = parseIrcMessage(line);
    if (msg == null || msg.command != 'NOTICE') return;

    final channelName = msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    if (channelName == null || msg.trailing == null) return;

    _noticeController.add(
      IrcNoticeEvent(
        channel: channelName,
        message: msg.trailing!,
        msgId: msg.tags['msg-id'],
      ),
    );
  }

  void _handleJtvMessage(String line) {
    final msg = parseIrcMessage(line);
    if (msg == null || msg.trailing == null) return;

    final channelName = msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    if (channelName == null) return;

    _jtvController.add(
      IrcNoticeEvent(channel: channelName, message: msg.trailing!),
    );
  }

  void _handleRoomState(String line) {
    final msg = parseIrcMessage(line);
    if (msg == null || msg.command != 'ROOMSTATE') return;

    final channelName = msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    if (channelName == null) return;

    _roomStateController.add(
      IrcRoomStateEvent(
        channel: channelName,
        slowSeconds: int.tryParse(msg.tags['slow'] ?? ''),
        followersOnly: msg.tags['followers-only'],
        emoteOnly: msg.tags['emote-only'] == '1',
        subsOnly: msg.tags['subs-only'] == '1',
        r9k: msg.tags['r9k'] == '1',
        tags: msg.tags,
      ),
    );
  }

  void _handleUserState(String line) {
    final msg = parseIrcMessage(line);
    if (msg == null || msg.command != 'USERSTATE') return;

    final channelName = msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    if (channelName == null) return;

    _userStateController.add(
      IrcUserStateEvent(
        channel: channelName,
        badges: parseIrcBadges(msg.tags['badges']),
      ),
    );
  }

  void _handleGlobalUserState(String line) {
    final msg = parseIrcMessage(line);
    if (msg == null || msg.command != 'GLOBALUSERSTATE') return;

    _globalUserStateController.add(
      IrcGlobalUserStateEvent(badges: parseIrcBadges(msg.tags['badges'])),
    );
  }

  void _handleUserNotice(String line) {
    final msg = parseIrcMessage(line);
    if (msg == null || msg.command != 'USERNOTICE') return;

    final channelName = msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    if (channelName == null) return;

    final ircPrefLogin = msg.prefix != null && msg.prefix!.contains('!')
        ? msg.prefix!.substring(0, msg.prefix!.indexOf('!'))
        : null;
    final login = (msg.tags['login'] ?? ircPrefLogin ?? '').toLowerCase();
    final displayName = msg.tags['display-name'] ?? login;
    final systemMsg = msg.tags['system-msg'] != null
        ? unescapeIrcTag(msg.tags['system-msg']!)
        : null;
    final text = msg.trailing;

    _userNoticeController.add(
      UserNoticeEvent(
        channel: channelName,
        msgId: msg.tags['msg-id'] ?? '',
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

  void _handleChatMessage(String line) {
    final msg = parseIrcMessage(line);
    if (msg == null || msg.command != 'PRIVMSG' || msg.trailing == null) {
      return;
    }
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

  @visibleForTesting
  void emitChatMessage(TwitchMessage msg) => _messageController.add(msg);

  @visibleForTesting
  void emitUserNotice(UserNoticeEvent event) =>
      _userNoticeController.add(event);

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
    _userStateController.close();
    _globalUserStateController.close();
    super.dispose();
  }
}

/// Parses an IRC PRIVMSG into a [TwitchMessage]. Shared by the live chat
/// socket, the read-only own-message socket, and history parsing;
/// `defaultLogin`/`defaultDisplayName`/`defaultUserId` are used when the
/// message lacks a user prefix or tags (own echoes). `timestamp`/`isHistory`
/// override the defaults for robotty history lines.
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

  final messageId = ircMsg.tags['id'];
  // PRIVMSG text normally comes in the trailing; messages without a colon
  // carry the whole text as a single param instead.
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
    prefixLen += 8;
  }

  // Twitch IRC prepends "@username " to reply echoes. Strip this prefix
  // so the stored text matches what the user sees; emote positions from IRC
  // tags use original-text coordinates and must be adjusted by prefixLen below.
  if (ircReplyParentId != null) {
    final prefixMatch = RegExp(r'^\s*@\S+\s+').firstMatch(strippedText);
    if (prefixMatch != null) {
      prefixLen += prefixMatch.end;
      strippedText = strippedText.substring(prefixMatch.end);
    }
  }
  final ircReplyUser = unescapeIrcTagNullable(
    ircMsg.tags['reply-parent-display-name'],
  );
  final ircReplyText = unescapeIrcTagNullable(
    ircMsg.tags['reply-parent-msg-body'],
  );

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

  // Shared chat: source-room-id carries the channel the message originated in.
  final sourceRoomId = ircMsg.tags['source-room-id'];
  final sourceBroadcasterId = (sourceRoomId != null && sourceRoomId.isNotEmpty)
      ? sourceRoomId
      : null;

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
    isHistory: isHistory,
  );
}

IrcMessage? parseIrcMessage(String line) {
  try {
    String? tags;
    String? prefix;
    String command;
    List<String> params = [];
    String? trailing;

    int pos = 0;

    if (line.startsWith('@')) {
      final end = line.indexOf(' ');
      if (end == -1) return null;
      tags = line.substring(1, end);
      pos = end + 1;
    }

    if (pos < line.length && line[pos] == ':') {
      final end = line.indexOf(' ', pos);
      if (end == -1) return null;
      prefix = line.substring(pos + 1, end);
      pos = end + 1;
    }

    final rest = line.substring(pos);
    final parts = rest.split(' ');
    command = parts[0];

    int i = 1;
    while (i < parts.length) {
      if (parts[i].startsWith(':')) {
        trailing = parts.sublist(i).join(' ').substring(1);
        break;
      }
      params.add(parts[i]);
      i++;
    }

    final tagMap = <String, String>{};
    if (tags != null) {
      for (final tag in tags.split(';')) {
        final eq = tag.indexOf('=');
        if (eq != -1) {
          String decoded;
          try {
            decoded = Uri.decodeComponent(tag.substring(eq + 1));
          } catch (_) {
            decoded = tag.substring(eq + 1);
          }
          // Strip orphaned UTF-16 surrogates: low surrogates alone or high
          // surrogates not followed by low (Flutter's text engine crashes on
          // isolated surrogates from malformed Twitch IRC data).
          decoded = decoded.replaceAll(RegExp(r'[\uDC00-\uDFFF]'), '');
          decoded = decoded.replaceAll(
            RegExp(r'[\uD800-\uDBFF](?![\uDC00-\uDFFF])'),
            '',
          );
          tagMap[tag.substring(0, eq)] = decoded;
        }
      }
    }

    return IrcMessage(
      tags: tagMap,
      prefix: prefix,
      command: command,
      params: params,
      trailing: trailing,
    );
  } catch (_) {
    debugPrint('[parseIrcMessage] failed to parse line: $line');
    return null;
  }
}

class IrcMessage {
  final Map<String, String> tags;
  final String? prefix;
  final String command;
  final List<String> params;
  final String? trailing;

  IrcMessage({
    required this.tags,
    this.prefix,
    required this.command,
    required this.params,
    this.trailing,
  });
}
