import 'dart:async';
import 'twitch_irc.dart';
import 'base_irc_connection.dart';

class IrcReadService extends BaseIrcConnection {
  final _ownMessageController = StreamController<IrcMessage>.broadcast();
  final _userColorController = StreamController<String>.broadcast();

  Stream<IrcMessage> get onOwnMessage => _ownMessageController.stream;
  Stream<String> get onUserColor => _userColorController.stream;

  @override
  String get debugPrefix => 'IRC read';

  IrcReadService({super.connectivity});

  @override
  void dispatchLine(String line) {
    if (line.contains('GLOBALUSERSTATE') || line.contains('USERSTATE')) {
      final msg = parseIrcMessage(line);
      if (msg != null) {
        final color = msg.tags['color'];
        if (color != null && color.isNotEmpty) {
          _userColorController.add(color);
        }
      }
      return;
    }

    // Own-message detection via IRC prefix (user@user.host). username was
    // lowercased at connect time so comparison is case-insensitive by design.
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
    _userColorController.close();
    super.dispose();
  }
}
