import 'widget_test_harness.dart';
import '../helpers.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    // Tests keep the app in a disconnected (never "online") state, so the join
    // button's loading spinner would spin forever and block the "+". Disable it
    // for the suite; the behavior itself is exercised in the real app.
    HomeScreen.disableJoinSpinner = true;
  });

  testWidgets(
    'Adding channel without credentials is view-only: sending blocked, '
    'incoming messages still render',
    (WidgetTester tester) async {
      final fakeEventSub = FakeEventSubService();
      final fakeIrc = FakeIrcService();
      final fakeIrcRead = FakeIrcReadService();
      final fakeRecent = FakeRecentMessagesService();

      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: fakeEventSub,
          ircService: fakeIrc,
          ircReadService: fakeIrcRead,
          recentMessagesService: fakeRecent,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'xqc');
      await tester.tap(find.text('Join', skipOffstage: false));
      await tester.pump();

      expect(
        find.text('Connect an account to chat', skipOffstage: false),
        findsOneWidget,
      );

      // Trying to send does nothing (input is disabled without credentials).
      await tester.enterText(
        find.byKey(const Key('message_input')),
        'hello chat',
      );
      await tester.tap(find.byIcon(Icons.send), warnIfMissed: false);
      await tester.pump();
      expect(find.textContaining('hello chat'), findsNothing);

      // EventSub messages still appear in view-only mode.
      fakeIrcRead.emitMessage(
        TwitchMessage(
          login: 'xqc',
          text: 'hello chat',
          channel: 'xqc',
          messageId: 'm1',
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        find.textContaining('hello chat', skipOffstage: false),
        findsOneWidget,
      );
    },
  );

  testWidgets('chrome menu toggles fullscreen and the composer', (
    WidgetTester tester,
  ) async {
    final modes = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          modes.add(call.arguments as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      TwitchChatApp(
        key: UniqueKey(),
        eventSubService: FakeEventSubService(),
        ircService: FakeIrcService(),
        ircReadService: FakeIrcReadService(),
        recentMessagesService: FakeRecentMessagesService(),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'xqc');
    await tester.tap(find.text('Join', skipOffstage: false));
    await tester.pumpAndSettle();

    Future<void> pick(String entry) async {
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry));
      await tester.pumpAndSettle();
    }

    // The webview has no platform view in tests, so Show stream is only
    // checked for presence, never tapped.
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    expect(find.text('Show stream'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    modes.clear();
    await pick('Toggle fullscreen');
    expect(modes.last, 'SystemUiMode.immersiveSticky');
    // The menu arrow survives fullscreen so the bars come back.
    await pick('Toggle fullscreen');
    expect(modes.last, 'SystemUiMode.edgeToEdge');

    expect(find.byType(MessageInput), findsOneWidget);
    await pick('Toggle input');
    expect(tester.takeException(), isNull);
    expect(find.byType(MessageInput), findsNothing);
    expect(find.text('xqc', skipOffstage: false), findsWidgets);

    await pick('Toggle input');
    expect(find.byType(MessageInput), findsOneWidget);

    // Hide with the keyboard open: no strand, no error.
    await tester.tap(find.byType(MessageInput));
    await tester.showKeyboard(find.byType(TextField).first);
    await tester.pump();
    await pick('Toggle input');
    expect(tester.takeException(), isNull);
    expect(find.byType(MessageInput), findsNothing);
  });

  group('stacked player with keyboard', () {
    testWidgets('keyboard swaps video for audio without remounting', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      tester.view.viewInsets = FakeViewPadding(bottom: 0);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(stackedPlayerHarness(showVideo: true));
      await tester.pumpAndSettle();
      expect(find.byKey(stackedVideoKey), findsOneWidget);
      expect(find.byKey(stackedAudioKey), findsNothing);
      final before = tester.element(find.byKey(stackedVideoKey));

      // Stream enabled + keyboard opening in the same frame.
      tester.view.viewInsets = FakeViewPadding(bottom: 300 * 3.0);
      await tester.pumpWidget(stackedPlayerHarness(showVideo: false));
      await tester.pumpAndSettle();
      expect(find.byKey(stackedVideoKey), findsOneWidget);
      expect(find.byKey(stackedAudioKey), findsOneWidget);
      // Same element: WebView state would survive the toggle.
      expect(
        identical(tester.element(find.byKey(stackedVideoKey)), before),
        isTrue,
      );

      // Rapid flapping never errors.
      for (final show in [true, false, true, false]) {
        await tester.pumpWidget(stackedPlayerHarness(showVideo: show));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
    });

    // The safe area animates as the keyboard crosses the gesture bar. Those
    // ticks rebuild ChatBody but must reuse the body, or every one rebuilds
    // the whole channel view.
    testWidgets('safe-area ticks reuse the chat body', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      tester.view.viewInsets = FakeViewPadding(bottom: 0);
      tester.view.padding = FakeViewPadding(bottom: 45 * 3.0);
      addTearDown(tester.view.reset);

      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            resizeToAvoidBottomInset: true,
            body: ChatBody(
              liquidGlass: true,
              bodyBuilder:
                  (
                    context, {
                    required hideChromeForKeyboard,
                    required maxWidth,
                    required maxHeight,
                    required keyboardH,
                    required composerH,
                  }) {
                    builds++;
                    return const SizedBox.expand();
                  },
              threadPanel: const SizedBox.shrink(),
              mentionsPanel: const SizedBox.shrink(),
              modViewPanel: const SizedBox.shrink(),
              emotePickerBuilder:
                  (_, {required sheetBoxHeight, required inset}) =>
                      const SizedBox.shrink(),
              autocomplete: const SizedBox.shrink(),
              emoteMaxFraction: 0.6,
              composer: const SizedBox(height: 56),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open past the safe area, then close back through it.
      for (final h in [10.0, 20.0, 30.0, 40.0, 300.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: h * 3.0);
        tester.view.padding = FakeViewPadding(
          bottom: (45 - h).clamp(0.0, 45.0) * 3.0,
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 300));
      final opened = builds;
      for (final h in [200.0, 40.0, 30.0, 20.0, 10.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: h * 3.0);
        tester.view.padding = FakeViewPadding(
          bottom: (45 - h).clamp(0.0, 45.0) * 3.0,
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      // Still open: no decision flipped, so no tick rebuilt the body.
      expect(builds, opened);
    });

    // Decisions read the learned open height, so a reopen flips the video
    // on its first tick and holds, instead of flipping when the live box
    // crosses the threshold mid-animation.
    testWidgets('video decision flips once on the first keyboard tick', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      tester.view.viewInsets = FakeViewPadding(bottom: 0);
      addTearDown(tester.view.reset);

      final seen = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            resizeToAvoidBottomInset: true,
            body: ChatBody(
              bodyBuilder:
                  (
                    context, {
                    required hideChromeForKeyboard,
                    required maxWidth,
                    required maxHeight,
                    required keyboardH,
                    required composerH,
                  }) {
                    seen.add(
                      shouldShowStreamVideo(
                        maxWidth: maxWidth,
                        maxHeight: maxHeight,
                        keyboardH: keyboardH,
                        inputH: composerH,
                        chatFontSize: 14,
                      ),
                    );
                    return const SizedBox.expand();
                  },
              threadPanel: const SizedBox.shrink(),
              mentionsPanel: const SizedBox.shrink(),
              modViewPanel: const SizedBox.shrink(),
              emotePickerBuilder:
                  (_, {required sheetBoxHeight, required inset}) =>
                      const SizedBox.shrink(),
              autocomplete: const SizedBox.shrink(),
              emoteMaxFraction: 0.6,
              composer: const SizedBox(height: 56),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> gesture(List<double> heights) async {
        for (final h in heights) {
          tester.view.viewInsets = FakeViewPadding(bottom: h * 3.0);
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pump(const Duration(milliseconds: 300));
      }

      // First open learns the 400dp keyboard, which leaves under 9 lines.
      await gesture([100, 250, 400]);
      await gesture([250, 100, 0]);
      expect(seen.last, isTrue);

      seen.clear();
      await gesture([100, 250, 400]);
      // At 100dp the live box still fits the video; the decision does not.
      expect(seen, isNotEmpty);
      expect(seen.every((show) => !show), isTrue);
    });
  });

  group('keyboard tick rebuild stability', () {
    late DateTime now;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      now = DateTime.now();
    });

    // Rapid inset ticks (a keyboard gesture) must keep showing cached rows,
    // and rows arriving mid-gesture must still appear despite the page, tab
    // and delegate caches. Guards the stable-identity rebuild skipping.
    testWidgets('ticks keep rows live and new rows arrive mid-gesture', (
      WidgetTester tester,
    ) async {
      const channel = 'testchannel';
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      tester.view.viewInsets = FakeViewPadding(bottom: 0);
      addTearDown(tester.view.reset);

      final ircRead = FakeIrcReadService();
      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: FakeEventSubService(),
          recentMessagesService: ConfigurableRecentMessagesService([
            TwitchMessage(
              login: 'alice',
              text: 'cached rows stay live',
              messageId: 'k1',
              timestamp: now.subtract(const Duration(minutes: 5)),
              isHistory: true,
              channel: channel,
            ),
          ]),
          ircService: FakeIrcService(),
          ircReadService: ircRead,
        ),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, channel);
      await tester.tap(find.text('Join', skipOffstage: false).last);
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('cached rows stay live', skipOffstage: false),
        findsWidgets,
      );

      // Keyboard opening ramp: one pump per tick, like the real gesture.
      for (final h in [100.0, 200.0, 300.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: h * 3.0);
        await tester.pump();
        expect(
          find.textContaining('cached rows stay live', skipOffstage: false),
          findsWidgets,
        );
      }

      // A live row landing mid-gesture still appears: the delegate recreates
      // on data change even with warm caches everywhere.
      ircRead.emitMessage(
        TwitchMessage(
          login: 'bob',
          text: 'live row arrives mid gesture',
          messageId: 'k2',
          channel: channel,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining(
          'live row arrives mid gesture',
          skipOffstage: false,
        ),
        findsWidgets,
      );
      expect(
        find.textContaining('cached rows stay live', skipOffstage: false),
        findsWidgets,
      );

      // And back down without errors, composer parked above the keyboard.
      for (final h in [200.0, 100.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: h * 3.0);
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('message_input')), findsOneWidget);
    });

    // Retracting the keyboard must settle the composer monotonically: once
    // the inset hits zero the input rests at the bottom with no up bounce.
    // Guards the governed close path (debounced zero) and the late unfocus.
    testWidgets('retract settles without an up bounce', (
      WidgetTester tester,
    ) async {
      const channel = 'testchannel';
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      tester.view.viewInsets = FakeViewPadding(bottom: 0);
      // Gesture bar like the device: present when the keyboard is closed,
      // covered while it is open.
      tester.view.viewPadding = const FakeViewPadding(bottom: 45.0);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: FakeEventSubService(),
          recentMessagesService: ConfigurableRecentMessagesService([
            TwitchMessage(
              login: 'alice',
              text: 'bounce probe row',
              messageId: 'b1',
              timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
              isHistory: true,
              channel: channel,
            ),
          ]),
          ircService: FakeIrcService(),
          ircReadService: FakeIrcReadService(),
        ),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, channel);
      await tester.tap(find.text('Join', skipOffstage: false).last);
      await tester.pump();
      await tester.pump();

      // Focus the input so the dismiss path runs its late unfocus, like the
      // device where the field keeps focus through the gesture. showKeyboard
      // guarantees focus instead of hoping the tap grants it.
      await tester.showKeyboard(find.byKey(const Key('message_input')));
      await tester.pump(const Duration(milliseconds: 16));

      // Open and settle so both inset learners know the height.
      for (final h in [100.0, 200.0, 300.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: h * 3.0);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 300));

      // Retract with a smooth tail, then watch the settle window frame by
      // frame with real clock advances so governor timers and label
      // animations run.
      for (final h in [200.0, 100.0, 40.0, 10.0, 2.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: h * 3.0);
        await tester.pump(const Duration(milliseconds: 16));
      }
      final tops = <double>[];
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        tops.add(tester.getRect(find.byKey(const Key('message_input'))).top);
      }
      for (var i = 1; i < tops.length; i++) {
        expect(
          tops[i],
          greaterThanOrEqualTo(tops[i - 1] - 1.0),
          reason: 'frame $i bounced up: $tops',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('a settled keyboard close drops focus once', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      tester.view.viewInsets = FakeViewPadding(bottom: 0);
      addTearDown(tester.view.reset);

      var dismissed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            resizeToAvoidBottomInset: true,
            body: ChatBody(
              emoteMaxFraction: 0.5,
              onKeyboardDismissed: () => dismissed++,
              composer: const SizedBox(height: 56),
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
              emotePickerBuilder:
                  (_, {required sheetBoxHeight, required inset}) =>
                      const SizedBox.shrink(),
              autocomplete: const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> ticks(List<double> heights) async {
        for (final h in heights) {
          tester.view.viewInsets = FakeViewPadding(bottom: h * 3.0);
          await tester.pump(const Duration(milliseconds: 16));
        }
      }

      await ticks([100, 250, 400]);
      await tester.pump(const Duration(milliseconds: 300));
      expect(dismissed, 0);

      // Reopening before the close settles cancels the unfocus.
      await ticks([250, 0]);
      await ticks([250, 400]);
      await tester.pump(const Duration(milliseconds: 300));
      expect(dismissed, 0);

      await ticks([250, 100, 0]);
      expect(dismissed, 0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(dismissed, 1);
    });

    testWidgets('glass freezes while the keyboard moves, then goes live', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      tester.view.viewInsets = FakeViewPadding(bottom: 0);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            resizeToAvoidBottomInset: true,
            body: ChatBody(
              liquidGlass: true,
              emoteMaxFraction: 0.5,
              composer: const SizedBox(height: 56),
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
              emotePickerBuilder:
                  (_, {required sheetBoxHeight, required inset}) =>
                      const SizedBox.shrink(),
              autocomplete: const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Offstage liveGlass() => tester.widget<Offstage>(
        find
            .descendant(
              of: find.byType(GlassSurface),
              matching: find.byType(Offstage),
            )
            .first,
      );
      bool snapshotShown() => tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: find.byType(GlassSurface),
              matching: find.byType(CustomPaint),
            ),
          )
          .any((p) => p.painter != null);

      expect(liveGlass().offstage, isFalse);
      expect(snapshotShown(), isFalse);

      for (final h in [100.0, 250.0, 400.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: h * 3.0);
        await tester.pump(const Duration(milliseconds: 16));
        expect(liveGlass().offstage, isTrue);
        expect(snapshotShown(), isTrue);
      }

      // Settled: live glass returns under the snapshot, which fades out.
      await tester.pump(const Duration(milliseconds: 150));
      expect(liveGlass().offstage, isFalse);
      expect(snapshotShown(), isTrue);
      await tester.pumpAndSettle();
      expect(snapshotShown(), isFalse);
    });

    // Glass mode pads the list by the measured pill footprint. That footprint
    // must be composed from live insets, not a cached measurement, or the
    // newest row dips under the pill for a frame as the keyboard retracts.
    testWidgets('glass clearance tracks the keyboard on retract', (
      WidgetTester tester,
    ) async {
      const dpr = 3.0;
      const navH = 45.0;
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = dpr;
      tester.view.viewInsets = FakeViewPadding(bottom: 0);
      tester.view.padding = FakeViewPadding(bottom: navH * dpr);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (_) {
              return Scaffold(
                resizeToAvoidBottomInset: true,
                body: ChatBody(
                  liquidGlass: true,
                  emoteMaxFraction: 0.5,
                  composer: const SizedBox(
                    key: Key('glass_composer'),
                    height: 56,
                  ),
                  bodyBuilder:
                      (
                        context, {
                        required hideChromeForKeyboard,
                        required maxWidth,
                        required maxHeight,
                        required keyboardH,
                        required composerH,
                      }) => Builder(
                        // bodyBuilder gets ChatBody's own context, above the
                        // scope, so read the clearance from a nested builder.
                        builder: (inner) => Stack(
                          fit: StackFit.expand,
                          children: [
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom:
                                  GlassChromeScope.maybeOf(
                                    inner,
                                  )?.bottomClearance ??
                                  0,
                              child: const SizedBox(
                                key: Key('glass_newest_row'),
                                height: 20,
                              ),
                            ),
                          ],
                        ),
                      ),
                  threadPanel: const SizedBox.shrink(),
                  mentionsPanel: const SizedBox.shrink(),
                  modViewPanel: const SizedBox.shrink(),
                  emotePickerBuilder:
                      (_, {required sheetBoxHeight, required inset}) =>
                          const SizedBox.shrink(),
                  autocomplete: const SizedBox.shrink(),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open and settle so the pill learns its height.
      for (final h in [100.0, 200.0, 300.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: h * dpr);
        tester.view.padding = FakeViewPadding(bottom: 0);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 300));

      // Retract with the gesture bar revealing as the inset clears it. The
      // newest row must stay clear of the pill on every frame.
      for (final h in [200.0, 100.0, 40.0, 10.0, 2.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: h * dpr);
        tester.view.padding = FakeViewPadding(
          bottom: (navH - h).clamp(0.0, navH) * dpr,
        );
        await tester.pump(const Duration(milliseconds: 16));
        final rowBottom = tester
            .getRect(find.byKey(const Key('glass_newest_row')))
            .bottom;
        final pillTop = tester
            .getRect(find.byKey(const Key('glass_composer')))
            .top;
        expect(
          rowBottom,
          lessThanOrEqualTo(pillTop + 0.5),
          reason: 'newest row rode over the pill at inset $h',
        );
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('search toggle page freshness', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    // Opening search filters rows and closing restores them, even though
    // pages are cached: search mode joins the cache validity check.
    testWidgets('open filters rows, close restores them', (
      WidgetTester tester,
    ) async {
      const channel = 'testchannel';
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      tester.view.viewInsets = FakeViewPadding(bottom: 0);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: FakeEventSubService(),
          recentMessagesService: ConfigurableRecentMessagesService([
            TwitchMessage(
              login: 'alice',
              text: 'visible apple',
              messageId: 's1',
              timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
              isHistory: true,
              channel: channel,
            ),
          ]),
          ircService: FakeIrcService(),
          ircReadService: FakeIrcReadService(),
        ),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, channel);
      await tester.tap(find.text('Join', skipOffstage: false).last);
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('visible apple', skipOffstage: false),
        findsWidgets,
      );

      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      expect(find.text('Search...'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('message_input')),
        'zzz-no-match',
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(
        find.textContaining('visible apple', skipOffstage: false),
        findsNothing,
      );
      expect(
        find.textContaining('No matches', skipOffstage: false),
        findsOneWidget,
      );

      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('visible apple', skipOffstage: false),
        findsWidgets,
      );
      expect(find.byKey(const Key('message_input')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Image embed viewer', () {
    testWidgets(
      'Image embed viewer opens over a scrim, closes via X or swipe',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => TextButton(
                  onPressed: () =>
                      showImageEmbedViewer(ctx, 'https://example.com/a.png'),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        // No pumpAndSettle: the loading spinner animates until the fetch fails.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(CachedNetworkImage), findsOneWidget);
        expect(find.byIcon(Icons.close), findsOneWidget);

        await tester.tap(find.byIcon(Icons.close));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byIcon(Icons.close), findsNothing);

        // Swipe down pops at once, same speed as the X button.
        await tester.tap(find.text('open'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byIcon(Icons.close), findsOneWidget);
        await tester.fling(
          find.byIcon(Icons.close),
          const Offset(0, 400),
          1000,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byIcon(Icons.close), findsNothing);
      },
    );
  });

  group('ChatMessageTile channel prefix', () {
    Widget buildTile({required bool showChannel}) => MaterialApp(
      key: UniqueKey(),
      home: Scaffold(
        body: ChatMessageTile(
          message: TwitchMessage(
            login: 'alice',
            text: 'hi there',
            channel: 'somechannel',
            messageId: 'c1',
          ),
          channel: 'somechannel',
          surface: Colors.white,
          textScale: 1.0,
          showChannel: showChannel,
          buildBadgeSpans: (_, _, {double badgeScale = 1.0}) => const [],
          buildMessageSpans:
              (_, _, _, {colored = false, textScale = 1.0, onImageTap}) =>
                  <InlineSpan>[const TextSpan(text: 'hi there')],
          bodyIsCached: (_, _) => false,
        ),
      ),
    );

    testWidgets('channel prefix renders before the username when enabled', (
      tester,
    ) async {
      await tester.pumpWidget(buildTile(showChannel: true));
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is RichText &&
              w.text.toPlainText().contains('#somechannel alice: hi there'),
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(buildTile(showChannel: false));
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().contains('#somechannel'),
        ),
        findsNothing,
      );
    });
  });

  testWidgets('Notification bell gates only on unfocused mentions', (
    WidgetTester tester,
  ) async {
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

    // Join 'b' first, then 'a' so 'a' is selected and 'b' is unfocused.
    for (final name in ['b', 'a']) {
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, name);
      await tester.tap(find.text('Join', skipOffstage: false));
      await tester.pump();
    }

    // System notices on unfocused channels never raise the unread dot.
    ircRead.emitNotice('b', 'This room requires a verified email.');
    await tester.pump();
    expect(find.byKey(const Key('unread_mention_dot')), findsNothing);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
      isNull,
    );

    // Mention in the focused channel keeps the bell calm.
    ircRead.emitMessage(
      TwitchMessage(
        login: 'bob',
        text: 'hey @me how are you',
        channel: 'a',
        messageId: 'm1',
      ),
    );
    await tester.pump();
    expect(
      tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
      isNull,
    );
    expect(find.byKey(const Key('unread_mention_dot')), findsNothing);

    // Mention in the unfocused channel turns the bell red with a tab dot.
    ircRead.emitMessage(
      TwitchMessage(
        login: 'carol',
        text: 'hello @me',
        channel: 'b',
        messageId: 'm2',
      ),
    );
    await tester.pump();
    expect(
      tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
      isNotNull,
    );
    expect(find.byKey(const Key('unread_mention_dot')), findsOneWidget);
  });

  testWidgets(
    'Clearing unread mentions works from taps and panel opens and swipes',
    (WidgetTester tester) async {
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

      for (final name in ['b', 'a']) {
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, name);
        await tester.tap(find.text('Join', skipOffstage: false));
        await tester.pump();
      }

      Future<void> tapNamed(String name) async {
        final barText = find.text(name, skipOffstage: false).first;
        await tester.ensureVisible(barText);
        await tester.pump();
        await tester.tap(barText);
        await tester.pumpAndSettle();
        await tester.pump();
      }

      void emitMention(String id) {
        ircRead.emitMessage(
          TwitchMessage(
            login: 'carol',
            text: 'hello @me',
            channel: 'b',
            messageId: id,
          ),
        );
      }

      // Tab tap path: select 'b' to clear, then back to 'a' so 'b' reverts grey.
      emitMention('m3');
      await tester.pump();
      expect(find.byKey(const Key('unread_mention_dot')), findsOneWidget);
      await tapNamed('b');
      expect(find.byKey(const Key('unread_mention_dot')), findsNothing);
      await tapNamed('a');
      final text = tester.widget<Text>(find.text('b', skipOffstage: false));
      expect(text.style?.color, isNull);
      expect(find.byKey(const Key('unread_mention_dot')), findsNothing);

      // Swipe path: switch via a TabBarView drag (not a tab tap). 'b' is at
      // page 0 and 'a' at page 1, so drag right (positive dx). The focus-change
      // handler clears the unread state mid-drag; on settle the index already
      // equals the selection so onSelectedIndexChanged is skipped, which is
      // exactly the path that used to leave the bell stale.
      emitMention('m6');
      await tester.pump();
      expect(
        tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
        isNotNull,
      );
      final barSize = tester.getSize(find.byType(PageView));
      final barCenter = tester.getCenter(find.byType(PageView));
      final gesture = await tester.startGesture(barCenter);
      await gesture.moveBy(const Offset(kTouchSlop + 1, 0));
      await tester.pump();
      await gesture.moveBy(Offset(barSize.width * 0.55, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pump();

      expect(
        tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
        isNull,
      );
      expect(find.byKey(const Key('unread_mention_dot')), findsNothing);

      // Panel open path: a new mention clears when the bell panel opens.
      await tapNamed('a');
      emitMention('m4');
      await tester.pump();
      expect(find.byKey(const Key('unread_mention_dot')), findsOneWidget);
      await tester.tap(find.byIcon(Icons.notifications_active));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
        isNull,
      );
      expect(find.byKey(const Key('unread_mention_dot')), findsNothing);
    },
  );

  testWidgets('Long pressed mention and whisper rows open the copy menu', (
    WidgetTester tester,
  ) async {
    final ircRead = FakeIrcReadService();
    await tester.pumpWidget(
      TwitchChatApp(
        key: UniqueKey(),
        eventSubService: FakeEventSubService(),
        ircService: FakeIrcService(),
        ircReadService: ircRead,
        recentMessagesService: ConfigurableRecentMessagesService(const []),
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
    ircRead.emitWhisper(
      TwitchMessage(
        login: 'carol',
        text: 'psst',
        channel: null,
        messageId: 'w-panel-1',
      ),
    );
    await tester.pump();

    Future<void> expectCopyMenu(String text) async {
      final row = find.textContaining(text, skipOffstage: false);
      expect(row, findsAtLeast(1));
      await tester.longPress(row.last);
      await tester.pumpAndSettle();
      expect(find.text('Copy message', skipOffstage: false), findsOneWidget);
      expect(find.text('Reply to message', skipOffstage: false), findsNothing);
    }

    await tester.tap(find.byIcon(Icons.notifications_active));
    await tester.pumpAndSettle();
    await expectCopyMenu('hello @me');
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Whispers', skipOffstage: false));
    await tester.pumpAndSettle();
    await expectCopyMenu('psst');
  });

  testWidgets(
    'Whispers tab unlocks the composer and routes replies to the partner',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({
        'access_token': 'test_token',
        'user_login': 'me',
        'user_id': '42',
      });
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
        ),
      );
      await tester.pump();

      for (final name in ['b', 'a']) {
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, name);
        await tester.tap(find.text('Join', skipOffstage: false));
        await tester.pump();
      }
      irc.triggerConnect();
      ircRead.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      ircRead.emitWhisper(
        TwitchMessage(
          login: 'carol',
          text: 'hi',
          channel: null,
          messageId: 'w2',
        ),
      );
      await tester.pump();
      expect(
        tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
        isNotNull,
      );

      await tester.tap(find.byIcon(Icons.notifications_active));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
        isNull,
      );

      // Mentions tab keeps the box locked.
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('message_input')))
            .enabled,
        isFalse,
      );

      await tester.tap(find.text('Whispers', skipOffstage: false));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(find.byKey(const Key('message_input')))
            .enabled,
        isTrue,
      );
      expect(
        find.text('Whisper to carol...', skipOffstage: false),
        findsOneWidget,
      );

      // Plain text routes as a whisper to the latest partner and clears.
      await tester.enterText(
        find.byKey(const Key('message_input')),
        'back at you',
      );
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('message_input')))
            .controller!
            .text,
        isEmpty,
      );
    },
  );

  testWidgets('Sending a reply dismisses the reply header', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
    FlutterSecureStorage.setMockInitialValues({
      'access_token': 'test_token',
      'user_login': 'me',
      'user_id': '42',
    });
    final irc = FakeIrcService();
    final ircRead = FakeIrcReadService();
    await tester.pumpWidget(
      TwitchChatApp(
        key: UniqueKey(),
        eventSubService: FakeEventSubService(),
        ircService: irc,
        ircReadService: ircRead,
        recentMessagesService: ConfigurableRecentMessagesService(const []),
      ),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'a');
    await tester.tap(find.text('Join', skipOffstage: false));
    await tester.pump();
    irc.triggerConnect();
    ircRead.triggerConnect();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // The reply header only shows while the composer is enabled, which
    // needs the channel join confirmed.
    irc.triggerJoin('a');
    ircRead.triggerJoin('a');
    await tester.pump();

    ircRead.emitMessage(
      TwitchMessage(
        login: 'alice',
        text: 'parent msg',
        messageId: 'p1',
        channel: 'a',
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(
      find.textContaining('alice: parent msg', skipOffstage: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reply to message', skipOffstage: false));
    await tester.pumpAndSettle();
    expect(find.textContaining('Replying to @alice'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('message_input')), 'hi');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(find.textContaining('Replying to @alice'), findsNothing);
  });

  testWidgets('Thread tab reopened from the dashboard replies to its thread', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
    FlutterSecureStorage.setMockInitialValues({
      'access_token': 'test_token',
      'user_login': 'me',
      'user_id': '42',
    });
    final irc = _RecordingIrcService();
    final ircRead = FakeIrcReadService();
    await tester.pumpWidget(
      TwitchChatApp(
        key: UniqueKey(),
        eventSubService: FakeEventSubService(),
        ircService: irc,
        ircReadService: ircRead,
        recentMessagesService: ConfigurableRecentMessagesService(const []),
      ),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'a');
    await tester.tap(find.text('Join', skipOffstage: false));
    await tester.pump();
    irc.triggerConnect();
    ircRead.triggerConnect();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    irc.triggerJoin('a');
    ircRead.triggerJoin('a');
    await tester.pump();

    ircRead.emitMessage(
      TwitchMessage(
        login: 'alice',
        text: 'parent msg',
        messageId: 'p1',
        channel: 'a',
      ),
    );
    ircRead.emitMessage(
      TwitchMessage(
        login: 'bob',
        text: 'child msg',
        messageId: 'c1',
        replyToParentId: 'p1',
        replyToUser: 'alice',
        replyToText: 'parent msg',
        channel: 'a',
      ),
    );
    await tester.pumpAndSettle();

    // Open the thread, then close the panel: the close drops the open root.
    await tester.tap(
      find.textContaining(
        'Replying to @alice: parent msg',
        skipOffstage: false,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    // Reopen through the dashboard and go straight to the Thread tab.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Threads').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Thread', skipOffstage: false).first);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('message_input')), 'hi');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(irc.sent, isNotEmpty);
    expect(irc.sent.last.text, 'hi');
    expect(irc.sent.last.replyParent, isNotNull);
  });

  // The open thread refreshes on its index, not on every channel arrival.
  testWidgets('An open thread picks up a live reply', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final ircRead = FakeIrcReadService();
    final irc = FakeIrcService();
    await tester.pumpWidget(
      TwitchChatApp(
        key: UniqueKey(),
        eventSubService: FakeEventSubService(),
        ircService: irc,
        ircReadService: ircRead,
        recentMessagesService: ConfigurableRecentMessagesService(const []),
      ),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'a');
    await tester.tap(find.text('Join', skipOffstage: false));
    await tester.pump();
    irc.triggerConnect();
    ircRead.triggerConnect();
    await tester.pump(const Duration(milliseconds: 600));
    irc.triggerJoin('a');
    ircRead.triggerJoin('a');
    await tester.pump();

    TwitchMessage reply(String id, String text) => TwitchMessage(
      login: 'bob',
      text: text,
      messageId: id,
      replyToParentId: 'p1',
      replyToUser: 'alice',
      replyToText: 'parent msg',
      channel: 'a',
    );
    ircRead.emitMessage(
      TwitchMessage(
        login: 'alice',
        text: 'parent msg',
        messageId: 'p1',
        channel: 'a',
      ),
    );
    ircRead.emitMessage(reply('c1', 'first reply'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.textContaining('Replying to @alice: parent msg').first,
    );
    await tester.pumpAndSettle();

    ircRead.emitMessage(
      TwitchMessage(
        login: 'carol',
        text: 'noise',
        messageId: 'n1',
        channel: 'a',
      ),
    );
    ircRead.emitMessage(reply('c2', 'second reply'));
    await tester.pumpAndSettle();

    // Main chat plus the thread panel.
    expect(
      find.textContaining('second reply', skipOffstage: false),
      findsNWidgets(2),
      reason: 'the open thread must show a reply that lands while open',
    );
    expect(find.textContaining('noise', skipOffstage: false), findsOneWidget);
  });

  testWidgets('Message timestamps render by default and hide when disabled', (
    WidgetTester tester,
  ) async {
    {
      final fakeEventSub = FakeEventSubService();
      final fakeIrc = FakeIrcService();
      final fakeIrcRead = FakeIrcReadService();
      final fakeRecent = FakeRecentMessagesService();

      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: fakeEventSub,
          ircService: fakeIrc,
          ircReadService: fakeIrcRead,
          recentMessagesService: fakeRecent,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'xqc');
      await tester.tap(find.text('Join', skipOffstage: false));
      await tester.pump();

      fakeIrcRead.emitMessage(
        TwitchMessage(
          login: 'xqc',
          text: 'hello',
          channel: 'xqc',
          messageId: 'm1',
        ),
      );
      await tester.pump();

      // The timestamp is the first span of the row's rich text now, so match
      // it inside that plain text rather than as a standalone widget.
      final timeText = find.textContaining(
        RegExp(r'\d{2}:\d{2} '),
        skipOffstage: false,
      );
      expect(timeText, findsAtLeast(1));
    }
    await tester.pumpAndSettle();
    {
      SharedPreferences.setMockInitialValues({
        'timestamp_format': 'HH:mm',
        'show_timestamps': false,
      });
      final fakeEventSub = FakeEventSubService();
      final fakeIrc = FakeIrcService();
      final fakeIrcRead = FakeIrcReadService();
      final fakeRecent = FakeRecentMessagesService();

      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: fakeEventSub,
          ircService: fakeIrc,
          ircReadService: fakeIrcRead,
          recentMessagesService: fakeRecent,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'xqc');
      await tester.tap(find.text('Join', skipOffstage: false));
      await tester.pump();

      fakeIrcRead.emitMessage(
        TwitchMessage(
          login: 'xqc',
          text: 'hello',
          channel: 'xqc',
          messageId: 'm1',
        ),
      );
      await tester.pump();

      expect(
        find.textContaining(RegExp(r'\d{2}:\d{2} '), skipOffstage: false),
        findsNothing,
      );
      expect(find.textContaining('hello', skipOffstage: false), findsWidgets);
    }
  });

  testWidgets('Connected notice inserts once and survives history load', (
    WidgetTester tester,
  ) async {
    {
      final fakeEventSub = FakeEventSubService();
      final fakeIrc = FakeIrcService();
      final historyCompleter = Completer<List<TwitchMessage>>();
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: fakeEventSub,
          recentMessagesService: CompleterRecentMessagesService(
            historyCompleter,
          ),
          ircService: fakeIrc,
        ),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'testchannel');
      await tester.tap(find.text('Join', skipOffstage: false));
      await tester.pumpAndSettle();
      fakeIrc.triggerConnect(joinChannel: 'testchannel');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(
        find.textContaining('Connected', skipOffstage: false),
        findsOneWidget,
      );
      historyCompleter.complete([
        TwitchMessage(
          login: 'alice',
          text: 'hello world',
          channel: 'testchannel',
          messageId: 'hist-1',
          timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
          isHistory: true,
        ),
      ]);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Connected', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('hello world', skipOffstage: false),
        findsOneWidget,
      );
    }
  });

  testWidgets('editing a channel swaps it in place', (tester) async {
    SharedPreferences.setMockInitialValues({
      'access_token': 'test_token',
      'channels': ['a', 'b', 'c'],
    });
    FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});

    await tester.pumpWidget(
      TwitchChatApp(
        key: UniqueKey(),
        eventSubService: FakeEventSubService(),
        ircService: FakeIrcService(),
        recentMessagesService: ScriptedRecentMessagesService([]),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Channels'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, 'b'),
        matching: find.byIcon(Icons.edit_outlined),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Edit channel'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Z ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListTile, 'b'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('channels'), ['a', 'z', 'c']);
  });

  testWidgets('Reconnect refetch shows gaps and merges in order', (
    WidgetTester tester,
  ) async {
    {
      SharedPreferences.setMockInitialValues({
        'access_token': 'test_token',
        'channels': ['xqc'],
      });
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});

      final now = DateTime.now();
      final recent = ScriptedRecentMessagesService([
        [
          TwitchMessage(
            login: 'alice',
            text: 'old message',
            channel: 'xqc',
            messageId: 'a1',
            timestamp: now.subtract(const Duration(minutes: 30)),
          ),
        ],
        [
          TwitchMessage(
            login: 'dave',
            text: 'fresh message',
            channel: 'xqc',
            messageId: 'd1',
            timestamp: now.subtract(const Duration(minutes: 1)),
          ),
        ],
      ]);
      final fakeEventSub = FakeEventSubService();
      final fakeIrc = FakeIrcService();

      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: fakeEventSub,
          ircService: fakeIrc,
          recentMessagesService: recent,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('old message', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'History: Not all messages retrieved',
          skipOffstage: false,
        ),
        findsNothing,
      );

      fakeIrc.triggerDisconnect();
      await tester.pump();
      fakeIrc.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(
        find.textContaining('fresh message', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('old message', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'History: Not all messages retrieved',
          skipOffstage: false,
        ),
        findsOneWidget,
      );
    }
    {
      SharedPreferences.setMockInitialValues({
        'access_token': 'test_token',
        'channels': ['xqc'],
      });
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});

      final now = DateTime.now();
      final refetchGate = Completer<void>();
      final recent = GatedRecentMessagesService(
        [
          [
            TwitchMessage(
              login: 'alice',
              text: 'old history',
              channel: 'xqc',
              messageId: 'a1',
              timestamp: now.subtract(const Duration(minutes: 5)),
            ),
          ],
          [
            TwitchMessage(
              login: 'bob',
              text: 'missed message',
              channel: 'xqc',
              messageId: 'b1',
              timestamp: now.subtract(const Duration(minutes: 1)),
            ),
          ],
        ],
        gateOnCall: 2,
        gate: refetchGate,
      );
      final fakeEventSub = FakeEventSubService();
      final fakeIrc = FakeIrcService();
      final fakeIrcRead = FakeIrcReadService();

      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: fakeEventSub,
          ircService: fakeIrc,
          ircReadService: fakeIrcRead,
          recentMessagesService: recent,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('old history', skipOffstage: false),
        findsOneWidget,
      );

      fakeIrc.triggerConnect();
      fakeIrcRead.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(recent.callCount, 1);

      fakeIrc.triggerDisconnect();
      fakeIrcRead.triggerDisconnect();
      await tester.pump();
      fakeIrc.triggerConnect();
      fakeIrcRead.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(recent.callCount, 2, reason: 'reconnect must trigger a re-fetch');

      // Live messages arrive while the re-fetch is still in flight.
      fakeIrcRead.emitMessage(
        TwitchMessage(
          login: 'carol',
          text: 'live after reconnect',
          channel: 'xqc',
          messageId: 'c1',
          timestamp: now,
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('live after reconnect', skipOffstage: false),
        findsOneWidget,
      );

      refetchGate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(
        find.textContaining('missed message', skipOffstage: false),
        findsOneWidget,
      );
      final liveY = tester
          .getTopLeft(
            find.textContaining('live after reconnect', skipOffstage: false),
          )
          .dy;
      final missedY = tester
          .getTopLeft(
            find.textContaining('missed message', skipOffstage: false),
          )
          .dy;
      expect(
        liveY,
        greaterThan(missedY),
        reason: 'newer live messages must stay above re-fetched history',
      );
      final oldY = tester
          .getTopLeft(find.textContaining('old history', skipOffstage: false))
          .dy;
      expect(
        missedY,
        greaterThan(oldY),
        reason: 'missed history is newer than pre-disconnect messages',
      );
    }
  });

  testWidgets('chat input is disabled until the channel join confirms', (
    WidgetTester tester,
  ) async {
    final fakeEventSub = FakeEventSubService();
    final fakeIrc = FakeIrcService();
    final fakeIrcRead = FakeIrcReadService();

    SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
    // Resolved identity so the session fast path applies. The test is about
    // JOIN gating; identity resolution now locks the input on its own.
    FlutterSecureStorage.setMockInitialValues({
      'accounts': '[{"login":"me","user_id":"42","access_token":"test_token"}]',
      'active_login': 'me',
    });

    await tester.pumpWidget(
      TwitchChatApp(
        key: UniqueKey(),
        eventSubService: fakeEventSub,
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

    // Sockets up but JOIN not confirmed yet: input locked with a hint.
    fakeIrc.triggerConnect();
    fakeIrcRead.triggerConnect();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    bool inputEnabled() =>
        tester
            .widget<TextField>(find.byKey(const Key('message_input')))
            .enabled ??
        false;
    expect(inputEnabled(), isFalse);
    expect(find.text('Disconnected'), findsOneWidget);

    // JOIN confirms on both sockets: input unlocks and the hint goes away.
    fakeIrc.triggerJoin('testchannel');
    fakeIrcRead.triggerJoin('testchannel');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(inputEnabled(), isTrue);
    expect(find.text('Disconnected'), findsNothing);
  });

  group('Thread', () {
    late DateTime now;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      now = DateTime.now();
    });

    Future<void> joinChannel(
      WidgetTester tester, {
      required String channelName,
      required List<TwitchMessage> history,
      FakeIrcService? irc,
      IrcReadService? ircReadService,
    }) async {
      final fakeIrc = irc ?? FakeIrcService();
      final fakeRecent = ConfigurableRecentMessagesService(history);
      final es = FakeEventSubService();

      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: es,
          recentMessagesService: fakeRecent,
          ircService: fakeIrc,
          ircReadService: ircReadService,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, channelName);
      await tester.tap(find.text('Join', skipOffstage: false).last);
      await tester.pump();
      await tester.pump();
    }

    testWidgets(
      'Thread replies open from indicators and menus with full chains',
      (WidgetTester tester) async {
        {
          const channel = 'testchannel';
          final parent = TwitchMessage(
            login: 'alice',
            text: 'parent msg',
            messageId: 'p1',
            timestamp: now.subtract(const Duration(minutes: 5)),
            channel: channel,
          );
          final child1 = TwitchMessage(
            login: 'bob',
            text: 'child one',
            messageId: 'c1',
            replyToParentId: 'p1',
            replyToUser: 'alice',
            replyToText: 'parent preview',
            timestamp: now.subtract(const Duration(minutes: 4)),
            isHistory: true,
            channel: channel,
          );
          final child2 = TwitchMessage(
            login: 'charlie',
            text: 'child two',
            messageId: 'c2',
            replyToParentId: 'p1',
            replyToUser: 'alice',
            replyToText: 'parent preview',
            timestamp: now.subtract(const Duration(minutes: 3)),
            isHistory: true,
            channel: channel,
          );
          await joinChannel(
            tester,
            channelName: channel,
            history: [parent, child1, child2],
          );

          await tester.longPress(
            find.textContaining('alice: parent msg', skipOffstage: false),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.text('View thread', skipOffstage: false));
          await tester.pumpAndSettle();

          expect(find.text('Threads', skipOffstage: false), findsOneWidget);
          expect(
            find.textContaining('parent msg', skipOffstage: false),
            findsAtLeast(1),
          );
          expect(
            find.textContaining('child one', skipOffstage: false),
            findsAtLeast(1),
          );
          expect(
            find.textContaining('child two', skipOffstage: false),
            findsAtLeast(1),
          );
        }
        {
          const channel = 'testchannel';
          final root = TwitchMessage(
            login: 'alice',
            text: 'root level',
            messageId: 'd1',
            timestamp: now.subtract(const Duration(minutes: 7)),
            channel: channel,
          );
          final mid = TwitchMessage(
            login: 'bob',
            text: 'mid level',
            messageId: 'd2',
            replyToParentId: 'd1',
            replyToUser: 'alice',
            replyToText: 'root level',
            timestamp: now.subtract(const Duration(minutes: 5)),
            isHistory: true,
            channel: channel,
          );
          final leaf = TwitchMessage(
            login: 'charlie',
            text: 'leaf level',
            messageId: 'd3',
            replyToParentId: 'd2',
            replyToUser: 'bob',
            replyToText: 'mid level',
            timestamp: now.subtract(const Duration(minutes: 3)),
            isHistory: true,
            channel: channel,
          );
          await joinChannel(
            tester,
            channelName: channel,
            history: [root, mid, leaf],
          );

          await tester.tap(
            find.textContaining(
              'Replying to @bob: mid level',
              skipOffstage: false,
            ),
          );
          await tester.pumpAndSettle();

          expect(find.text('Threads', skipOffstage: false), findsOneWidget);
          expect(
            find.textContaining('root level', skipOffstage: false),
            findsAtLeast(1),
          );
          expect(
            find.textContaining('mid level', skipOffstage: false),
            findsAtLeast(1),
          );
          expect(
            find.textContaining('leaf level', skipOffstage: false),
            findsAtLeast(1),
          );
        }
      },
    );

    testWidgets(
      'open thread panel survives scrollback trimming without going empty',
      (WidgetTester tester) async {
        const channel = 'testchannel';
        // Small window so flooding live chat pushes the thread out quickly.
        SharedPreferences.setMockInitialValues({'max_messages_per_channel': 5});
        final parent = TwitchMessage(
          login: 'alice',
          text: 'thread root',
          messageId: 'p1',
          timestamp: now.subtract(const Duration(minutes: 5)),
          channel: channel,
        );
        final child = TwitchMessage(
          login: 'bob',
          text: 'child msg',
          messageId: 'c1',
          replyToParentId: 'p1',
          replyThreadRootId: 'p1',
          replyToUser: 'alice',
          replyToText: 'parent msg',
          timestamp: now.subtract(const Duration(minutes: 4)),
          channel: channel,
        );
        final irc = FakeIrcService();
        final ircRead = FakeIrcReadService();
        await joinChannel(
          tester,
          channelName: channel,
          history: [parent, child],
          irc: irc,
          ircReadService: ircRead,
        );

        await tester.pump();
        await tester.pump();

        await tester.tap(
          find.textContaining('Replying to @alice', skipOffstage: false),
        );
        await tester.pumpAndSettle();
        expect(find.text('Threads', skipOffstage: false), findsOneWidget);
        expect(
          find.textContaining('thread root', skipOffstage: false),
          findsAtLeast(1),
        );

        // Flood the channel so truncation evicts every thread member from
        // the main chat buffer while the panel is open.
        for (var i = 0; i < 12; i++) {
          ircRead.emitMessage(
            TwitchMessage(
              login: 'user$i',
              text: 'flood $i',
              messageId: 'fl$i',
              timestamp: now.add(Duration(seconds: i)),
              channel: channel,
            ),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();

        // The panel must not collapse to an empty state: the pinned root
        // keeps the thread viewable even though the buffer forgot it.
        expect(find.text('No messages found'), findsNothing);
        expect(
          find.textContaining('thread root', skipOffstage: false),
          findsAtLeast(1),
        );
      },
    );

    testWidgets(
      'Thread menu hides for standalone messages and shows orphans alone',
      (WidgetTester tester) async {
        {
          const channel = 'testchannel';
          final standalone = TwitchMessage(
            login: 'charlie',
            text: 'standalone msg',
            messageId: 's1',
            timestamp: now.subtract(const Duration(minutes: 3)),
            channel: channel,
          );
          await joinChannel(
            tester,
            channelName: channel,
            history: [standalone],
          );

          await tester.longPress(
            find.textContaining('charlie: standalone msg', skipOffstage: false),
          );
          await tester.pumpAndSettle();

          expect(find.text('View thread'), findsNothing);
          expect(
            find.text('Reply to message', skipOffstage: false),
            findsOneWidget,
          );
        }
        {
          const channel = 'testchannel';
          final orphan = TwitchMessage(
            login: 'bob',
            text: 'orphan msg',
            messageId: 'o1',
            replyToParentId: 'nonexistent',
            replyToUser: 'unknown_user',
            replyToText: 'missing text',
            timestamp: now.subtract(const Duration(minutes: 4)),
            isHistory: true,
            channel: channel,
          );
          await joinChannel(tester, channelName: channel, history: [orphan]);

          await tester.tap(
            find.textContaining(
              'Replying to @unknown_user: missing text',
              skipOffstage: false,
            ),
          );
          await tester.pumpAndSettle();

          expect(find.text('Threads', skipOffstage: false), findsOneWidget);
          expect(
            find.textContaining('orphan msg', skipOffstage: false),
            findsAtLeast(1),
          );
        }
      },
    );

    testWidgets('Panels close on downward drags on thread and emote headers', (
      WidgetTester tester,
    ) async {
      {
        const channel = 'testchannel';
        final threadNow = DateTime.now();
        final parent = TwitchMessage(
          login: 'alice',
          text: 'parent msg',
          messageId: 'p1',
          timestamp: threadNow.subtract(const Duration(minutes: 5)),
          channel: channel,
        );
        final child = TwitchMessage(
          login: 'bob',
          text: 'child msg',
          messageId: 'c1',
          replyToParentId: 'p1',
          replyToUser: 'alice',
          replyToText: 'parent msg',
          timestamp: threadNow.subtract(const Duration(minutes: 4)),
          isHistory: true,
          channel: channel,
        );
        final fakeRecent = ConfigurableRecentMessagesService([parent, child]);
        await tester.pumpWidget(
          TwitchChatApp(
            key: UniqueKey(),
            eventSubService: FakeEventSubService(),
            recentMessagesService: fakeRecent,
            ircService: FakeIrcService(),
          ),
        );
        await tester.pump();
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, channel);
        await tester.tap(find.text('Join', skipOffstage: false).last);
        await tester.pump();
        await tester.pump();
        await tester.tap(
          find.textContaining(
            'Replying to @alice: parent msg',
            skipOffstage: false,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Threads', skipOffstage: false), findsOneWidget);
        final headerSize = tester.getSize(
          find.text('Threads', skipOffstage: false),
        );
        await tester.fling(
          find.text('Threads', skipOffstage: false),
          Offset(0, headerSize.height * 3),
          1000,
        );
        await tester.pumpAndSettle();
        expect(find.text('Threads'), findsNothing);
      }
      {
        SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
        // Resolved identity: the emote sheet toggle needs an enabled
        // composer, which now requires the session user (not just a token).
        FlutterSecureStorage.setMockInitialValues({
          'accounts':
              '[{"login":"me","user_id":"42","access_token":"test_token"}]',
          'active_login': 'me',
        });
        final irc = FakeIrcService();
        final ircRead = FakeIrcReadService();
        await tester.pumpWidget(
          TwitchChatApp(
            key: UniqueKey(),
            eventSubService: FakeEventSubService(),
            recentMessagesService: ConfigurableRecentMessagesService(const []),
            ircService: irc,
            ircReadService: ircRead,
          ),
        );
        await tester.pump();
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'testchannel');
        await tester.tap(find.text('Join', skipOffstage: false).last);
        await tester.pump();
        await tester.pump();
        irc.triggerConnect(joinChannel: 'testchannel');
        ircRead.triggerConnect(joinChannel: 'testchannel');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
        await tester.pumpAndSettle();
        final tabSize = tester.getSize(
          find.text('Recent', skipOffstage: false),
        );
        await tester.fling(
          find.text('Recent', skipOffstage: false),
          Offset(0, tabSize.height * 5),
          1000,
        );
        await tester.pumpAndSettle();
        expect(find.text('Recent'), findsNothing);
      }
    });
  });

  group('System messages', () {
    Future<void> setupChannel(
      WidgetTester tester, {
      required FakeEventSubService eventSub,
      required FakeIrcService irc,
      IrcReadService? ircReadService,
      RecentMessagesService? recent,
    }) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
      final fakeRecent = recent ?? FakeRecentMessagesService();

      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: eventSub,
          recentMessagesService: fakeRecent,
          ircService: irc,
          ircReadService: ircReadService,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'testchannel');
      await tester.tap(find.text('Join', skipOffstage: false).last);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('Ban, timeout and deletion notices render as system rows', (
      WidgetTester tester,
    ) async {
      final ircRead = FakeIrcReadService();
      await setupChannel(
        tester,
        eventSub: FakeEventSubService(),
        irc: FakeIrcService(),
        ircReadService: ircRead,
      );

      ircRead.emitBan('baduser', isTimeout: false, channel: 'testchannel');
      ircRead.emitBan(
        'spammer',
        isTimeout: true,
        durationSeconds: 300,
        channel: 'testchannel',
      );
      ircRead.emitBan('quiet', isTimeout: true, channel: 'testchannel');
      await tester.pump();
      Finder row(String t) => find.textContaining(t, skipOffstage: false);
      expect(row('baduser was banned'), findsOneWidget);
      expect(row('spammer was timed out for 5m.'), findsOneWidget);
      expect(row('quiet was timed out'), findsOneWidget);
      expect(find.textContaining('quiet was timed out for'), findsNothing);

      // A tombstone for a message never seen, then a live row that is
      // deleted after a second row shifts it: the text stays, greyed out.
      ircRead.emitDeleted(
        'root-1',
        'testchannel',
        user: 'alice',
        deletedMessageText: 'hello world',
      );
      ircRead.emitMessage(
        TwitchMessage(
          login: 'bob',
          text: 'will be deleted',
          channel: 'testchannel',
          messageId: 'live-1',
        ),
      );
      await tester.pump();
      ircRead.emitMessage(
        TwitchMessage(
          login: 'carol',
          text: 'shift me',
          channel: 'testchannel',
          messageId: 'live-2',
        ),
      );
      await tester.pump();
      ircRead.emitDeleted(
        'live-1',
        'testchannel',
        user: 'mod',
        deletedMessageText: 'will be deleted',
      );
      await tester.pump();
      expect(row('A message from alice was deleted'), findsOneWidget);
      expect(row('hello world'), findsAtLeast(1));
      expect(row('will be deleted'), findsAtLeast(1));
    });
  });

  group('Message cutoff', () {
    Future<void> joinChannel(
      WidgetTester tester, {
      required String channelName,
      required List<TwitchMessage> history,
      FakeIrcService? irc,
      IrcReadService? ircReadService,
      int maxMessages = 500,
    }) async {
      SharedPreferences.setMockInitialValues({
        'max_messages_per_channel': maxMessages,
      });
      final fakeIrc = irc ?? FakeIrcService();
      final fakeRecent = ConfigurableRecentMessagesService(history);
      final es = FakeEventSubService();

      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: es,
          recentMessagesService: fakeRecent,
          ircService: fakeIrc,
          ircReadService: ircReadService,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, channelName);
      await tester.tap(find.text('Join', skipOffstage: false).last);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('Truncation keeps a thread until it is pushed past the limit', (
      WidgetTester tester,
    ) async {
      {
        const channel = 'testchannel';
        final parent = TwitchMessage(
          login: 'alice',
          text: 'thread root',
          messageId: 'p3',
          timestamp: DateTime.now().subtract(const Duration(minutes: 12)),
          channel: channel,
        );
        final child = TwitchMessage(
          login: 'bob',
          text: 'thread reply',
          messageId: 'c3',
          replyToParentId: 'p3',
          replyToUser: 'alice',
          replyToText: 'thread root',
          timestamp: DateTime.now().subtract(const Duration(minutes: 11)),
          isHistory: true,
          channel: channel,
        );
        final filler = List.generate(
          9,
          (i) => TwitchMessage(
            login: 'user$i',
            text: 'filler $i',
            messageId: 'h$i',
            timestamp: DateTime.now().subtract(Duration(minutes: 10 - i)),
            channel: channel,
          ),
        );
        final irc = FakeIrcService();
        final ircRead = FakeIrcReadService();
        await joinChannel(
          tester,
          channelName: channel,
          history: [parent, child, ...filler],
          irc: irc,
          ircReadService: ircRead,
          maxMessages: 10,
        );

        await tester.pump();
        await tester.pump();

        // Expand viewport so lazy ListView builds all items without scrolling
        // (avoids triggering the frozen-snapshot behavior in scroll notifications).
        await tester.binding.setSurfaceSize(const Size(2000, 2000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpAndSettle();

        // Thread is initially preserved - child is within the limit.
        expect(
          find.textContaining('thread root', skipOffstage: false),
          findsWidgets,
        );
        expect(
          find.textContaining('thread reply', skipOffstage: false),
          findsOneWidget,
        );

        // Emit new messages that push the thread past the limit. Truncation
        // coalesces inside a 250ms wall-clock window, but crossing the 2x hard
        // cap forces the thread-aware pass on the same insert, so the pass is
        // deterministic without depending on real elapsed time.
        for (int i = 1; i <= 10; i++) {
          ircRead.emitMessage(
            TwitchMessage(
              login: 'newuser',
              text: 'new message $i',
              messageId: 'new$i',
              timestamp: DateTime.now(),
              channel: channel,
            ),
          );
          await tester.pump();
        }
        await tester.pump();

        // Thread should now be removed - pushed past maxMessages=10.
        expect(find.textContaining('thread root'), findsNothing);
        expect(find.textContaining('thread reply'), findsNothing);
      }
    });
  });

  group('Chat pause', () {
    testWidgets(
      'keepPosition holds reading position while scrolled up on arrival',
      (WidgetTester tester) async {
        final now = DateTime.now();
        final manyMessages = List.generate(
          50,
          (i) => TwitchMessage(
            login: 'user$i',
            text: 'message number $i',
            channel: 'testchannel',
            messageId: 'msg-$i',
            timestamp: now.subtract(Duration(minutes: 50 - i)),
          ),
        );
        final fakeEventSub = FakeEventSubService();
        final fakeIrc = FakeIrcService();
        final fakeIrcRead = FakeIrcReadService();
        final fakeRecent = ConfigurableRecentMessagesService(manyMessages);

        await tester.pumpWidget(
          TwitchChatApp(
            key: UniqueKey(),
            eventSubService: fakeEventSub,
            ircService: fakeIrc,
            ircReadService: fakeIrcRead,
            recentMessagesService: fakeRecent,
          ),
        );
        await tester.pump();

        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'testchannel');
        await tester.tap(find.text('Join', skipOffstage: false).last);
        await tester.pump();
        await tester.pump();

        // Scroll up - FAB appears (with reverse:true, drag DOWN = scroll UP)
        await tester.drag(find.byType(ListView).first, const Offset(0, 500));
        await tester.pump();
        await tester.pump();
        expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

        // Global y of each rendered chat row, so we can assert the rows the
        // reader is on do not move when a newer row arrives. Message bodies
        // render via Text.rich, and the body text follows the timestamp and
        // username, so match on the message substring.
        final rowText = RegExp(r'message number \d+');
        Map<String, double> visibleRowTops() {
          final rows = <String, double>{};
          final finder = find.byWidgetPredicate((w) {
            if (w is! Text) return false;
            final text = w.data ?? w.textSpan?.toPlainText() ?? '';
            return rowText.hasMatch(text);
          });
          for (final element in finder.evaluate()) {
            final box = element.renderObject;
            if (box is! RenderBox || !box.attached) continue;
            final text = (element.widget as Text).textSpan!.toPlainText();
            rows[rowText.firstMatch(text)!.group(0)!] = box
                .localToGlobal(Offset.zero)
                .dy;
          }
          return rows;
        }

        final rowsBeforeArrival = visibleRowTops();
        expect(
          rowsBeforeArrival,
          isNotEmpty,
          reason: 'row finder must match the rendered Text.rich rows',
        );

        // Emit a new message while scrolled up
        fakeIrcRead.emitMessage(
          TwitchMessage(
            login: 'newuser',
            text: 'new message while paused',
            channel: 'testchannel',
            messageId: 'new-msg',
            timestamp: DateTime.now(),
          ),
        );
        await tester.pump();
        await tester.pump();

        // FAB still visible - did not auto-scroll
        expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

        // The offset shifts to cancel the new row; what must hold is that the
        // rows the reader is on stay put on screen.
        final rowsAfterArrival = visibleRowTops();
        for (final entry in rowsBeforeArrival.entries) {
          final after = rowsAfterArrival[entry.key];
          if (after == null) continue;
          expect(
            after,
            moreOrLessEquals(entry.value, epsilon: 1.5),
            reason: '${entry.key} moved when a new row arrived',
          );
        }

        // Tap FAB to resume (jump to newest)
        await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);

        // New message IS now visible after jumping back to the bottom
        expect(
          find.textContaining('new message while paused', skipOffstage: false),
          findsOneWidget,
        );
      },
    );

    testWidgets('Announcement rows tint by accent and label child messages', (
      WidgetTester tester,
    ) async {
      {
        final fakeEventSub = FakeEventSubService();
        final fakeIrc = FakeIrcService();
        final fakeIrcRead = FakeIrcReadService();
        await tester.pumpWidget(
          TwitchChatApp(
            key: UniqueKey(),
            eventSubService: fakeEventSub,
            ircService: fakeIrc,
            ircReadService: fakeIrcRead,
          ),
        );
        await tester.pump();
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'testchannel');
        await tester.tap(find.text('Join', skipOffstage: false).last);
        await tester.pump();
        await tester.pump();

        const accent = Color(0xFF1F69FF);
        // Announcements ride USERNOTICE in production; the banner color and
        // the message text land on the rendered child row.
        fakeIrcRead.emitUserNotice(
          UserNoticeEvent(
            channel: 'testchannel',
            msgId: 'announcement',
            login: '',
            displayName: '',
            text: 'Announcement: Test announcement text',
            announcementColor: 'BLUE',
          ),
        );
        await tester.pump();

        expect(
          find.textContaining('Test announcement text', skipOffstage: false),
          findsOneWidget,
        );
        final surface = Theme.of(
          tester.element(
            find.textContaining('Test announcement text', skipOffstage: false),
          ),
        ).colorScheme.surface;
        final anchor = highlightAnchor(surface);
        final accentHue = HSLColor.fromColor(accent).hue;
        final strength = (accentHue >= 210 && accentHue <= 300)
            ? highlightStrength * 0.85
            : highlightStrength;
        final tint = matchTintContrast(
          accent,
          surface,
          anchor,
          strength: strength,
        );
        final blended = Color.alphaBlend(tint.withValues(alpha: 0.6), surface);
        // The row tint is a ColoredBox under the tile's transparency
        // Material, so ink ripples stay visible above it.
        final rows = find
            .ancestor(
              of: find.textContaining(
                'Test announcement text',
                skipOffstage: false,
              ),
              matching: find.byType(ColoredBox, skipOffstage: false),
            )
            .evaluate()
            .where((el) => (el.widget as ColoredBox).color == blended);
        expect(
          rows,
          isNotEmpty,
          reason: 'announcement should sit on a full-row accent background',
        );

        {
          final systemMsg = TwitchMessage(
            login: '',
            text: 'Plain system notice',
            isSystem: true,
            channel: 'testchannel',
          );
          fakeIrcRead.emitMessage(systemMsg);
          await tester.pump();

          expect(
            find.textContaining('Plain system notice', skipOffstage: false),
            findsOneWidget,
          );
          final surface = Theme.of(
            tester.element(
              find.textContaining('Plain system notice', skipOffstage: false),
            ),
          ).colorScheme.surface;
          final blended = Color.alphaBlend(
            const Color(0xFF1F69FF).withValues(alpha: 0.25),
            surface,
          );
          final rows = find
              .ancestor(
                of: find.textContaining(
                  'Plain system notice',
                  skipOffstage: false,
                ),
                matching: find.byType(ColoredBox),
              )
              .evaluate()
              .where((el) => (el.widget as ColoredBox).color == blended);
          expect(rows, isEmpty);
        }

        fakeIrcRead.emitUserNotice(
          UserNoticeEvent(
            channel: 'testchannel',
            msgId: 'announcement',
            login: 'ermugo2',
            displayName: 'ermugo2',
            text: 'uuh',
            announcementColor: 'PURPLE',
            userId: '1468479097',
            messageId: 'ann-1',
            color: '#0000FF',
            badges: parseIrcBadges('broadcaster/1'),
          ),
        );
        await tester.pump();

        // The child message plus its own "Announcement" label (three matches
        // with the first announcement's text).
        expect(
          find.textContaining('Announcement', skipOffstage: false),
          findsNWidgets(3),
        );
        expect(
          find.textContaining('ermugo2: uuh', skipOffstage: false),
          findsOneWidget,
        );
      }
    });
  });

  testWidgets('Autocomplete suggests users and commands and inserts picks', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
    // Resolved identity: typing needs an enabled composer.
    FlutterSecureStorage.setMockInitialValues({
      'accounts': '[{"login":"me","user_id":"42","access_token":"test_token"}]',
      'active_login': 'me',
    });
    final irc = FakeIrcService();
    final ircRead = FakeIrcReadService();
    await tester.pumpWidget(
      TwitchChatApp(
        key: UniqueKey(),
        eventSubService: FakeEventSubService(),
        ircService: irc,
        ircReadService: ircRead,
        recentMessagesService: FakeRecentMessagesService(),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'xqc');
    await tester.tap(find.text('Join', skipOffstage: false));
    await tester.pump();
    ircRead.emitMessage(
      TwitchMessage(
        login: 'UserOne',
        text: 'hello chat',
        channel: 'xqc',
        messageId: 'm1',
      ),
    );
    await tester.pump();
    irc.triggerConnect(joinChannel: 'xqc');
    ircRead.triggerConnect(joinChannel: 'xqc');
    await tester.pump();

    final input = find.byKey(const Key('message_input'));
    final dropdown = find.byKey(const Key('autocomplete_dropdown'));
    void select(Suggestion suggestion) => tester
        .widget<AutocompleteDropdown>(find.byType(AutocompleteDropdown))
        .onSelect(suggestion);
    String text() => tester.widget<TextField>(input).controller!.text;

    // One character is too short to suggest.
    await tester.enterText(input, 'U');
    await tester.pump();
    expect(dropdown, findsNothing);

    await tester.enterText(input, 'Us');
    await tester.pump();
    expect(
      find.descendant(
        of: dropdown,
        matching: find.text('UserOne', skipOffstage: false),
      ),
      findsOneWidget,
    );

    await tester.enterText(input, '@Us');
    await tester.pump();
    select(UserSuggestion(displayName: 'UserOne'));
    await tester.pump();
    expect(text(), '@UserOne ');

    // Every command is offered, including mod-only ones.
    await tester.enterText(input, '/');
    await tester.pump();
    for (final command in ['/me', '/color', '/ban']) {
      expect(
        find.descendant(of: dropdown, matching: find.text(command)),
        findsOneWidget,
      );
    }
    select(const CommandSuggestion(command: '/me'));
    await tester.pump();
    expect(text(), '/me ');

    select(
      EmoteSuggestion(
        emote: makeTestEmote(id: 'recent-e1', code: 'RecentEmote'),
      ),
    );
    // The usage write is fire-and-forget; two pumps flush its microtasks.
    await tester.pump();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    expect(
      container.read(emoteUsageRegistryProvider).recentEmoteIds,
      contains('recent-e1'),
    );
    await tester.pumpAndSettle();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> joinChannel(WidgetTester tester, String name) async {
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, name);
    await tester.tap(find.text('Join', skipOffstage: false).last);
    await tester.pumpAndSettle();
    await tester.pump();
  }

  Future<void> tapChannel(WidgetTester tester, String channel) async {
    final barText = find.text(channel, skipOffstage: false).first;
    await tester.ensureVisible(barText);
    await tester.pump();
    await tester.tap(barText);
    await tester.pumpAndSettle();
    await tester.pump();
  }

  // Glass swaps the floating header for the docked layout when the keyboard
  // leaves too little room. The swap remounted the pages: one frame of the
  // first channel, and the chat lost its scroll position (iOS, 0.9.5).
  testWidgets('glass keyboard collapse keeps the page and chat position', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'liquid_glass': true});
    final msgs = List.generate(
      50,
      (i) => TwitchMessage(
        login: 'user$i',
        text: 'message number $i',
        channel: 'b',
        messageId: 'msg-$i',
        timestamp: DateTime.now().subtract(Duration(minutes: 50 - i)),
      ),
    );
    await tester.pumpWidget(
      TwitchChatApp(
        key: UniqueKey(),
        eventSubService: FakeEventSubService(),
        ircService: FakeIrcService(),
        ircReadService: FakeIrcReadService(),
        recentMessagesService: ConfigurableRecentMessagesService(msgs),
      ),
    );
    await tester.pump();
    await joinChannel(tester, 'a');
    await joinChannel(tester, 'b');
    await tester.drag(find.byType(ListView).first, const Offset(0, 300));
    await tester.pumpAndSettle();

    ScrollableState chat() => tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    double? page() =>
        tester.widget<PageView>(find.byType(PageView).first).controller!.page;
    final list = chat();
    final pixels = list.position.pixels;
    final selected = page();
    expect(pixels, greaterThan(0));

    for (final kb in [1200.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: kb);
      await tester.pump(const Duration(milliseconds: 16));
      expect(page(), selected, reason: 'flip frame, kb=$kb');
      await tester.pumpAndSettle();
      expect(identical(chat(), list), isTrue, reason: 'remounted, kb=$kb');
      expect(chat().position.pixels, pixels, reason: 'kb=$kb');
    }
    tester.view.reset();
  });

  group('Channel bar', () {
    testWidgets('Removing the last channel hides the channel bar', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(TwitchChatApp(key: UniqueKey()));
      await tester.pump();
      expect(find.byType(TabBar), findsNothing);

      await joinChannel(tester, 'xqc');
      expect(find.byType(TabBar), findsOneWidget);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings', skipOffstage: false));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channels', skipOffstage: false));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.remove_circle_outline));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('xqc'), findsNothing);
      expect(find.byType(TabBar), findsNothing);
    });

    testWidgets('Joining a channel selects it, not its neighbor', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(TwitchChatApp(key: UniqueKey()));
      await tester.pump();

      await joinChannel(tester, 'alpha');
      await joinChannel(tester, 'beta');
      await tester.pumpAndSettle();
      final bar0 = tester.widget<TabBar>(find.byType(TabBar).first);
      expect(bar0.controller!.length, 2);
      expect(bar0.controller!.index, 1);

      await joinChannel(tester, 'gamma');
      await tester.pumpAndSettle();
      await tester.pump();
      // A regression lands on the neighbor (beta, index 1) instead.
      final bar1 = tester.widget<TabBar>(find.byType(TabBar).first);
      expect(bar1.controller!.length, 3);
      expect(bar1.controller!.index, 2);
    });

    testWidgets('Channel focus follows swipe thresholds with hysteresis', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(TwitchChatApp(key: UniqueKey()));
      await tester.pump();
      await joinChannel(tester, 'a');
      await joinChannel(tester, 'b');

      FontWeight? weight(String name) => tester
          .widget<Text>(
            find.descendant(
              of: find.byType(TabBar),
              matching: find.text(name, skipOffstage: false),
            ),
          )
          .style
          ?.fontWeight;

      // Drags from a toward b by each fraction in turn, still holding.
      Future<TestGesture> dragFromA(List<double> fractions) async {
        await tapChannel(tester, 'a');
        final size = tester.getSize(find.byType(PageView));
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(PageView)),
        );
        await gesture.moveBy(const Offset(-kTouchSlop - 1, 0));
        await tester.pump();
        for (final f in fractions) {
          await gesture.moveBy(Offset(size.width * f, 0));
          await tester.pump();
        }
        return gesture;
      }

      expect(weight('b'), FontWeight.w600);
      expect(weight('a'), FontWeight.normal);

      // Past half: focus switches mid-drag, before release.
      var gesture = await dragFromA([-0.55]);
      expect(weight('b'), FontWeight.w600);
      expect(weight('a'), FontWeight.normal);
      await gesture.up();
      await tester.pumpAndSettle();

      // Under half: focus stays.
      gesture = await dragFromA([-0.45]);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(weight('a'), FontWeight.w600);
      expect(weight('b'), FontWeight.normal);

      // Cross half, then come back under: focus returns.
      gesture = await dragFromA([-0.6, 0.3]);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(weight('a'), FontWeight.w600);
    });
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  Emote sevenTv(String id, String code) => Emote(
    id: id,
    code: code,
    meta: const SevenTvMeta(),
    scales: {EmoteScale.medium: 'https://example.com/$id.png'},
    scope: EmoteScope.channel,
  );

  Widget wrapEmoteMenu(EmoteManager manager) {
    return ProviderScope(
      overrides: [
        emoteManagerProvider.overrideWithValue(manager),
        // The panel observes emoteStateProvider, which watches the store, so
        // the test manager's own store must back it.
        emoteStoreProvider.overrideWithValue(manager.store),
      ],
      child: MaterialApp(
        key: UniqueKey(),
        home: Scaffold(
          body: EmoteMenuPanelWidget(
            isActive: true,
            selectedChannel: 'ch',
            onEmoteSelected: (_) {},
            onClose: () {},
            scrollController: ScrollController(),
            sheetCtrl: DraggableScrollableController(),
            emoteMaxFraction: 0.8,
          ),
        ),
      ),
    );
  }

  testWidgets(
    'SevenTV list updates reuse elements across inserts and removals',
    (WidgetTester tester) async {
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        usageFlushDelay: Duration.zero,
        removeCachedFile: (url) async {},
      );
      manager.updateSevenTvEmotes(
        'ch',
        added: [
          sevenTv('a', 'Alpha'),
          sevenTv('c', 'Charlie'),
          sevenTv('d', 'Delta'),
        ],
      );

      await tester.pumpWidget(wrapEmoteMenu(manager));
      await tester.tap(find.text('Channel', skipOffstage: false));
      // The loading band animates indefinitely, so pump fixed durations
      // instead of pumpAndSettle (which would never settle).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final alphaElement = tester.element(find.byKey(const ValueKey('a')));
      final deltaElement = tester.element(find.byKey(const ValueKey('d')));

      void expectReused() {
        expect(
          tester.element(find.byKey(const ValueKey('a'))),
          same(alphaElement),
        );
        expect(
          tester.element(find.byKey(const ValueKey('d'))),
          same(deltaElement),
        );
      }

      // Keyed reconciliation: neighbors keep their elements on insert/remove.
      manager.updateSevenTvEmotes('ch', added: [sevenTv('b', 'Bravo')]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expectReused();
      expect(find.byKey(const ValueKey('b')), findsOneWidget);

      manager.updateSevenTvEmotes('ch', removedIds: ['b']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expectReused();
      expect(find.byKey(const ValueKey('b')), findsNothing);
    },
  );

  group('Chat notices and snackbars', () {
    testWidgets('notice floats above the composer, acts, and dismisses', (
      tester,
    ) async {
      final controller = ChatNoticeController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(noticeHarness(controller));
      final chatSize = tester.getSize(find.byKey(const Key('notice-chat')));

      controller.show('hello');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final barBottom = tester.getBottomLeft(find.text('hello')).dy;
      final composerTop = tester
          .getTopLeft(find.byKey(const Key('notice-composer')))
          .dy;
      expect(composerTop, greaterThan(barBottom));
      // Overlay: the chat keeps its size instead of shrinking.
      expect(tester.getSize(find.byKey(const Key('notice-chat'))), chatSize);

      await tester.fling(find.text('hello'), const Offset(400, 0), 800);
      await tester.pumpAndSettle();
      expect(find.text('hello'), findsNothing);

      var pressed = 0;
      controller.show(
        'copied',
        actionLabel: 'Paste',
        onAction: () => pressed++,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Paste'));
      await tester.pump();
      expect(pressed, 1);
      expect(find.text('copied'), findsNothing);

      controller.show('later', duration: const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('later'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.text('later'), findsNothing);
    });

    testWidgets('overlay snackbar replaces, and pops on page changes only', (
      tester,
    ) async {
      await tester.pumpWidget(snackHarness());
      final context = tester.element(find.text('show snack'));
      AppSnack.show(context, 'first');
      await tester.pump();
      AppSnack.show(context, 'second');
      await tester.pump();
      expect(find.text('first'), findsNothing);
      expect(find.text('second'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);

      // A dialog leaves it alone.
      showDialog(
        context: context,
        builder: (_) => const AlertDialog(content: Text('dialog')),
      );
      await tester.pumpAndSettle();
      expect(find.text('second'), findsOneWidget);
      Navigator.of(tester.element(find.text('dialog'))).pop();
      await tester.pumpAndSettle();

      // A page push pops it.
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('next'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('second'), findsNothing);

      // So does a page pop.
      final next = tester.element(find.text('next'));
      AppSnack.show(next, 'on next');
      await tester.pump();
      expect(find.text('on next'), findsOneWidget);
      Navigator.of(next).pop();
      await tester.pumpAndSettle();
      expect(find.text('on next'), findsNothing);
    });

    group('ChatNoticeController', () {
      testWidgets('show replaces and dismiss clears the current notice', (
        tester,
      ) async {
        final controller = ChatNoticeController();
        addTearDown(controller.dispose);
        controller.show('first');
        controller.show('second');
        expect(controller.current?.message, 'second');
        controller.dismiss();
        expect(controller.current, isNull);
      });

      testWidgets('auto-dismisses after the duration', (tester) async {
        final controller = ChatNoticeController();
        addTearDown(controller.dispose);
        controller.show('hello', duration: const Duration(seconds: 1));
        await tester.pump(const Duration(milliseconds: 900));
        expect(controller.current, isNotNull);
        await tester.pump(const Duration(milliseconds: 200));
        expect(controller.current, isNull);
      });

      testWidgets('replace resets the auto-dismiss timer', (tester) async {
        final controller = ChatNoticeController();
        addTearDown(controller.dispose);
        controller.show('first', duration: const Duration(seconds: 1));
        await tester.pump(const Duration(milliseconds: 700));
        controller.show('second', duration: const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 700));
        expect(controller.current?.message, 'second');
        await tester.pump(const Duration(seconds: 2));
        expect(controller.current, isNull);
      });
    });
  });

  group('chrome menu entries', () {
    Widget chromeMenuHarness({
      bool showMod = false,
      VoidCallback? onMod,
      VoidCallback? onSearch,
    }) => MaterialApp(
      home: Scaffold(
        body: ChromeMenuButton(
          onToggleFullscreen: () {},
          onToggleInput: () {},
          onShowModView: onMod,
          showModView: () => showMod,
          onToggleSearch: onSearch,
        ),
      ),
    );

    Future<void> openChromeMenu(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
    }

    testWidgets('Mod view is gated and Search always fires', (tester) async {
      var opened = false;
      await tester.pumpWidget(
        chromeMenuHarness(showMod: true, onMod: () => opened = true),
      );
      await openChromeMenu(tester);
      await tester.tap(find.text('Mod view'));
      await tester.pumpAndSettle();
      expect(opened, isTrue);

      var toggled = false;
      await tester.pumpWidget(
        chromeMenuHarness(showMod: false, onSearch: () => toggled = true),
      );
      await openChromeMenu(tester);
      expect(find.text('Mod view'), findsNothing);
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      expect(toggled, isTrue);
    });
  });

  testWidgets('PiP collapse keeps only the video', (tester) async {
    await tester.pumpWidget(pipCollapseHarness(isInPip: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pip-video')), findsOneWidget);
    expect(find.byKey(const Key('pip-composer')), findsNothing);
    expect(find.byKey(const Key('pip-thread')), findsNothing);

    await tester.pumpWidget(pipCollapseHarness(isInPip: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pip-composer')), findsOneWidget);
    expect(find.byKey(const Key('pip-thread')), findsOneWidget);
  });

  group('Background channel window', () {
    testWidgets('a background channel freezes and catches up on refocus', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final irc = FakeIrcService();
      final ircRead = FakeIrcReadService();
      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: FakeEventSubService(),
          recentMessagesService: ConfigurableRecentMessagesService(const []),
          ircService: irc,
          ircReadService: ircRead,
        ),
      );
      await tester.pump();

      Future<void> join(String name) async {
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, name);
        await tester.tap(find.text('Join', skipOffstage: false).last);
        await tester.pump();
        await tester.pump();
      }

      Future<void> focusTab(String name) async {
        await tester.tap(
          find.descendant(of: find.byType(TabBar), matching: find.text(name)),
        );
        await tester.pumpAndSettle();
      }

      await join('alpha');
      irc.triggerConnect(joinChannel: 'alpha');
      ircRead.triggerConnect(joinChannel: 'alpha');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      ircRead.emitMessage(
        TwitchMessage(
          login: 'alice',
          text: 'alpha first',
          channel: 'alpha',
          messageId: 'a1',
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('alpha first', skipOffstage: false),
        findsOneWidget,
      );

      // Join beta and focus it; alpha stays mounted as the adjacent page.
      await join('beta');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await focusTab('beta');

      ircRead.emitMessage(
        TwitchMessage(
          login: 'bob',
          text: 'alpha second',
          channel: 'alpha',
          messageId: 'a2',
        ),
      );
      ircRead.emitMessage(
        TwitchMessage(
          login: 'carol',
          text: 'beta first',
          channel: 'beta',
          messageId: 'b1',
        ),
      );
      await tester.pump();

      // The focused channel updates; the background one holds its last frame.
      expect(
        find.textContaining('beta first', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('alpha second', skipOffstage: false),
        findsNothing,
      );

      // Refocusing alpha flushes the messages it missed.
      await focusTab('alpha');
      expect(
        find.textContaining('alpha second', skipOffstage: false),
        findsOneWidget,
      );
    });
  });
}

/// Records outgoing chat lines; the base write socket drops them unconnected.
class _RecordingIrcService extends FakeIrcService {
  final sent = <({String channel, String text, String? replyParent})>[];

  @override
  void sendMessage(
    String channelName,
    String text, {
    String? replyParentMessageId,
  }) {
    sent.add((
      channel: channelName,
      text: text,
      replyParent: replyParentMessageId,
    ));
  }
}
