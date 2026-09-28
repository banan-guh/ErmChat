import 'package:ermchat/widgets/badge_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('tapping a badge shows its name', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: BadgeChip(
              label: '6-Month Subscriber',
              child: SizedBox(width: 24, height: 24),
            ),
          ),
        ),
      ),
    );
    expect(find.text('6-Month Subscriber'), findsNothing);

    await tester.tap(find.byType(BadgeChip));
    await tester.pumpAndSettle();
    expect(find.text('6-Month Subscriber'), findsOneWidget);
  });
}
