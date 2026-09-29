import 'package:ermchat/composer/composer_bar.dart' show inputBarKey;
import 'widget_test_harness.dart';

// Composer regressions, both chrome modes (glass pill and opaque in-flow):
//  - the field must focus on a plain tap;
//  - the shared inputBarKey must never mount twice and must keep the
//    composer's FocusNode alive across the pill -> in-flow hand-off;
//  - the pill bottom tracks the body bottom with a single safe area.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    HomeScreen.disableJoinSpinner = true;
  });

  // Bare ChatBody harness: geometry and hit-testing without the whole app.
  Future<void> pumpBody(
    WidgetTester tester, {
    required bool liquidGlass,
    required FocusNode focus,
    bool showComposer = true,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatBody(
            liquidGlass: liquidGlass,
            emoteMaxFraction: 0.5,
            composer: showComposer
                ? TextField(key: const Key('message_input'), focusNode: focus)
                : null,
            bodyBuilder:
                (
                  context, {
                  required hideChromeForKeyboard,
                  required maxWidth,
                  required maxHeight,
                  required keyboardH,
                  required composerH,
                }) => const SizedBox.expand(),
            threadPanel: const SizedBox.shrink(),
            mentionsPanel: const SizedBox.shrink(),
            modViewPanel: const SizedBox.shrink(),
            emotePickerBuilder: (_, {required sheetBoxHeight}) =>
                const SizedBox.shrink(),
            autocomplete: const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }

  Future<bool> tapBodyComposer(WidgetTester tester, FocusNode focus) async {
    final field = find.byKey(const Key('message_input'));
    expect(field, findsWidgets);
    focus.unfocus();
    await tester.pump();
    await tester.tap(field.last, warnIfMissed: false);
    await tester.pump();
    return focus.hasFocus;
  }

  testWidgets('non-glass composer is tappable', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await pumpBody(tester, liquidGlass: false, focus: focus);
    await tester.pumpAndSettle();
    expect(await tapBodyComposer(tester, focus), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('glass composer is tappable', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await pumpBody(tester, liquidGlass: true, focus: focus);
    await tester.pumpAndSettle();
    expect(await tapBodyComposer(tester, focus), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('toggling glass off leaves the composer tappable', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await pumpBody(tester, liquidGlass: true, focus: focus);
    await tester.pumpAndSettle();
    await pumpBody(tester, liquidGlass: false, focus: focus);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(await tapBodyComposer(tester, focus), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pill bottom tracks the body bottom without double safe area', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding.zero;
    tester.view.padding = const FakeViewPadding(bottom: 45);
    addTearDown(tester.view.reset);

    await pumpBody(tester, liquidGlass: true, focus: focus);
    await tester.pumpAndSettle();

    final pill = find.byKey(inputBarKey);
    expect(pill, findsOneWidget);
    expect(
      tester.getRect(pill).bottom,
      closeTo(800, 0.5),
      reason: 'pill bottom must sit on the body bottom, not 45dp above it',
    );
  });

  testWidgets('the two composer paths share one key without colliding', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await pumpBody(tester, liquidGlass: true, focus: focus);
    await tester.pumpAndSettle();
    // Glass on: the pill owns the key, the in-flow slot is empty.
    expect(find.byKey(inputBarKey), findsOneWidget);
    // Flip to opaque: the key moves to the in-flow composer, still one mount.
    await pumpBody(tester, liquidGlass: false, focus: focus);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(inputBarKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // A short screen collapses chrome once the keyboard opens (the iPhone
  // case). The pill must stay put: only the focus glow changes.
  testWidgets('keyboard chrome collapse keeps the pill', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    tester.view.physicalSize = const Size(400, 550);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpBody(tester, liquidGlass: true, focus: focus);
    await tester.pumpAndSettle();
    final pill = find.byKey(const ValueKey('composer_pill'));
    final width = tester.getSize(pill).width;
    await tester.tap(find.byKey(const Key('message_input')));
    await tester.pump();

    for (var kb = 50.0; kb <= 350; kb += 50) {
      tester.view.viewInsets = FakeViewPadding(bottom: kb);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();

    expect(pill, findsOneWidget);
    expect(tester.getSize(pill).width, width);
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    final glow = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(ComposerFocusGlow),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final outline = glow.decoration! as BoxDecoration;
    expect((outline.border! as Border).top.color.a, greaterThan(0));
  });

  // Fullscreen hides the nav bar: the composer eases down into the freed
  // inset instead of jumping, in both chrome modes.
  for (final glass in [false, true]) {
    testWidgets('nav bar inset eases away (glass: $glass)', (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(bottom: 48);
      tester.view.viewPadding = const FakeViewPadding(bottom: 48);
      addTearDown(tester.view.reset);
      await pumpBody(tester, liquidGlass: glass, focus: focus);
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('message_input'));
      final before = tester.getBottomLeft(field).dy;

      tester.view.padding = FakeViewPadding.zero;
      tester.view.viewPadding = FakeViewPadding.zero;
      await tester.pump();
      // The ease starts after the frame that saw the change.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 110));
      final mid = tester.getBottomLeft(field).dy;
      await tester.pumpAndSettle();
      final after = tester.getBottomLeft(field).dy;

      expect(after, closeTo(before + 48, 1));
      expect(mid, greaterThan(before + 5));
      expect(mid, lessThan(after - 5));
    });
  }

  // Keyboard close with the nav bar coming back must snap the nav pad. The
  // Scaffold already moves the body with the keyboard, so easing the pad on
  // top would read as a bounce up to the limit.
  for (final glass in [false, true]) {
    testWidgets('keyboard close snaps the nav pad (glass: $glass)', (
      tester,
    ) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      // Keyboard up with the nav bar hidden.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      tester.view.viewPadding = FakeViewPadding.zero;
      tester.view.padding = FakeViewPadding.zero;
      addTearDown(tester.view.reset);
      await pumpBody(tester, liquidGlass: glass, focus: focus);
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('message_input'));

      // Keyboard closes and the nav bar reappears in the same tick.
      tester.view.viewInsets = FakeViewPadding.zero;
      tester.view.viewPadding = const FakeViewPadding(bottom: 48);
      tester.view.padding = const FakeViewPadding(bottom: 48);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final early = tester.getBottomLeft(field).dy;
      await tester.pumpAndSettle();
      final settled = tester.getBottomLeft(field).dy;

      // Snapped: already at the limit right after the close, not easing up.
      expect(settled, lessThan(800 - 40));
      expect(early, closeTo(settled, 1));
    });
  }

  testWidgets('input toggle-off fades the field out with the pill', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await pumpBody(tester, liquidGlass: true, focus: focus);
    await tester.pumpAndSettle();

    await pumpBody(
      tester,
      liquidGlass: true,
      focus: focus,
      showComposer: false,
    );
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(const Key('message_input')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('message_input')), findsNothing);
    expect(find.byKey(const ValueKey('composer_pill')), findsNothing);
  });

  // Full-app harness: the real HomeScreen wiring, joined and connected, so the
  // field is enabled and a plain tap can be checked in both chrome modes.
  Future<void> pumpJoined(WidgetTester tester, {required bool glass}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    tester.view.viewInsets = FakeViewPadding.zero;
    tester.view.viewPadding = const FakeViewPadding(bottom: 45.0);
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({
      'access_token': 'test_token',
      'liquid_glass': glass,
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

  // Saved prefs apply before HomeScreen's first frame. Read async, the
  // first frames ran on defaults and the chrome animated over on start.
  testWidgets('full app: the first home frame uses the saved glass pref', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'liquid_glass': true});
    await tester.pumpWidget(
      TwitchChatApp(
        key: UniqueKey(),
        eventSubService: FakeEventSubService(),
        recentMessagesService: FakeRecentMessagesService(),
        ircService: FakeIrcService(),
        ircReadService: FakeIrcReadService(),
      ),
    );
    for (var i = 0; i < 20 && find.byType(HomeScreen).evaluate().isEmpty; i++) {
      await tester.pump();
    }
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('composer_pill')), findsOneWidget);
    // Let startup's socket lookups time out under fake time.
    await tester.pump(const Duration(milliseconds: 600));
  });

  for (final glass in <bool>[false, true]) {
    testWidgets('full app: composer focuses on a plain tap (glass=$glass)', (
      WidgetTester tester,
    ) async {
      await pumpJoined(tester, glass: glass);

      final input = find.byKey(const Key('message_input'));
      expect(input, findsOneWidget);
      expect(
        tester.widget<TextField>(input).enabled,
        isTrue,
        reason: 'composer must be enabled for a tap to focus it',
      );

      final node = tester.widget<TextField>(input).focusNode!;
      node.unfocus();
      await tester.pump();

      await tester.tap(input);
      await tester.pump();

      expect(
        node.hasFocus,
        isTrue,
        reason: 'tapping the composer must focus it (glass=$glass)',
      );
      expect(tester.takeException(), isNull);
    });
  }
}
