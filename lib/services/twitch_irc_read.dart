import 'dart:async';
import 'package:flutter/foundation.dart';
import 'twitch_irc.dart';
import 'base_irc_connection.dart';

class IrcReadService extends BaseIrcConnection {
  final _ownMessageController = StreamController<IrcMessage>.broadcast();

  Stream<IrcMessage> get onOwnMessage => _ownMessageController.stream;

  @override
  String get debugPrefix => 'IRC read';

  IrcReadService({super.connectivity});

  @override
  void dispatchLine(String line) {
    if (line.contains('PRIVMSG ') && username != null) {
      final msg = parseIrcMessage(line);
      if (msg != null && msg.command == 'PRIVMSG' && msg.prefix != null) {
        final sender = msg.prefix!.contains('!')
            ? msg.prefix!.split('!')[0].toLowerCase()
            : msg.prefix!.toLowerCase();
        if (sender == username) {
          _ownMessageController.add(msg);
        }
      }
    }
  }

  @override
  void dispose() {
    _ownMessageController.close();
    super.dispose();
  }

  @visibleForTesting
  void emitOwnMessage(IrcMessage msg) => _ownMessageController.add(msg);
}
