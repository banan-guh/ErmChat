import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/widgets/message_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('reply header is a bottom sheet and drags down to dismiss', (
    WidgetTester tester,
  ) async {
    var dismissed = false;
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageInput(
            controller: controller,
            focusNode: focus,
            onSend: () {},
            enabled: true,
            replyToMsg: TwitchMessage(
              login: 'alice',
              text: 'parent msg',
              channel: 'testchannel',
            ),
            onCancelReply: () => dismissed = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Replying to @alice'), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);

    await tester.drag(find.byType(BottomSheet), const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(dismissed, isTrue);
  });
}
