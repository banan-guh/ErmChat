import 'widget_test_harness.dart';

void main() {
  // The 48pt emote/send icons ignore theme density, so the text line must
  // too, or a compact theme lifts it above their centerline.
  for (final density in [VisualDensity.standard, VisualDensity.compact]) {
    for (final borderless in [true, false]) {
      testWidgets('text centers on the icons '
          '(density ${density.vertical}, borderless $borderless)', (
        tester,
      ) async {
        final controller = TextEditingController();
        final focusNode = FocusNode();
        addTearDown(controller.dispose);
        addTearDown(focusNode.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(visualDensity: density),
            home: Scaffold(
              body: Center(
                child: MessageInput(
                  controller: controller,
                  focusNode: focusNode,
                  onSend: () {},
                  borderless: borderless,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final text = tester.getCenter(find.byType(EditableText)).dy;
        final send = tester.getCenter(find.byIcon(Icons.send)).dy;
        expect(text, closeTo(send, 0.5));
      });
    }
  }
}
