import 'widget_test_harness.dart';

import 'package:ermchat/widgets/glass_chrome.dart';

void main() {
  testWidgets('PillFocusGlow stays flat until an inner field focuses', (
    WidgetTester tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PillFocusGlow(child: TextField(focusNode: focusNode)),
        ),
      ),
    );
    await tester.pump();

    BoxDecoration decoration() {
      final box = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byType(PillFocusGlow),
          matching: find.byType(AnimatedContainer),
        ),
      );
      return box.decoration! as BoxDecoration;
    }

    final unfocused = decoration();
    expect((unfocused.border! as Border).top.color.a, 0);
    expect(unfocused.boxShadow, isEmpty);

    // Focus resolves in a microtask, so the first pump applies it and the
    // second rebuilds with the glow.
    focusNode.requestFocus();
    await tester.pump();
    await tester.pump();

    final focused = decoration();
    expect((focused.border! as Border).top.color.a, greaterThan(0));
    expect(focused.boxShadow, isNotEmpty);

    focusNode.unfocus();
    await tester.pump();
    await tester.pump();
    expect(decoration().boxShadow, isEmpty);
  });
}
