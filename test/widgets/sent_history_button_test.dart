import 'dart:math' as math;

import 'package:ermchat/widgets/sent_history_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('history opens above its button and the keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    final history = ValueNotifier<List<String>>([
      for (var i = 0; i < 50; i++) 'message $i',
    ]);
    addTearDown(history.dispose);
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            resizeToAvoidBottomInset: true,
            body: Column(
              children: [
                const Expanded(child: SizedBox.expand()),
                SentHistoryButton(
                  history: history,
                  onSelect: (text) => selected = text,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final button = find.byIcon(Icons.history);
    final buttonTop = tester.getRect(button).top;
    await tester.tap(button);
    await tester.pumpAndSettle();

    final list = find.byType(ListView);
    expect(list, findsOneWidget);
    expect(
      tester.getRect(list).bottom,
      lessThanOrEqualTo(math.min(buttonTop, 800 - 320)),
      reason: 'the list must stay above both its anchor and the keyboard',
    );

    await tester.tap(find.text('message 0'));
    await tester.pumpAndSettle();
    expect(selected, 'message 0');
    expect(list, findsNothing);
  });

  testWidgets('history falls below a top anchored button', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final history = ValueNotifier<List<String>>([
      for (var i = 0; i < 50; i++) 'message $i',
    ]);
    addTearDown(history.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SentHistoryButton(history: history, onSelect: (_) {}),
              const Expanded(child: SizedBox.expand()),
            ],
          ),
        ),
      ),
    );

    final button = find.byIcon(Icons.history);
    final buttonBottom = tester.getRect(button).bottom;
    await tester.tap(button);
    await tester.pumpAndSettle();

    final list = find.byType(ListView);
    expect(list, findsOneWidget);
    expect(tester.getRect(list).top, greaterThanOrEqualTo(buttonBottom));
    expect(tester.getRect(list).bottom, lessThanOrEqualTo(800));
  });
}
