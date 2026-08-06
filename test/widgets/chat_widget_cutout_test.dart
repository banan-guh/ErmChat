import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/services/twitch_eventsub.dart';
import 'package:ermchat/widgets/chat_widget_cutout.dart';

PollEvent _poll() => PollEvent(
  channel: 'c',
  kind: 'begin',
  title: 'A or B?',
  choices: [
    PollChoice(title: 'A', votes: 10),
    PollChoice(title: 'B', votes: 5),
  ],
  status: 'ACTIVE',
);

HypeTrainEvent _hypeTrain() => HypeTrainEvent(
  channel: 'c',
  kind: 'begin',
  level: 1,
  progress: 10,
  total: 50,
  expiresAt: DateTime.now().add(const Duration(minutes: 5)),
  topContributions: [
    HypeTrainContribution(userName: 'bitsuser', type: 'BITS', total: 100),
  ],
);

void main() {
  testWidgets('cutout swipes between pages and minimize fires callback', (
    tester,
  ) async {
    final controller = PageController();
    var minimized = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatWidgetCutout(
            pages: [
              PollCard(event: _poll()),
              HypeTrainCard(event: _hypeTrain()),
            ],
            controller: controller,
            onMinimize: () => minimized++,
          ),
        ),
      ),
    );

    expect(find.text('A or B?'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('Hype Train'), findsOneWidget);
    expect(find.text('A or B?'), findsNothing);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    expect(minimized, 1);

    controller.dispose();
  });

  testWidgets('minimized bar shows active labels with a restore button', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatWidgetMinimizedBar(
            labels: 'Poll / Prediction',
            onRestore: () {},
          ),
        ),
      ),
    );

    expect(find.text('Poll / Prediction'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);
  });
}
