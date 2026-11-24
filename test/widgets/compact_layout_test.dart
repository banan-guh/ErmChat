import 'package:ermchat/util/chrome_theme.dart';
import 'package:ermchat/util/layout_density.dart';
import 'package:ermchat/util/prefs.dart';
import 'package:ermchat/util/prefs_store.dart';
import 'package:ermchat/util/settings.dart';
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
    required LayoutDensity density,
    String? chromeTheme,
  }) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    tester.view.viewInsets = FakeViewPadding.zero;
    tester.view.viewPadding = const FakeViewPadding(top: 72, bottom: 45);
    addTearDown(tester.view.reset);

    final values = <String, Object>{
      'access_token': 'test_token',
      'layout_density': density.name,
    };
    if (chromeTheme != null) values['chrome_theme'] = chromeTheme;
    SharedPreferences.setMockInitialValues(values);
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

    await tester.tap(find.byTooltip('Add channels'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'testchannel');
    await tester.tap(find.text('Add', skipOffstage: false));
    await tester.pumpAndSettle();

    fakeIrc.triggerConnect();
    fakeIrcRead.triggerConnect();
    fakeIrc.triggerJoin('testchannel');
    fakeIrcRead.triggerJoin('testchannel');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
  }

  Future<void> setDensity(WidgetTester tester, LayoutDensity density) async {
    await Prefs.load();
    await Settings.layoutDensity.set(density);
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

  testWidgets('flipping density keeps the channel and focus', (tester) async {
    await pumpJoined(tester, density: LayoutDensity.full);

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

  // A softlock: with the view menu in the row or the field, hiding the input
  // took the menu with it, and the menu is the only way back.
  testWidgets('hiding the input never hides the view menu', (tester) async {
    await pumpJoined(tester, density: LayoutDensity.compact);
    final prefs = await Prefs.load();
    final dankchat4 = ChromeTheme.dankchat4.spec;
    final placements = {
      'row': dankchat4,
      'field': dankchat4.copyWith(
        rowEnd: [ChromeAction.threads],
        fieldEnd: [FieldItem.action(ChromeAction.viewMenu)],
      ),
    };
    for (final MapEntry(key: place, value: spec) in placements.entries) {
      await Settings.showInput.set(true);
      await prefs.setCustomChromeThemes([spec]);
      await prefs.setChromeThemeKey('${Prefs.customChromeThemePrefix}0');
      await settlePrefs(tester);
      await Settings.showInput.set(false);
      await settlePrefs(tester);
      expect(
        find.byIcon(Icons.expand_more),
        findsOneWidget,
        reason: 'menu in the $place',
      );
      expect(
        find.byKey(const Key('bottom_chrome_bar')),
        findsNothing,
        reason: 'only the menu stays, menu in the $place',
      );
    }
  });
}
