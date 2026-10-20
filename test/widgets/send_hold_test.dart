import 'package:ermchat/widgets/send_hold.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Two fingers by design: spam must never start from one stray hold.
  testWidgets('spam runs only while send and the spam button are both held', (
    tester,
  ) async {
    final calls = <String>[];
    final sends = ValueNotifier(0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: SendHold(
              enabled: true,
              onRecall: () => calls.add('recall'),
              onRecallUndo: () => calls.add('undo'),
              onSpamStart: () => calls.add('start'),
              onSpamStop: () => calls.add('stop'),
              spamSends: sends,
              child: const Icon(Icons.send, size: 48),
            ),
          ),
        ),
      ),
    );

    final send = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.send)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 200));
    expect(calls, ['recall']);
    final button = find.byIcon(Icons.repeat);
    expect(button, findsOneWidget, reason: 'holding send shows the button');
    expect(
      tester.getCenter(button).dx,
      lessThan(200),
      reason: 'it sits in the corner across from send',
    );

    final spam = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls, ['recall'], reason: 'the button needs a full hold');
    await tester.pump(const Duration(milliseconds: 150));
    expect(calls, ['recall', 'undo', 'start']);

    await spam.up();
    await tester.pump();
    expect(calls.last, 'stop');
    expect(button, findsOneWidget, reason: 'send is still held');

    await send.up();
    await tester.pumpAndSettle();
    expect(button, findsNothing);
    expect(calls, ['recall', 'undo', 'start', 'stop']);
  });
}
