import 'package:ermchat/util/layout_density.dart';
import 'widget_test_harness.dart';

void main() {
  Future<void> pumpInput(
    WidgetTester tester, {
    required bool compact,
    required bool borderless,
  }) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => compactLayoutRoot(
          context,
          density: compact ? LayoutDensity.compact : LayoutDensity.full,
          child: child!,
        ),
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
  }

  for (final borderless in [true, false]) {
    // The icons ignore theme density, so the text line must too, or compact
    // lifts it above their centerline.
    for (final compact in [false, true]) {
      testWidgets('text centers on the icons '
          '(compact $compact, borderless $borderless)', (tester) async {
        await pumpInput(tester, compact: compact, borderless: borderless);
        final text = tester.getCenter(find.byType(EditableText)).dy;
        final send = tester.getCenter(find.byIcon(Icons.send)).dy;
        expect(text, closeTo(send, 0.5));
      });
    }

    testWidgets('compact is shorter (borderless $borderless)', (tester) async {
      await pumpInput(tester, compact: false, borderless: borderless);
      final full = tester.getSize(find.byType(MessageInput)).height;
      await pumpInput(tester, compact: true, borderless: borderless);
      final compact = tester.getSize(find.byType(MessageInput)).height;
      debugPrint('borderless=$borderless full=$full compact=$compact');
      expect(compact, lessThan(full));
    });
  }
}
