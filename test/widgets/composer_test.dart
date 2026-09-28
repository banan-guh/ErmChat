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
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatBody(
            liquidGlass: liquidGlass,
            emoteMaxFraction: 0.5,
            composer: TextField(
              key: const Key('message_input'),
              focusNode: focus,
            ),
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

  // Full-app harness: the real HomeScreen wiring, joined and connected, so the
  // field is enabled and a plain tap can be checked in both chrome modes. The
  // glass pref defaults to true in code and is read async, so the app always
  // starts on the pill and hands off to the in-flow path: that hand-off is
  // exactly where the focus node used to be dropped.
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
