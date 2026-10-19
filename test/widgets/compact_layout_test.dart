import 'package:ermchat/util/chrome_theme.dart';
import 'package:ermchat/util/layout_density.dart';
import 'package:ermchat/util/prefs.dart';
import 'package:ermchat/util/prefs_store.dart';
import 'widget_test_harness.dart';

// Compact layout end to end: the app bar folds away, the bell and menu dock
// in the composer's bottom row, the join tab stays last in the strip, and the
// welcome view keeps the app bar.
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

    await tester.tap(find.byTooltip('Join channel'));
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

  Finder inBottomBar(Finder f) => find.descendant(
    of: find.byKey(const Key('bottom_chrome_bar')),
    matching: f,
  );

  Future<void> setDensity(WidgetTester tester, LayoutDensity density) async {
    await (await Prefs.load()).setLayoutDensity(density);
    PrefsStore.instance.notifyChanged();
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
  }

  Future<void> settlePrefs(WidgetTester tester) async {
    PrefsStore.instance.notifyChanged();
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('a compact layout keeps emote in the field, not the row', (
    tester,
  ) async {
    await pumpJoined(tester, glass: false, density: LayoutDensity.compact);

    final rowEmote = inBottomBar(find.byIcon(Icons.emoji_emotions_outlined));
    expect(rowEmote, findsNothing);

    // The same layout without compact leaves the emote button in the row.
    final prefs = await Prefs.load();
    await prefs.setCustomChromeThemes([
      ChromeTheme.ermchat.spec.copyWith(
        compact: false,
        fieldStart: [],
        fieldEnd: [FieldItem.send],
      ),
    ]);
    await prefs.setChromeThemeKey('${Prefs.customChromeThemePrefix}0');
    await settlePrefs(tester);
    expect(rowEmote, findsOneWidget);
  });

  for (final glass in [false, true]) {
    testWidgets('the bottom row holds the actions and panel titles fold '
        '(glass=$glass)', (tester) async {
      await pumpJoined(tester, glass: glass, density: LayoutDensity.compact);

      expect(inStrip(find.byIcon(Icons.add)), findsOneWidget);
      expect(
        inBottomBar(find.byIcon(Icons.notifications_active)),
        findsOneWidget,
      );
      expect(inBottomBar(find.byIcon(Icons.more_vert)), findsOneWidget);

      // The strip clears the status bar now that nothing sits above it.
      expect(tester.getRect(find.byType(TabBar)).top, greaterThanOrEqualTo(24));

      // The join tab opens the join dialog without leaving the channel.
      await tester.tap(inStrip(find.byIcon(Icons.add)));
      await tester.pumpAndSettle();
      expect(find.text('Join', skipOffstage: false), findsWidgets);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // The panel title folds into its tabs, one row with the back button.
      await tester.tap(inBottomBar(find.byIcon(Icons.notifications_active)));
      await tester.pumpAndSettle();
      expect(find.text('Mentions / Whispers'), findsNothing);
      final whispers = find.widgetWithText(Tab, 'Whispers');
      final back = find.byTooltip('Back');
      expect(whispers, findsOneWidget);
      expect(back, findsOneWidget);
      expect(
        tester.getCenter(back).dy,
        closeTo(tester.getCenter(whispers).dy, 4),
      );
    });

    testWidgets('full keeps the join tab in the strip (glass=$glass)', (
      tester,
    ) async {
      await pumpJoined(tester, glass: glass, density: LayoutDensity.full);

      expect(inStrip(find.byIcon(Icons.add)), findsOneWidget);
      expect(
        inBottomBar(find.byIcon(Icons.notifications_active)),
        findsOneWidget,
      );
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
