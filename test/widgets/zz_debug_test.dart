import 'package:flutter/rendering.dart';
import 'widget_test_harness.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    HomeScreen.disableJoinSpinner = true;
  });

  testWidgets('ZZ hit path probe', (WidgetTester tester) async {
    final eventSub = FakeEventSubService();
    final irc = FakeIrcService();
    final ircRead = FakeIrcReadService();
    final recent = ConfigurableRecentMessagesService(const []);
    await tester.pumpWidget(
      TwitchChatApp(
        key: UniqueKey(),
        eventSubService: eventSub,
        ircService: irc,
        ircReadService: ircRead,
        recentMessagesService: recent,
        initialCurrentUserLogin: 'me',
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'b');
    await tester.tap(find.text('Join', skipOffstage: false));
    await tester.pump();

    ircRead.emitMessage(
      TwitchMessage(
        login: 'carol',
        text: 'hello @me',
        channel: 'b',
        messageId: 'm-panel-1',
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.notifications_active));
    await tester.pumpAndSettle();

    final row = find.textContaining('hello @me', skipOffstage: false);
    for (var i = 0; i < row.evaluate().length; i++) {
      final center = tester.getCenter(row.at(i));
      final result = HitTestResult();
      WidgetsBinding.instance.hitTest(result, center);
      final path = result.path
          .map((e) => e.target.runtimeType.toString())
          .toList();
      debugPrint('ZZ [$i] center=$center');
      // Print only the interesting part: render objects near the leaf.
      debugPrint('ZZ [$i] leaf path: ${path.take(12).join(' < ')}');
    }
  });
}
