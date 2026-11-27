import 'package:ermchat/composer/composer_bar.dart';
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

  testWidgets('compact splash hides while the keyboard is up', (tester) async {
    await pumpJoined(tester, density: LayoutDensity.compact);
    final prefs = await Prefs.load();
    final spec = ChromeTheme.ermchat.spec.copyWith(compact: true);
    await prefs.setCustomChromeThemes([spec]);
    await prefs.setChromeThemeKey('${Prefs.customChromeThemePrefix}0');
    await settlePrefs(tester);

    final home = tester.element(find.byType(HomeScreen));
    final chat = ProviderScope.containerOf(home).read(chatProvider);
    final info = chat.channelFor('testchannel')!.info;
    final input = find.byKey(inputBarKey);
    final field = find.byKey(const Key('message_input'));
    double clearance() => IslandScope.maybeOf(
      tester.element(find.byType(CustomScrollView).first),
    )!.metrics.clearance(page: 'testchannel');

    final inputH = tester.getSize(input).height;

    // The splash lives in its own footer line, not the field's placeholder.
    const short = 'Live with 1 viewer';
    info.setStatus(short, live: true);
    await tester.pumpAndSettle();
    expect(find.text(short), findsOneWidget);
    expect(
      tester.widget<TextField>(field).decoration!.hintText,
      isNot(short),
      reason: 'compact status is not folded into the input hint',
    );
    expect(tester.getSize(input).height, inputH);
    expect(
      find.ancestor(of: find.text(short), matching: find.byType(AnimatedSize)),
      findsOneWidget,
      reason: 'keyboard down keeps the normal footer ease',
    );

    // Once the splash is up, its ticks must not move the chat.
    final live = clearance();
    const long =
        'Live with 123456 viewers for 123h 59m · Slow (30s) · Followers only';
    info.setStatus(long, live: true);
    await tester.pumpAndSettle();
    expect(find.text(long), findsOneWidget);
    expect(
      clearance(),
      closeTo(live, 0.5),
      reason: 'the chat does not drift when the splash text changes',
    );
    info.setStatus('Live with 7 viewers', live: true);
    await tester.pumpAndSettle();
    expect(clearance(), closeTo(live, 0.5));

    // Typing keeps the splash visible and the chat still.
    await tester.tap(field);
    await tester.enterText(field, 'hello');
    await tester.pumpAndSettle();
    expect(find.text('Live with 7 viewers'), findsOneWidget);
    expect(clearance(), closeTo(live, 0.5));

    // With the keyboard up the footer is clipped away with the row, so its
    // splash no longer adds an offset to any page.
    await tester.pump();
    for (final kb in <double>[100, 200, 300]) {
      tester.view.viewInsets = FakeViewPadding(bottom: kb);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 400));
    final open = clearance();
    info.setStatus('Live with 7 viewers for 2h 3m', live: true);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getSize(input).height, inputH);
    expect(
      clearance(),
      closeTo(open, 0.5),
      reason:
          'a clipped splash adds no channel offset while the keyboard is up',
    );

    // Closing the keyboard brings the splash and its ease back.
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Live with 7 viewers for 2h 3m'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Live with 7 viewers for 2h 3m'),
        matching: find.byType(AnimatedSize),
      ),
      findsOneWidget,
    );
  });

  testWidgets('dankchat4 puts the splash above the busy line and row', (
    tester,
  ) async {
    await pumpJoined(
      tester,
      density: LayoutDensity.full,
      chromeTheme: ChromeTheme.dankchat4.name,
    );
    final home = tester.element(find.byType(HomeScreen));
    final chat = ProviderScope.containerOf(home).read(chatProvider);
    final island = find.byKey(const ValueKey('composer_island'));
    final emptyIslandHeight = tester.getSize(island).height;
    const status = 'Live with 42 viewers for 1h 2m';
    void expectSplash() {
      final text = find.text(status);
      final statusRow = find.byKey(const ValueKey('island_status'));
      expect(text, findsOneWidget);
      expect(tester.widget<Text>(text).textAlign, TextAlign.left);
      expect(find.ancestor(of: text, matching: statusRow), findsOneWidget);
      expect(
        find.ancestor(
          of: text,
          matching: find.byKey(const ValueKey('island_footer')),
        ),
        findsNothing,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('island_footer'))).height,
        0,
      );
      expect(
        tester.getRect(statusRow).left,
        closeTo(tester.getRect(island).left, 0.5),
      );
      expect(
        tester.getRect(statusRow).width,
        closeTo(tester.getRect(island).width, 0.5),
      );
      expect(
        tester.getRect(text).left,
        closeTo(tester.getRect(statusRow).left + 20, 0.5),
      );
      expect(
        tester.getRect(find.byKey(inputBarKey)).bottom,
        lessThanOrEqualTo(tester.getRect(text).top),
      );
      expect(
        tester.getRect(text).bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const Key('bottom_chrome_bar'))).top,
        ),
      );
      expect(tester.getSize(island).height, greaterThan(emptyIslandHeight));
    }

    chat.channelFor('testchannel')!.info.setStatus(status, live: true);
    await tester.pumpAndSettle();
    expectSplash();

    final prefs = await Prefs.load();
    await prefs.setCustomChromeThemes([ChromeTheme.dankchat4.spec]);
    await prefs.setChromeThemeKey('${Prefs.customChromeThemePrefix}0');
    await settlePrefs(tester);
    expectSplash();
  });

  testWidgets('dankchat3 keeps the splash left in the footer', (tester) async {
    await pumpJoined(
      tester,
      density: LayoutDensity.full,
      chromeTheme: ChromeTheme.dankchat3.name,
    );
    final home = tester.element(find.byType(HomeScreen));
    final chat = ProviderScope.containerOf(home).read(chatProvider);
    final island = find.byKey(const ValueKey('composer_island'));
    const status = 'Live with 42 viewers for 1h 2m';
    void expectSplash() {
      final text = find.text(status);
      final footer = find.byKey(const ValueKey('island_footer'));
      expect(tester.widget<Text>(text).textAlign, TextAlign.left);
      expect(find.ancestor(of: text, matching: footer), findsOneWidget);
      expect(
        tester.getRect(footer).left,
        closeTo(tester.getRect(island).left, 0.5),
      );
      expect(
        tester.getRect(footer).width,
        closeTo(tester.getRect(island).width, 0.5),
      );
      expect(
        tester.getRect(text).left,
        closeTo(tester.getRect(footer).left + 20, 0.5),
      );
    }

    chat.channelFor('testchannel')!.info.setStatus(status, live: true);
    await tester.pumpAndSettle();
    expectSplash();

    final prefs = await Prefs.load();
    await prefs.setCustomChromeThemes([ChromeTheme.dankchat3.spec]);
    await prefs.setChromeThemeKey('${Prefs.customChromeThemePrefix}0');
    await settlePrefs(tester);
    expectSplash();
  });

  testWidgets('calendar is hidden while the archive is off', (tester) async {
    await pumpJoined(
      tester,
      density: LayoutDensity.full,
      chromeTheme: ChromeTheme.dankchat4.name,
    );
    await Settings.archiveEnabled.set(false);
    await settlePrefs(tester);

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    expect(find.text('Calendar'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await Settings.archiveEnabled.set(true);
    await settlePrefs(tester);
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    expect(find.text('Calendar'), findsOneWidget);
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
