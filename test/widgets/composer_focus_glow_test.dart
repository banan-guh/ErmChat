import 'widget_test_harness.dart';

void main() {
  Future<FocusNode> pumpGlow(WidgetTester tester, {required bool enabled}) {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    return tester
        .pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ComposerFocusGlow(
                enabled: enabled,
                radius: kGlassComposerRadius,
                child: TextField(focusNode: focusNode),
              ),
            ),
          ),
        )
        .then((_) => focusNode);
  }

  double outlineAlpha(WidgetTester tester) {
    final box = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(ComposerFocusGlow),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final decoration = box.foregroundDecoration! as BoxDecoration;
    return (decoration.border! as Border).top.color.a;
  }

  testWidgets('glows while an inner field holds focus', (tester) async {
    final focusNode = await pumpGlow(tester, enabled: true);
    expect(outlineAlpha(tester), 0);
    final size = tester.getSize(find.byType(TextField));

    // Focus resolves in a microtask, so the first pump applies it and the
    // second rebuilds with the glow.
    focusNode.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(outlineAlpha(tester), greaterThan(0));
    expect(
      tester.getSize(find.byType(TextField)),
      size,
      reason: 'the glow paints as a foreground and never resizes the field',
    );

    focusNode.unfocus();
    await tester.pump();
    await tester.pump();
    expect(outlineAlpha(tester), 0);
  });

  testWidgets('stays flat when disabled', (tester) async {
    final focusNode = await pumpGlow(tester, enabled: false);
    focusNode.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
    expect(outlineAlpha(tester), 0);
  });
}
