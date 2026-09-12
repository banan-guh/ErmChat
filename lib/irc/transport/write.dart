import 'connection.dart';

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
    final msg = '${tag}PRIVMSG #$channelName :$text';
    sendLine(msg);
  }
}
