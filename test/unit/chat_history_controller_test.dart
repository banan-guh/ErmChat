import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/client/session.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/chat_history_controller.dart';
import 'package:ermchat/services/ignore_manager.dart';
import 'package:ermchat/services/ping_manager.dart';
import 'package:ermchat/services/recent_messages.dart';
import 'package:ermchat/services/user_store.dart';
import 'package:flutter_test/flutter_test.dart';

ChatHistoryController _controller(Chat chat) => ChatHistoryController(
  chat: chat,
  session: Session(),
  recentMessages: RecentMessagesService(),
  ignoreManager: IgnoreManager(),
  pingManager: PingManager(),
  userStore: UserStore(),
  maxMessages: () => 500,
  recentMessagesLimit: () => 100,
);

void main() {
  test('mergeHistory does not resurrect a removed channel', () {
    final chat = Chat();
    addTearDown(chat.dispose);
    chat.ensure('test');
    final controller = _controller(chat);

    chat.remove('test');
    controller.mergeHistory('test', [
      TwitchMessage(login: 'a', text: 'hi', messageId: 'm1', channel: 'test'),
    ]);

    expect(chat.contains('test'), isFalse);
    expect(chat.names, isEmpty);
    expect(chat.mentions.isEmpty, isTrue);
  });
}
