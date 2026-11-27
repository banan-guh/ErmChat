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

  testWidgets('classic loading fills the field and yields to progress', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    final busy = ValueNotifier<bool>(true);
    final progress = ValueNotifier<double?>(null);
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    addTearDown(busy.dispose);
    addTearDown(progress.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageInput(
            controller: controller,
            focusNode: focusNode,
            onSend: () {},
            fillProgress: progress,
            busyListenable: busy,
            isBusy: () => busy.value,
          ),
        ),
      ),
    );

    final line = find.byType(LinearProgressIndicator);
    final fade = find.byKey(const Key('classic_busy_fade'));
    expect(line, findsOneWidget);
    expect(
      tester.getSize(line).height,
      closeTo(tester.getSize(find.byType(TextField)).height, 0.5),
    );
    expect(tester.widget<AnimatedOpacity>(fade).opacity, 1);

    progress.value = 0.5;
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(fade).opacity, 0);

    progress.value = null;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.widget<AnimatedOpacity>(fade).opacity, 1);

    busy.value = false;
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(fade).opacity, 0);
  });
}
