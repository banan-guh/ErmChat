import 'connection.dart';

final _lineBreakRe = RegExp(r'[\r\n]+');

/// Chat write socket: sends PRIVMSG and emits raw frames. Stays join-free;
/// the read socket ([IrcReadService]) owns every JOIN.
class IrcService extends IrcConnection {
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
    // A line break would end the command and send the rest as raw IRC.
    final line = text.replaceAll(_lineBreakRe, ' ');
    final msg = '${tag}PRIVMSG #$channelName :$line';
    sendLine(msg);
  }
}
