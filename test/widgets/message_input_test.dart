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

    testWidgets('the keyboard send action sends and keeps focus '
        '(borderless $borderless)', (tester) async {
      var sent = 0;
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageInput(
              controller: TextEditingController(text: 'hi'),
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
      expect(sent, 1);
      expect(focusNode.hasFocus, isTrue);
    });

    testWidgets('compact keeps full-size buttons (borderless $borderless)', (
      tester,
    ) async {
      await pumpInput(tester, compact: true, borderless: borderless);
      for (final icon in [Icons.send, Icons.emoji_emotions_outlined]) {
        final ink = find.ancestor(
          of: find.byIcon(icon),
          matching: find.byType(InkWell),
        );
        expect(tester.getSize(ink), const Size(48, 48));
        // A dense field shrinks its icons to 18pt unless they set a size.
        final glyph = find.byIcon(icon);
        final size =
            tester.widget<Icon>(glyph).size ??
            IconTheme.of(tester.element(glyph)).size;
        expect(size, 24);
      }
    });
  }
}
