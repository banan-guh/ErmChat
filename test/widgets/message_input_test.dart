import 'widget_test_harness.dart';

void main() {
  testWidgets('the keyboard send action sends and keeps focus', (tester) async {
    for (final borderless in [true, false]) {
      var sent = 0;
      final controller = TextEditingController(text: 'hi');
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          home: Scaffold(
            body: MessageInput(
              controller: controller,
              focusNode: focusNode,
              onSend: () => sent++,
              borderless: borderless,
            ),
          ),
        ),
      );
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(sent, 1, reason: 'borderless $borderless');
      expect(focusNode.hasFocus, isTrue, reason: 'borderless $borderless');
    }
  });
}
