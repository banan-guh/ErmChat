import 'dart:async';
import 'package:flutter/foundation.dart';
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

  IrcNoticeEvent({required this.channel, required this.message});
}

class IrcService extends BaseIrcConnection {
  final _banController = StreamController<IrcBanEvent>.broadcast();
  final _noticeController = StreamController<IrcNoticeEvent>.broadcast();
  final _jtvController = StreamController<IrcNoticeEvent>.broadcast();

  Stream<IrcBanEvent> get onBan => _banController.stream;
  Stream<IrcNoticeEvent> get onNotice => _noticeController.stream;
  Stream<IrcNoticeEvent> get onJtvMessage => _jtvController.stream;

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
    if (line.contains('NOTICE ')) {
      _handleNotice(line);
      return;
    }
    if (line.contains('PRIVMSG ') && line.contains(':jtv ')) {
      _handleJtvMessage(line);
    }
  }

  void _handleClearChat(String line) {
    final msg = parseIrcMessage(line);
    if (msg == null || msg.command != 'CLEARCHAT') return;

    final channelName =
        msg.params.isNotEmpty ? msg.params[0].substring(1) : null;
    if (channelName == null) return;

    final targetUser = msg.trailing;
    if (targetUser == null || targetUser.isEmpty) return;

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

  void _handleNotice(String line) {
    final msg = parseIrcMessage(line);
    if (msg == null || msg.command != 'NOTICE') return;

    final channelName =
        msg.params.isNotEmpty ? msg.params[0].substring(1) : null;
    if (channelName == null || msg.trailing == null) return;

    _noticeController.add(
      IrcNoticeEvent(channel: channelName, message: msg.trailing!),
    );
  }

  void _handleJtvMessage(String line) {
    final msg = parseIrcMessage(line);
    if (msg == null || msg.trailing == null) return;

    final channelName =
        msg.params.isNotEmpty ? msg.params[0].substring(1) : null;
    if (channelName == null) return;

    _jtvController.add(
      IrcNoticeEvent(channel: channelName, message: msg.trailing!),
    );
  }

  @override
  void dispose() {
    _banController.close();
    _noticeController.close();
    _jtvController.close();
    super.dispose();
  }
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
