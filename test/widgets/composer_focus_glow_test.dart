import 'widget_test_harness.dart';

void main() {
  Future<FocusNode> pumpGlow(WidgetTester tester) {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    return tester
        .pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ComposerFocusGlow(
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(
                    Radius.circular(kComposerIslandRadius),
                  ),
                ),
                child: TextField(focusNode: focusNode),
              ),
            ),
          ),
        )
        .then((_) => focusNode);
  }

  double ringAlpha(WidgetTester tester) {
    final box = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(ComposerFocusGlow),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final decoration = box.foregroundDecoration as ShapeDecoration?;
    return (decoration?.shape as OutlinedBorder?)?.side.color.a ?? 0;
  }

  testWidgets('rings while focused without resizing the field', (tester) async {
    final focusNode = await pumpGlow(tester);
    expect(ringAlpha(tester), 0);
    final size = tester.getSize(find.byType(TextField));

    // Focus resolves in a microtask, so the first pump applies it and the
    // second rebuilds with the ring.
    focusNode.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(ringAlpha(tester), greaterThan(0));
    expect(
      tester.getSize(find.byType(TextField)),
      size,
      reason: 'focus only tints the ring and never resizes the field',
    );

    focusNode.unfocus();
    await tester.pump();
    await tester.pump();
    expect(ringAlpha(tester), 0);
  });
}
