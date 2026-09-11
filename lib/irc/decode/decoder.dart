import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/twitch_message.dart';
import '../../util/log.dart';
import '../message.dart';
import 'codec.dart';
import 'events.dart';

/// Lifts typed domain events out of raw IRC frames. One instance per socket:
/// the read decoder gets the socket's nick provider for own-echo detection,
/// the write decoder takes none.
class IrcChatDecoder {
  IrcChatDecoder(
    Stream<IrcMessage> source, {
    String? Function()? nickProvider,
    String debugPrefix = 'IRC read',
    bool isReadSocket = true,
  }) : _nickProvider = nickProvider, // ignore: prefer_initializing_formals
       _debugPrefix = debugPrefix, // ignore: prefer_initializing_formals
       _isReadSocket = isReadSocket { // ignore: prefer_initializing_formals
    _subscription = source.listen(_handle);
  }

  final String? Function()? _nickProvider;
  final String _debugPrefix;

  /// False for the write socket: NOTICE star frames surface as send
  /// rejections there, and ROOMSTATE confirmations stay unlogged.
  final bool _isReadSocket;
  late final StreamSubscription<IrcMessage> _subscription;

  final _banController = StreamController<IrcBanEvent>.broadcast();
  final _noticeController = StreamController<IrcNoticeEvent>.broadcast();
  final _jtvController = StreamController<IrcNoticeEvent>.broadcast();
  final _deleteController =
      StreamController<IrcMessageDeletedEvent>.broadcast();
  final _messageController = StreamController<TwitchMessage>.broadcast(
    sync: true,
  );
  final _ownMessageController = StreamController<IrcMessage>.broadcast();
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
  final _emoteSetsController =
      StreamController<(String?, List<String>)>.broadcast(sync: true);

  // Own badge set-ids per channel. Feeds slow-mode bypass checks.
  final selfBadges = <String?, Set<String>>{};

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
  Stream<IrcMessage> get onOwnMessage => _ownMessageController.stream;

  void clearSelfBadges() => selfBadges.clear();

  /// Test hook into the same handler the raw stream uses.
  @visibleForTesting
  void feed(IrcMessage msg) => _handle(msg);

  void _handle(IrcMessage msg) {
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
    // Target `*` (or absent) is the login-failure channel. The transport
    // owns that outcome; the read decoder only surfaces channel notices.
    // The write socket surfaces its own send rejections the same way it
    // always did, including star-targeted ones.
    if (channelParam == null || channelParam == '*') {
      if (_isReadSocket) return;
      final starChannel = channelParam ?? '';
      if (msg.trailing == null) return;
      _noticeController.add(
        IrcNoticeEvent(
          channel: starChannel,
          message: msg.trailing!,
          msgId: msg.tags['msg-id'],
        ),
      );
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
    if (_isReadSocket) {
      PerfLog.I.record('JOINQ', '[$_debugPrefix] confirm #$channelName');
    }

    _roomStateController.add(
      IrcRoomStateEvent(channel: channelName, tags: msg.tags),
    );
  }

  void _handleUserNotice(IrcMessage msg) {
    final channelName = msg.params.isNotEmpty
        ? msg.params[0].substring(1)
        : null;
    if (channelName == null) return;

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

    _messageController.add(parseIrcChatMessage(msg, channel: channelName));

    // Own messages arrive on the read socket too. Emit on both controllers:
    // onMessage for regular chat, onOwnMessage for self-timeout heal and
    // reply-highlight tracking. Read-side only: no nick, no echo.
    final sender = msg.prefix != null && msg.prefix!.contains('!')
        ? msg.prefix!.substring(0, msg.prefix!.indexOf('!')).toLowerCase()
        : null;
    if (sender == _nickProvider?.call()) {
      _ownMessageController.add(msg);
    }
  }

  void _handleWhisper(IrcMessage msg) {
    if (msg.trailing == null) return;
    _whisperController.add(parseIrcChatMessage(msg, channel: null));
  }

  void dispose() {
    _subscription.cancel();
    _banController.close();
    _noticeController.close();
    _jtvController.close();
    _deleteController.close();
    _messageController.close();
    _ownMessageController.close();
    _userNoticeController.close();
    _clearController.close();
    _roomStateController.close();
    _whisperController.close();
    _emoteSetsController.close();
  }
}
