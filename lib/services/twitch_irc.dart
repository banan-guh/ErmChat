import 'dart:async';
import 'package:flutter/foundation.dart';
import '../color_utils.dart';
import '../models/twitch_badge.dart';
import '../models/twitch_message.dart';
import '../util/irc_utils.dart';
import 'base_irc_connection.dart';

final _loneLowSurrogateRe = RegExp(r'[\uDC00-\uDFFF]');
final _orphanedHighSurrogateRe = RegExp(r'[\uD800-\uDBFF](?![\uDC00-\uDFFF])');
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

  /// Raw tag map; updates are partial (only changed tags), so callers that
  /// need the full state must merge with the previous event.
  final Map<String, String> tags;

  IrcRoomStateEvent({required this.channel, required this.tags});
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

/// USERNOTICE `msg-id` values that represent subscriptions / gift subs.
/// These render like default (PRIMARY purple) announcements: the notice
/// stays a system message but carries the announcement accent.
const subNoticeMsgIds = <String>{
  'sub',
  'resub',
  'subgift',
  'anonsubgift',
  'communitygift',
  'submysterygift',
  'giftpaidupgrade',
  'anongiftpaidupgrade',
  'primepaidupgrade',
};

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
/// measured against the message body: for regular messages that is
/// [originalText], and for ACTION (/me) messages Twitch reports them relative
/// to the text after the `\x01ACTION ` wrapper. [prefixLen] is the number of
/// characters stripped from the front after that (reply prefix) and
/// [strippedText] is the text those adjusted positions are measured against.
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

/// Converts a position from the IRC `emotes` tag (which counts each
/// supplementary/astral code point - any emoji or other non-BMP character -
/// as a single offset) into a UTF-16 code unit index into [text], which is how
/// Dart strings are indexed internally. Every supplementary character before
/// the offset occupies 2 UTF-16 units but only counts as 1 in the tag, so each
/// one shifts the resulting index forward by 1. Returns -1 if [tagOffset]
/// exceeds the number of code points in [text].
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
  final _whisperController = StreamController<TwitchMessage>.broadcast(
    sync: true,
  );
  // Channel-scoped emote-set ids: USERSTATE carries the channel its sets
  // belong to; GLOBALUSERSTATE emits null (account-wide union).
  final _emoteSetsController =
      StreamController<(String?, List<String>)>.broadcast(sync: true);

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
    // Parse each line exactly once and dispatch on the parsed command; the
    // old contains()-based routing matched trailing chat text and silently
    // dropped or misrouted messages whose text contained command words.
    final msg = parseIrcMessage(line);
    if (msg == null) return;
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
      // Both carry the emote-sets tag, the authoritative source of which
      // emote sets the account can use (the Helix /chat/emotes/user endpoint
      // is known to omit certain grants, e.g. bot accounts).
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
    if (emoteSets == null || emoteSets.isEmpty) return;
    final ids = emoteSets
        .split(',')
        .where((id) => id.trim().isNotEmpty)
        .toList();
    if (ids.isEmpty) return;
    // USERSTATE is sent per joined channel and its emote-sets are scoped to
    // that channel; GLOBALUSERSTATE is the account-wide union (null channel).
    final channel = msg.command == 'USERSTATE' && msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    _emoteSetsController.add((channel, ids));
  }

  void _handleRoomState(IrcMessage msg) {
    final channelName = msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    if (channelName == null) return;

    _roomStateController.add(
      IrcRoomStateEvent(channel: channelName, tags: msg.tags),
    );
  }

  void _handleUserNotice(IrcMessage msg) {
    final channelName = msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    if (channelName == null) return;

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

  final messageId = ircMsg.tags['id'] ?? ircMsg.tags['message-id'];
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
    // Twitch reports emote positions for ACTION messages relative to the
    // message body after the \x01ACTION wrapper (see parseIrcEmotePositions),
    // so the wrapper must not count as a stripped prefix offset.
  }

  // Twitch IRC prepends "@username " to reply echoes. Strip this prefix
  // so the stored text matches what the user sees; emote positions from IRC
  // tags use original-text coordinates and must be adjusted by prefixLen below.
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
    isFirstMessage: ircMsg.tags['first-msg'] == '1',
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
          // Twitch IRCv3 tags are backslash-escaped, not percent-encoded.
          String decoded = unescapeIrcTag(tag.substring(eq + 1));
          // Strip orphaned UTF-16 surrogates: low surrogates alone or high
          // surrogates not followed by low (Flutter's text engine crashes on
          // isolated surrogates from malformed Twitch IRC data).
          decoded = decoded.replaceAll(_loneLowSurrogateRe, '');
          decoded = decoded.replaceAll(_orphanedHighSurrogateRe, '');
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
