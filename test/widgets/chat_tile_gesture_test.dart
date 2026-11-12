import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/widgets/chat_message_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TwitchMessage _message() => TwitchMessage(
  login: 'alice',
  text: 'hello there',
  channel: 'test',
  messageId: 'm1',
  userId: 'u1',
);

Future<void> _pump(
  WidgetTester tester, {
  required VoidCallback onCopy,
  required VoidCallback onMenu,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChatMessageTile(
          message: _message(),
          channel: 'test',
          surface: Colors.black,
          textScale: 1,
          buildBadgeSpans: (channel, msg, {badgeScale = 1}) => const [],
          buildMessageSpans:
              (
                msg,
                channel,
                surface, {
                colored = false,
                textScale = 1,
                onImageTap,
              }) => [TextSpan(text: msg.text)],
          bodyIsCached: (msg, spans) => false,
          onTapUser: (context, login, userId) {},
          onLongPressUser: (context) => onCopy(),
          onLongPress: (context) => onMenu(),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('long press copies the name instead of opening the menu', (
    tester,
  ) async {
    var copied = 0;
    var menu = 0;
    await _pump(tester, onCopy: () => copied++, onMenu: () => menu++);

    final row = tester.getRect(find.byType(ChatMessageTile));
    await tester.longPressAt(Offset(row.left + 6, row.center.dy));
    await tester.pump();

    expect((copied, menu), (1, 0));
  });

  testWidgets('long press away from the name still opens the menu', (
    tester,
  ) async {
    var copied = 0;
    var menu = 0;
    await _pump(tester, onCopy: () => copied++, onMenu: () => menu++);

    final row = tester.getRect(find.byType(ChatMessageTile));
    await tester.longPressAt(Offset(row.right - 6, row.center.dy));
    await tester.pump();

    expect((copied, menu), (0, 1));
  });
}
