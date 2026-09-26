import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/widgets/chat_body.dart';
import 'package:ermchat/widgets/message_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('reply header is a bottom sheet and drags down to dismiss', (
    WidgetTester tester,
  ) async {
    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ReplyHeader(
                message: TwitchMessage(
                  login: 'alice',
                  text: 'parent msg',
                  channel: 'testchannel',
                ),
                onDismiss: () => dismissed = true,
              ),
            ],
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

  testWidgets('reply overlay toggle and dismiss throws nothing', (
    WidgetTester tester,
  ) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    var replyActive = false;
    late StateSetter setLocal;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setLocal = setState;
              return ChatBody(
                bodyBuilder:
                    (
                      context, {
                      required hideChromeForKeyboard,
                      required maxWidth,
                      required maxHeight,
                      required keyboardH,
                      required composerH,
                    }) => const SizedBox.expand(
                      child: ColoredBox(color: Colors.black),
                    ),
                threadPanel: const SizedBox.shrink(),
                mentionsPanel: const SizedBox.shrink(),
                modViewPanel: const SizedBox.shrink(),
                emotePickerBuilder: (_, {required sheetBoxHeight}) =>
                    const SizedBox.shrink(),
                autocomplete: const SizedBox.shrink(),
                emoteMaxFraction: 0.5,
                keyboardH: 0,
                replyHeader: replyActive
                    ? ReplyHeader(
                        message: TwitchMessage(
                          login: 'alice',
                          text: 'parent msg',
                          channel: 'c',
                        ),
                        onDismiss: () => setLocal(() => replyActive = false),
                      )
                    : null,
                composer: MessageInput(
                  controller: controller,
                  focusNode: focus,
                  onSend: () {},
                  enabled: true,
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    setLocal(() => replyActive = true);
    await tester.pumpAndSettle();
    expect(find.textContaining('Replying to @alice'), findsOneWidget);

    await tester.drag(find.byType(BottomSheet), const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(find.textContaining('Replying to @alice'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reply toggle does not remount the emote sheet', (
    WidgetTester tester,
  ) async {
    final sheetCtrl = DraggableScrollableController();
    addTearDown(sheetCtrl.dispose);
    var replyActive = false;
    late StateSetter setLocal;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setLocal = setState;
              return ChatBody(
                bodyBuilder:
                    (
                      context, {
                      required hideChromeForKeyboard,
                      required maxWidth,
                      required maxHeight,
                      required keyboardH,
                      required composerH,
                    }) => const SizedBox.expand(
                      child: ColoredBox(color: Colors.black),
                    ),
                threadPanel: const SizedBox.shrink(),
                mentionsPanel: const SizedBox.shrink(),
                modViewPanel: const SizedBox.shrink(),
                emotePickerBuilder: (_, {required sheetBoxHeight}) =>
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      height: sheetBoxHeight,
                      child: ScaleTransition(
                        scale: const AlwaysStoppedAnimation(1.0),
                        child: LayoutBuilder(
                          builder: (context, constraints) => IgnorePointer(
                            ignoring: false,
                            child: DraggableScrollableSheet(
                              controller: sheetCtrl,
                              initialChildSize: 0.5,
                              minChildSize: 0,
                              maxChildSize: 0.5,
                              builder: (_, _) => const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      ),
                    ),
                autocomplete: const SizedBox.shrink(),
                emoteMaxFraction: 0.5,
                keyboardH: 0,
                replyHeader: replyActive
                    ? ReplyHeader(
                        message: TwitchMessage(
                          login: 'alice',
                          text: 'parent msg',
                          channel: 'c',
                        ),
                        onDismiss: () => setLocal(() => replyActive = false),
                      )
                    : null,
                composer: const SizedBox(height: 56),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    setLocal(() => replyActive = true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    setLocal(() => replyActive = false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
