import 'package:ermchat/util/layout_density.dart';
import 'package:ermchat/util/prefs.dart';
import 'package:ermchat/util/prefs_store.dart';
import 'widget_test_harness.dart';

// Compact layout end to end: the app bar folds into the tab strip (join as
// the last tab, bell and menu pinned right), the welcome view keeps the app
// bar, and flipping density mid-session keeps the channel and the focus.
void main() {
  setUp(() {
    HomeScreen.disableJoinSpinner = true;
  });

  Future<void> pumpJoined(
    WidgetTester tester, {
    required bool glass,
    required LayoutDensity density,
  }) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    tester.view.viewInsets = FakeViewPadding.zero;
    tester.view.viewPadding = const FakeViewPadding(top: 72, bottom: 45);
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({
      'access_token': 'test_token',
      'liquid_glass': glass,
      'layout_density': density.name,
    });
    FlutterSecureStorage.setMockInitialValues({
      'accounts': '[{"login":"me","user_id":"42","access_token":"test_token"}]',
      'active_login': 'me',
    });

    final fakeIrc = FakeIrcService();
    final fakeIrcRead = FakeIrcReadService();
    await tester.pumpWidget(
      TwitchChatApp(
        key: UniqueKey(),
        eventSubService: FakeEventSubService(),
        recentMessagesService: FakeRecentMessagesService(),
        ircService: fakeIrc,
        ircReadService: fakeIrcRead,
      ),
    );
    await tester.pump();

    // No channels yet: the welcome view keeps the app bar in both modes.
    expect(find.text('ErmChat'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'testchannel');
    await tester.tap(find.text('Join', skipOffstage: false));
    await tester.pumpAndSettle();

    fakeIrc.triggerConnect();
    fakeIrcRead.triggerConnect();
    fakeIrc.triggerJoin('testchannel');
    fakeIrcRead.triggerJoin('testchannel');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
  }

  Finder inStrip(Finder f) => find.descendant(
    of: find.ancestor(of: find.byType(TabBar), matching: find.byType(Row)),
    matching: f,
  );

  Future<void> setDensity(WidgetTester tester, LayoutDensity density) async {
    await (await Prefs.load()).setLayoutDensity(density);
    PrefsStore.instance.notifyChanged();
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
  }

  for (final glass in [false, true]) {
    testWidgets('compact merges the app bar into the strip (glass=$glass)', (
      tester,
    ) async {
      await pumpJoined(tester, glass: glass, density: LayoutDensity.compact);

      expect(find.text('ErmChat'), findsNothing);
      expect(inStrip(find.byIcon(Icons.add)), findsOneWidget);
      expect(inStrip(find.byIcon(Icons.notifications_active)), findsOneWidget);
      expect(inStrip(find.byIcon(Icons.more_vert)), findsOneWidget);

      // The strip clears the status bar now that nothing sits above it.
      final strip = tester.getRect(find.byType(TabBar));
      expect(strip.top, greaterThanOrEqualTo(24));

      // The join tab opens the join dialog without leaving the channel.
      await tester.tap(inStrip(find.byIcon(Icons.add)));
      await tester.pumpAndSettle();
      expect(find.text('Join', skipOffstage: false), findsWidgets);
    });

    testWidgets('compact folds the panel title into its tabs (glass=$glass)', (
      tester,
    ) async {
      await pumpJoined(tester, glass: glass, density: LayoutDensity.compact);
      await tester.tap(inStrip(find.byIcon(Icons.notifications_active)));
      await tester.pumpAndSettle();

      expect(find.text('Mentions / Whispers'), findsNothing);
      final whispers = find.widgetWithText(Tab, 'Whispers');
      final back = find.byTooltip('Back');
      expect(whispers, findsOneWidget);
      expect(back, findsOneWidget);
      // One row: the back button sits beside the tabs, not above them.
      expect(
        tester.getCenter(back).dy,
        closeTo(tester.getCenter(whispers).dy, 4),
      );
    });

    testWidgets('full keeps the separate app bar (glass=$glass)', (
      tester,
    ) async {
      await pumpJoined(tester, glass: glass, density: LayoutDensity.full);

      expect(find.text('ErmChat'), findsOneWidget);
      expect(inStrip(find.byIcon(Icons.add)), findsNothing);
      expect(inStrip(find.byIcon(Icons.notifications_active)), findsNothing);

      await tester.tap(find.byIcon(Icons.notifications_active));
      await tester.pumpAndSettle();
      expect(find.text('Mentions / Whispers'), findsOneWidget);
    });

    testWidgets('flipping density keeps the channel and focus (glass=$glass)', (
      tester,
    ) async {
      await pumpJoined(tester, glass: glass, density: LayoutDensity.full);

      final input = find.byKey(const Key('message_input'));
      await tester.tap(input);
      await tester.pump();
      final node = tester.widget<TextField>(input).focusNode!;
      expect(node.hasFocus, isTrue);

      for (final density in [
        LayoutDensity.compact,
        LayoutDensity.full,
        LayoutDensity.compact,
      ]) {
        await setDensity(tester, density);
        final compact = density == LayoutDensity.compact;
        expect(find.text('ErmChat'), compact ? findsNothing : findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(TabBar),
            matching: find.text('testchannel'),
          ),
          findsOneWidget,
        );
        expect(node.hasFocus, isTrue, reason: 'flip to $density');
        expect(tester.testTextInput.isVisible, isTrue);
      }
    });
  }
}
