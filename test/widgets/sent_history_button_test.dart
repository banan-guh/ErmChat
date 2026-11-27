import 'package:ermchat/widgets/sent_history_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('native history menu is oldest first and opens at newest', (
    tester,
  ) async {
    final history = ValueNotifier<List<String>>([
      for (var i = 49; i >= 0; i--) 'message $i',
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

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    final firstItem = find.byType(PopupMenuItem<String>).first;
    final latestItem = find.byType(PopupMenuItem<String>).last;
    expect(firstItem, findsOneWidget);
    expect(latestItem, findsOneWidget);
    expect(
      tester.getTopLeft(find.text('message 0')).dy,
      lessThan(tester.getTopLeft(find.text('message 49')).dy),
      reason: 'oldest is at the top and newest is at the bottom',
    );
    final position = Scrollable.maybeOf(
      tester.element(find.text('message 49')),
    )!.position;
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 0.5),
      reason: 'the menu opens scrolled to the newest message',
    );

    await tester.tap(find.text('message 49'));
    await tester.pumpAndSettle();
    expect(selected, 'message 49');
    expect(find.byType(PopupMenuItem<String>), findsNothing);
  });
}
