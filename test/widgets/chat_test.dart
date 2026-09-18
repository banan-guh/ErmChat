import 'widget_test_harness.dart';

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
    'Home screen shows empty state prompts for signed out and signed in users',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: FakeEventSubService(),
          ircService: FakeIrcService(),
          recentMessagesService: FakeRecentMessagesService(),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.add), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      expect(find.byIcon(Icons.settings), findsNothing);
      expect(
        find.textContaining(
          'Configure Twitch credentials in Settings first',
          skipOffstage: false,
        ),
        findsWidgets,
      );
      // Let the anonymous-mode socket attempts resolve so no timer pends.
      await tester.pumpAndSettle();

      FlutterSecureStorage.setMockInitialValues({
        'accounts': '[{"login":"alice","access_token":"tok_a"}]',
        'active_login': 'alice',
        'access_token': 'tok_a',
      });
      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: FakeEventSubService(),
          ircService: FakeIrcService(),
          recentMessagesService: FakeRecentMessagesService(),
        ),
      );
      await tester.pump();

      expect(
        find.textContaining('Signed in as alice', skipOffstage: false),
        findsWidgets,
      );
      expect(
        find.textContaining('Press + to join a channel', skipOffstage: false),
        findsWidgets,
      );
      expect(
        find.textContaining('Configure Twitch', skipOffstage: false),
        findsNothing,
      );
      await tester.pumpAndSettle();
    },
  );

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

  testWidgets('chrome menu offers Show stream without live status', (
    WidgetTester tester,
  ) async {
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

    // WebView has no platform view in tests, so open the menu but never
    // tap the item itself.
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();

    expect(find.text('Toggle fullscreen'), findsOneWidget);
    expect(find.text('Toggle input'), findsOneWidget);
    expect(find.text('Show stream'), findsOneWidget);
  });

  testWidgets('fullscreen toggles immersive system bars', (
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

    Future<void> toggleFullscreen() async {
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Toggle fullscreen'));
      await tester.pumpAndSettle();
    }

    modes.clear();
    await toggleFullscreen();
    expect(modes.last, 'SystemUiMode.immersiveSticky');

    // The chrome menu arrow survives fullscreen so the bars come back.
    await toggleFullscreen();
    expect(modes.last, 'SystemUiMode.edgeToEdge');
  });

  testWidgets('toggle input hides and restores the composer without errors', (
    WidgetTester tester,
  ) async {
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

    Future<void> toggleInput() async {
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Toggle input'));
      await tester.pumpAndSettle();
    }

    // Composer visible before the toggle.
    expect(find.byType(MessageInput), findsOneWidget);

    // Hide with the keyboard closed: chat and chrome survive.
    await toggleInput();
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byType(MessageInput), findsNothing);
    expect(find.text('xqc', skipOffstage: false), findsWidgets);

    // Restore: composer comes back.
    await toggleInput();
    expect(tester.takeException(), isNull);
    expect(find.byType(MessageInput), findsOneWidget);

    // Hide with the keyboard open: no strand, no error.
    await tester.tap(find.byType(MessageInput));
    await tester.showKeyboard(find.byType(TextField).first);
    await tester.pump();
    await toggleInput();
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byType(MessageInput), findsNothing);
    expect(find.text('xqc', skipOffstage: false), findsWidgets);
  });

  group('stacked player with keyboard', () {
    testWidgets('video shown without keyboard, audio hidden', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      tester.view.viewInsets = FakeViewPadding(bottom: 0);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        stackedPlayerHarness(showVideo: true, keyboardH: 0),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      // Default finders skip offstage: found means painted, not Offstage.
      expect(find.byKey(stackedVideoKey), findsOneWidget);
      expect(find.byKey(stackedAudioKey), findsNothing);
      expect(
        tester.getSize(find.byKey(stackedVideoKey)).height,
        moreOrLessEquals(202.5, epsilon: 1.0),
      );
    });

    testWidgets('keyboard hides video but keeps it attached with audio', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      tester.view.viewInsets = FakeViewPadding(bottom: 0);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        stackedPlayerHarness(showVideo: true, keyboardH: 0),
      );
      await tester.pumpAndSettle();
      final before = tester.element(find.byKey(stackedVideoKey));

      // Stream enabled + keyboard opening in the same frame.
      tester.view.viewInsets = FakeViewPadding(bottom: 300 * 3.0);
      await tester.pumpWidget(
        stackedPlayerHarness(showVideo: false, keyboardH: 300),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      // Default finders skip offstage: found means painted, not Offstage.
      expect(find.byKey(stackedVideoKey), findsOneWidget);
      expect(find.byKey(stackedAudioKey), findsOneWidget);
      // Inner box keeps full 16:9 size while only a 1px clip shows.
      expect(
        tester.getSize(find.byKey(stackedVideoKey)).height,
        moreOrLessEquals(202.5, epsilon: 1.0),
      );
      // Same element: WebView state would survive the toggle.
      expect(
        identical(tester.element(find.byKey(stackedVideoKey)), before),
        isTrue,
      );
    });

    testWidgets('rapid show/hide flapping never errors', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      tester.view.viewInsets = FakeViewPadding(bottom: 0);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        stackedPlayerHarness(showVideo: true, keyboardH: 0),
      );
      await tester.pump();
      await tester.pumpWidget(
        stackedPlayerHarness(showVideo: false, keyboardH: 300),
      );
      await tester.pump();
      await tester.pumpWidget(
        stackedPlayerHarness(showVideo: true, keyboardH: 300),
      );
      await tester.pump();
      await tester.pumpWidget(
        stackedPlayerHarness(showVideo: false, keyboardH: 300),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(find.byKey(stackedVideoKey), findsOneWidget);
      expect(find.byKey(stackedAudioKey), findsOneWidget);
    });

    testWidgets('composer height arrives post-layout without size reads', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      tester.view.viewInsets = FakeViewPadding(bottom: 0);
      addTearDown(tester.view.reset);

      double? seenComposerH;
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
                    seenComposerH = composerH;
                    // The real decision path, with settled inputs only.
                    final show = shouldShowStreamVideo(
                      maxWidth: maxWidth,
                      maxHeight: maxHeight,
                      keyboardH: keyboardH,
                      inputH: composerH,
                      chatFontSize: 14,
                    );
                    return Column(
                      children: [
                        Expanded(
                          child: TabbedLayout(
                            tabs: const ['xqc'],
                            selectedIndex: 0,
                            onSelectedIndexChanged: (_) {},
                            belowTabBar: buildStackedPlayer(
                              show: show,
                              video: stackedStubVideo(),
                              audioBar: stackedStubAudio(),
                            ),
                            pageBuilder: (_, _) =>
                                const ColoredBox(color: Colors.green),
                          ),
                        ),
                      ],
                    );
                  },
              threadPanel: const SizedBox.shrink(),
              mentionsPanel: const SizedBox.shrink(),
              modViewPanel: const SizedBox.shrink(),
              emotePickerBuilder: (_, {required sheetBoxHeight}) =>
                  const SizedBox.shrink(),
              autocomplete: const SizedBox.shrink(),
              emoteMaxFraction: 0.6,
              keyboardH: 0,
              composer: const SizedBox(height: 56),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(seenComposerH, moreOrLessEquals(56.0, epsilon: 1.0));
      expect(find.byKey(stackedVideoKey), findsOneWidget);
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

  group('ChatMessageTile deleted rows', () {
    TwitchMessage deletedMsg() => TwitchMessage(
      login: 'alice',
      text: 'gone',
      channel: 'test',
      messageId: 'm1',
    )..deleted = true;

    Widget buildTile({required bool fadeDeleted}) => MaterialApp(
      key: UniqueKey(),
      home: Scaffold(
        body: ChatMessageTile(
          message: deletedMsg(),
          channel: 'test',
          surface: Colors.white,
          textScale: 1.0,
          buildBadgeSpans: (_, _, {double badgeScale = 1.0}) => const [],
          buildMessageSpans:
              (_, _, _, {colored = false, textScale = 1.0, onImageTap}) =>
                  <InlineSpan>[TextSpan(text: 'gone')],
          bodyIsCached: (_, _) => false,
          fadeDeleted: fadeDeleted,
        ),
      ),
    );

    testWidgets('Deleted rows fade only when fading is enabled', (
      tester,
    ) async {
      await tester.pumpWidget(buildTile(fadeDeleted: true));
      final opacity = tester.widget<Opacity>(find.byType(Opacity));
      expect(opacity.opacity, lessThan(1.0));

      await tester.pumpWidget(buildTile(fadeDeleted: false));
      await tester.pump();
      expect(find.byType(Opacity), findsNothing);
      // The body is a Text.rich, so match on the rendered rich text.
      expect(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().contains('gone'),
        ),
        findsOneWidget,
      );
    });

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

  testWidgets('Notification bell opens mentions modal', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(TwitchChatApp(key: UniqueKey()));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'xqc');
    await tester.tap(find.text('Join', skipOffstage: false));
    await tester.pump();

    // Mentions panel is always mounted but closed with null data.
    expect(find.text('No mentions or whispers'), findsNothing);

    await tester.tap(find.byIcon(Icons.notifications_active));
    await tester.pumpAndSettle();

    expect(
      find.text('Mentions / Whispers', skipOffstage: false),
      findsOneWidget,
    ); // title
    expect(find.text('Mentions', skipOffstage: false), findsOneWidget); // tab
    expect(find.text('Whispers', skipOffstage: false), findsOneWidget); // tab
    expect(
      find.textContaining('No mentions or whispers', skipOffstage: false),
      findsOneWidget,
    );
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
      await gesture.moveBy(const Offset(1, 0));
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

  testWidgets(
    'Incoming whisper turns the bell red and shows in the Whispers tab',
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

      ircRead.emitWhisper(
        TwitchMessage(
          login: 'carol',
          text: 'hello @me',
          channel: null,
          messageId: 'w1',
        ),
      );
      await tester.pump();

      expect(
        tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
        isNotNull,
      );

      await tester.tap(find.byIcon(Icons.notifications_active));
      await tester.pumpAndSettle();

      // The bell tap clears all unread (mentions + whispers).
      expect(
        tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
        isNull,
      );

      await tester.tap(find.text('Whispers', skipOffstage: false));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('hello @me', skipOffstage: false),
        findsOneWidget,
      );
    },
  );

  testWidgets('Long pressed mention and whisper rows open the copy menu', (
    WidgetTester tester,
  ) async {
    {
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
      expect(row, findsAtLeast(1));
      await tester.longPress(row.last);
      await tester.pumpAndSettle();

      expect(find.text('Copy message', skipOffstage: false), findsOneWidget);
      expect(find.text('More...', skipOffstage: false), findsOneWidget);
      expect(find.text('Reply to message', skipOffstage: false), findsNothing);
    }
    {
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

      ircRead.emitWhisper(
        TwitchMessage(
          login: 'carol',
          text: 'psst',
          channel: null,
          messageId: 'w-panel-1',
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.notifications_active));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Whispers', skipOffstage: false));
      await tester.pumpAndSettle();

      final row = find.textContaining('psst', skipOffstage: false);
      expect(row, findsAtLeast(1));
      await tester.longPress(row.last);
      await tester.pumpAndSettle();

      expect(find.text('Copy message', skipOffstage: false), findsOneWidget);
      expect(find.text('More...', skipOffstage: false), findsOneWidget);
      expect(find.text('Reply to message', skipOffstage: false), findsNothing);
    }
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

      await tester.tap(find.byIcon(Icons.notifications_active));
      await tester.pumpAndSettle();

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

  testWidgets(
    'Message timestamps render in default and custom formats and hide when disabled',
    (WidgetTester tester) async {
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
          'timestamp_format': 'h:mm a',
          'show_timestamps': true,
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
          find.textContaining(
            RegExp(r'\d{1,2}:\d{2} (AM|PM)'),
            skipOffstage: false,
          ),
          findsAtLeast(1),
        );
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
    },
  );

  testWidgets('Connected notice inserts once and survives history load', (
    WidgetTester tester,
  ) async {
    {
      final fakeEventSub = FakeEventSubService();
      final fakeRecent = FakeRecentMessagesService();
      final fakeIrc = FakeIrcService();
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: fakeEventSub,
          recentMessagesService: fakeRecent,
          ircService: fakeIrc,
        ),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'testchannel');
      await tester.tap(find.text('Join', skipOffstage: false));
      await tester.pumpAndSettle();
      expect(find.textContaining('Connected'), findsNothing);
      fakeIrc.triggerConnect(joinChannel: 'testchannel');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(
        find.textContaining('Connected', skipOffstage: false),
        findsOneWidget,
      );
      expect(find.textContaining('Disconnected'), findsNothing);
    }
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
    {
      final fakeEventSub = FakeEventSubService();
      final fakeIrc = FakeIrcService();
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: fakeEventSub,
          recentMessagesService: FakeRecentMessagesService(),
          ircService: fakeIrc,
        ),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'testchannel');
      await tester.tap(find.text('Join', skipOffstage: false).last);
      await tester.pump();
      await tester.pump();
      fakeIrc.triggerConnect(joinChannel: 'testchannel');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(
        find.textContaining('Connected', skipOffstage: false),
        findsOneWidget,
      );
      fakeIrc.triggerConnect(joinChannel: 'testchannel');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(
        find.textContaining('Connected', skipOffstage: false),
        findsOneWidget,
      );
    }
  });

  testWidgets('Reconnect refetch dedups and shows gaps and merges in order', (
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
            text: 'first message',
            channel: 'xqc',
            messageId: 'a1',
            timestamp: now.subtract(const Duration(minutes: 5)),
          ),
          TwitchMessage(
            login: 'bob',
            text: 'second message',
            channel: 'xqc',
            messageId: 'a2',
            timestamp: now.subtract(const Duration(minutes: 4)),
          ),
        ],
        [
          TwitchMessage(
            login: 'bob',
            text: 'second message',
            channel: 'xqc',
            messageId: 'a2',
            timestamp: now.subtract(const Duration(minutes: 4)),
          ),
          TwitchMessage(
            login: 'carol',
            text: 'third message',
            channel: 'xqc',
            messageId: 'a3',
            timestamp: now.subtract(const Duration(minutes: 3)),
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
        find.textContaining('first message', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('second message', skipOffstage: false),
        findsOneWidget,
      );

      // First connect must not trigger a history re-fetch.
      fakeIrc.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(recent.callCount, 1);

      // Reconnect: robotty returns one duplicate + one new message.
      fakeIrc.triggerDisconnect();
      await tester.pump();
      fakeIrc.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(recent.callCount, 2);
      expect(
        find.textContaining('third message', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('second message', skipOffstage: false),
        findsOneWidget,
        reason: 'duplicate from re-fetch must be discarded',
      );
      expect(
        find.textContaining('first message', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'History: Not all messages retrieved',
          skipOffstage: false,
        ),
        findsNothing,
      );
    }
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
    {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
      final eventSub3 = FakeEventSubService();
      final irc3 = FakeIrcService();
      final recent3 = GappedRecentMessagesService();
      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: eventSub3,
          recentMessagesService: recent3,
          ircService: irc3,
        ),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'testchannel');
      await tester.tap(find.text('Join', skipOffstage: false).last);
      await tester.pump();
      await tester.pump();

      irc3.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(
        find.textContaining('early message', skipOffstage: false),
        findsWidgets,
      );

      irc3.triggerDisconnect();
      await tester.pump();
      irc3.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(
        find.textContaining('missed during gap', skipOffstage: false),
        findsWidgets,
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

  testWidgets('reconnect refetch folds duplicated id-less system rows', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'access_token': 'test_token',
      'channels': ['xqc'],
    });
    FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});

    final now = DateTime.now();
    final refetchGate = Completer<void>();
    const dupBanText = 'spammer was timed out for 5m.';
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
          // Same event the live socket already delivered while the app was
          // connected: identical text, near-identical timestamp, no id.
          TwitchMessage(
            login: 'spammer',
            text: dupBanText,
            channel: 'xqc',
            isSystem: true,
            isBanNotice: true,
            timestamp: now,
          ),
          // A distinct event must still come through.
          TwitchMessage(
            login: 'otheruser',
            text: 'otheruser was banned.',
            channel: 'xqc',
            isSystem: true,
            isBanNotice: true,
            timestamp: now.subtract(const Duration(seconds: 30)),
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

    fakeIrcRead.emitBan(
      'spammer',
      isTimeout: true,
      durationSeconds: 300,
      channel: 'xqc',
    );
    // Socket decode delivers asynchronously; the first pump flushes it.
    await tester.pump();
    await tester.pump();
    expect(
      find.textContaining(dupBanText, skipOffstage: false),
      findsOneWidget,
    );

    fakeIrc.triggerDisconnect();
    fakeIrcRead.triggerDisconnect();
    await tester.pump();
    fakeIrc.triggerConnect();
    fakeIrcRead.triggerConnect();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(recent.callCount, 2, reason: 'reconnect must trigger a re-fetch');

    refetchGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(
      find.textContaining(dupBanText, skipOffstage: false),
      findsOneWidget,
      reason: 'the backfilled copy of the ban line must fold away',
    );
    expect(
      find.textContaining('otheruser was banned.', skipOffstage: false),
      findsOneWidget,
      reason: 'a distinct id-less system row must still be inserted',
    );
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
          final child = TwitchMessage(
            login: 'bob',
            text: 'child msg',
            messageId: 'c1',
            replyToParentId: 'p1',
            replyToUser: 'alice',
            replyToText: 'parent msg',
            timestamp: now.subtract(const Duration(minutes: 4)),
            isHistory: true,
            channel: channel,
          );
          await joinChannel(
            tester,
            channelName: channel,
            history: [parent, child],
          );

          await tester.tap(
            find.textContaining(
              'replying to alice: parent msg',
              skipOffstage: false,
            ),
          );
          await tester.pumpAndSettle();

          expect(find.text('Threads', skipOffstage: false), findsOneWidget);
          expect(find.byIcon(Icons.close), findsOneWidget);
          expect(
            find.textContaining('parent msg', skipOffstage: false),
            findsAtLeast(1),
          );
          expect(
            find.textContaining('child msg', skipOffstage: false),
            findsAtLeast(1),
          );
        }
        {
          const channel = 'testchannel';
          final parent = TwitchMessage(
            login: 'alice',
            text: 'parent msg',
            messageId: 'p1',
            timestamp: now.subtract(const Duration(minutes: 5)),
            channel: channel,
          );
          final child = TwitchMessage(
            login: 'bob',
            text: 'child msg',
            messageId: 'c1',
            replyToParentId: 'p1',
            replyToUser: 'alice',
            replyToText: 'parent msg',
            timestamp: now.subtract(const Duration(minutes: 4)),
            isHistory: true,
            channel: channel,
          );
          await joinChannel(
            tester,
            channelName: channel,
            history: [parent, child],
          );

          await tester.longPress(
            find.textContaining('bob: child msg', skipOffstage: false),
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
            find.textContaining('child msg', skipOffstage: false),
            findsAtLeast(1),
          );
        }
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
              'replying to bob: mid level',
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
          find.textContaining('replying to alice', skipOffstage: false),
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
              'replying to unknown_user: missing text',
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

    testWidgets('Long pressed thread rows open the copy menu', (
      WidgetTester tester,
    ) async {
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
          'replying to alice: parent msg',
          skipOffstage: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Threads', skipOffstage: false), findsOneWidget);

      final childInThread = find.textContaining(
        'bob: child msg',
        skipOffstage: false,
      );
      expect(childInThread, findsAtLeast(1));
      await tester.longPress(childInThread.first);
      await tester.pumpAndSettle();

      expect(find.text('Copy message', skipOffstage: false), findsOneWidget);
      expect(find.text('More...', skipOffstage: false), findsOneWidget);
      expect(find.text('Reply to message', skipOffstage: false), findsNothing);
    });

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
            'replying to alice: parent msg',
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

    testWidgets('Ban and timeout notices describe the action and duration', (
      WidgetTester tester,
    ) async {
      {
        final eventSub = FakeEventSubService();
        final irc = FakeIrcService();
        final ircRead = FakeIrcReadService();
        await setupChannel(
          tester,
          eventSub: eventSub,
          irc: irc,
          ircReadService: ircRead,
        );

        ircRead.emitBan('baduser', isTimeout: false, channel: 'testchannel');
        await tester.pump();

        expect(
          find.textContaining('baduser was banned', skipOffstage: false),
          findsOneWidget,
        );
      }
      {
        final eventSub = FakeEventSubService();
        final irc = FakeIrcService();
        final ircRead = FakeIrcReadService();
        await setupChannel(
          tester,
          eventSub: eventSub,
          irc: irc,
          ircReadService: ircRead,
        );

        ircRead.emitBan(
          'spammer',
          isTimeout: true,
          durationSeconds: 300,
          channel: 'testchannel',
        );
        await tester.pump();

        expect(
          find.textContaining(
            'spammer was timed out for 5m.',
            skipOffstage: false,
          ),
          findsOneWidget,
        );
      }
      {
        final eventSub = FakeEventSubService();
        final irc = FakeIrcService();
        final ircRead = FakeIrcReadService();
        await setupChannel(
          tester,
          eventSub: eventSub,
          irc: irc,
          ircReadService: ircRead,
        );

        ircRead.emitBan('spammer', isTimeout: true, channel: 'testchannel');
        await tester.pump();

        expect(
          find.textContaining('spammer was timed out', skipOffstage: false),
          findsOneWidget,
        );
        expect(find.textContaining('for '), findsNothing);
      }
    });

    testWidgets('Deletion leaves a tombstone and greys out cleared messages', (
      WidgetTester tester,
    ) async {
      {
        final eventSub = FakeEventSubService();
        final irc = FakeIrcService();
        final ircRead = FakeIrcReadService();
        await setupChannel(
          tester,
          eventSub: eventSub,
          irc: irc,
          ircReadService: ircRead,
        );

        ircRead.emitDeleted(
          'root-1',
          'testchannel',
          user: 'alice',
          deletedMessageText: 'hello world',
        );
        await tester.pump();

        expect(
          find.textContaining(
            'A message from alice was deleted',
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining('hello world', skipOffstage: false),
          findsAtLeast(1),
        );
      }
      {
        final eventSub = FakeEventSubService();
        final irc = FakeIrcService();
        final ircRead = FakeIrcReadService();
        await setupChannel(
          tester,
          eventSub: eventSub,
          irc: irc,
          ircReadService: ircRead,
        );

        // Send a live message and let its tile cache/element settle.
        ircRead.emitMessage(
          TwitchMessage(
            login: 'bob',
            text: 'will be deleted',
            channel: 'testchannel',
            messageId: 'live-1',
          ),
        );
        await tester.pump();
        // A second live message shifts the first, forcing a real reconciliation.
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

        // The deleted message's tile must still be visible (greyed out, not removed).
        expect(
          find.textContaining('will be deleted', skipOffstage: false),
          findsAtLeast(1),
        );
      }
    });

    testWidgets('statuses: Connected survives Disconnected; reconnect folds', (
      WidgetTester tester,
    ) async {
      final eventSub = FakeEventSubService();
      final irc = FakeIrcService();
      await setupChannel(tester, eventSub: eventSub, irc: irc);

      irc.triggerConnect(joinChannel: 'testchannel');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(
        find.textContaining('Connected', skipOffstage: false),
        findsOneWidget,
      );

      irc.triggerDisconnect();
      await tester.pump();
      // "Connected" is NOT swallowed by "Disconnected": both stay separate.
      // (The input hint reads "Reconnecting..." while down, hence one
      // "Disconnected" system line and one "Reconnecting..." hint.)
      expect(
        find.textContaining('Connected', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('Disconnected', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('Reconnecting', skipOffstage: false),
        findsOneWidget,
      );

      irc.triggerConnect(joinChannel: 'testchannel');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      // The transient "Disconnected" is folded into "Reconnected"; the
      // boot "Connected" survives as its own line.
      expect(
        find.textContaining('Connected', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('Reconnected', skipOffstage: false),
        findsOneWidget,
      );
      expect(find.textContaining('Disconnected'), findsNothing);
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

    testWidgets('truncates non-thread messages when exceeding limit', (
      WidgetTester tester,
    ) async {
      const channel = 'testchannel';
      final history = List.generate(
        15,
        (i) => TwitchMessage(
          login: 'user$i',
          text: 'msg $i',
          messageId: 'm$i',
          timestamp: DateTime.now().subtract(Duration(minutes: 15 - i)),
          channel: channel,
        ),
      );
      final irc = FakeIrcService();
      await joinChannel(
        tester,
        channelName: channel,
        history: history,
        irc: irc,
        maxMessages: 10,
      );

      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('msg 14', skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('Truncation keeps threads together and drops them past the limit', (
      WidgetTester tester,
    ) async {
      {
        const channel = 'testchannel';
        final parent = TwitchMessage(
          login: 'alice',
          text: 'thread root',
          messageId: 'p1',
          timestamp: DateTime.now().subtract(const Duration(minutes: 12)),
          channel: channel,
        );
        final child = TwitchMessage(
          login: 'bob',
          text: 'thread reply',
          messageId: 'c1',
          replyToParentId: 'p1',
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
            messageId: 'f$i',
            timestamp: DateTime.now().subtract(Duration(minutes: 10 - i)),
            channel: channel,
          ),
        );
        final irc = FakeIrcService();
        await joinChannel(
          tester,
          channelName: channel,
          history: [parent, child, ...filler],
          irc: irc,
          maxMessages: 10,
        );

        await tester.pump();
        await tester.pump();

        // Expand viewport so lazy ListView builds all items without scrolling
        // (avoids triggering the frozen-snapshot behavior in scroll notifications).
        await tester.binding.setSurfaceSize(const Size(2000, 2000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpAndSettle();

        final taken = tester.takeException();
        if (taken != null) debugPrint('TAKEN EXCEPTION: $taken');

        expect(
          find.textContaining('thread root', skipOffstage: false),
          findsWidgets,
        );
        expect(
          find.textContaining('thread reply', skipOffstage: false),
          findsOneWidget,
        );
      }
      {
        const channel = 'testchannel';
        final parent = TwitchMessage(
          login: 'alice',
          text: 'thread root',
          messageId: 'p2',
          timestamp: DateTime.now().subtract(const Duration(minutes: 14)),
          channel: channel,
        );
        final child = TwitchMessage(
          login: 'bob',
          text: 'thread reply',
          messageId: 'c2',
          replyToParentId: 'p2',
          replyToUser: 'alice',
          replyToText: 'thread root',
          timestamp: DateTime.now().subtract(const Duration(minutes: 13)),
          isHistory: true,
          channel: channel,
        );
        final filler = List.generate(
          13,
          (i) => TwitchMessage(
            login: 'user$i',
            text: 'filler $i',
            messageId: 'g$i',
            timestamp: DateTime.now().subtract(Duration(minutes: 12 - i)),
            channel: channel,
          ),
        );
        final irc = FakeIrcService();
        await joinChannel(
          tester,
          channelName: channel,
          history: [parent, child, ...filler],
          irc: irc,
          maxMessages: 10,
        );

        await tester.pump();
        await tester.pump();

        expect(find.textContaining('thread root'), findsNothing);
        expect(find.textContaining('thread reply'), findsNothing);
      }
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

        // Emit new messages that push the thread past the limit.
        for (int i = 1; i <= 3; i++) {
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

        // Truncation is coalesced (250ms window), so the full pass is
        // deferred: advance the clock and emit one more message so the
        // thread-aware pass runs and drops the thread.
        await tester.pump(const Duration(milliseconds: 300));
        ircRead.emitMessage(
          TwitchMessage(
            login: 'newuser',
            text: 'new message 4',
            messageId: 'new4',
            timestamp: DateTime.now(),
            channel: channel,
          ),
        );
        await tester.pump();
        await tester.pump();

        // Thread should now be removed - pushed past maxMessages=10.
        expect(find.textContaining('thread root'), findsNothing);
        expect(find.textContaining('thread reply'), findsNothing);
      }
    });
  });

  group('Chat pause', () {
    testWidgets(
      'scroll-to-bottom FAB appears when scrolled up and hides on tap',
      (WidgetTester tester) async {
        final now = DateTime.now();
        final manyMessages = List.generate(
          50,
          (i) => TwitchMessage(
            login: 'user$i',
            text: 'message number $i with some extra text to fill the line',
            channel: 'testchannel',
            messageId: 'msg-$i',
            timestamp: now.subtract(Duration(minutes: 50 - i)),
          ),
        );
        final fakeEventSub = FakeEventSubService();
        final fakeIrc = FakeIrcService();
        final fakeRecent = ConfigurableRecentMessagesService(manyMessages);

        await tester.pumpWidget(
          TwitchChatApp(
            key: UniqueKey(),
            eventSubService: fakeEventSub,
            ircService: fakeIrc,
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

        // Initially at bottom - FAB should not be visible
        expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);

        // Scroll up to trigger pause (with reverse:true, drag DOWN = scroll UP)
        await tester.drag(
          find.byType(FlutterListView).first,
          const Offset(0, 500),
        );
        await tester.pump();
        await tester.pump();

        // FAB should now be visible
        expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

        // Tap FAB to scroll back to bottom
        await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
        await tester.pump();
        await tester.pump();

        // FAB should be gone
        expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);

        // Let the DoubleTapGestureRecognizer timer from the drag expire.
        await tester.pump(const Duration(milliseconds: 50));
      },
    );

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
        await tester.drag(
          find.byType(FlutterListView).first,
          const Offset(0, 500),
        );
        await tester.pump();
        await tester.pump();
        expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

        final position = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        final offsetBeforeArrival = position.pixels;

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

        // Reading position held steady by keepPosition
        expect(
          position.pixels,
          moreOrLessEquals(offsetBeforeArrival, epsilon: 2),
        );

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
        // The row tint is painted as the tile Material's color (so ink ripples
        // stay visible above it) rather than a ColoredBox over the content.
        final rows = find
            .ancestor(
              of: find.textContaining(
                'Test announcement text',
                skipOffstage: false,
              ),
              matching: find.byType(Material, skipOffstage: false),
            )
            .evaluate()
            .where((el) => (el.widget as Material).color == blended);
        expect(
          rows,
          isNotEmpty,
          reason: 'announcement should sit on a full-row accent background',
        );
      }
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

        // DankChat-style: the child message plus the "Announcement" label.
        expect(
          find.textContaining('Announcement', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.textContaining('ermugo2: uuh', skipOffstage: false),
          findsOneWidget,
        );
      }
    });
  });

  group('Autocomplete', () {
    testWidgets('shows dropdown with user suggestion after typing', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      // Resolved identity: typing needs an enabled composer, which now
      // requires the session user (not just a token).
      FlutterSecureStorage.setMockInitialValues({
        'accounts':
            '[{"login":"me","user_id":"42","access_token":"test_token"}]',
        'active_login': 'me',
      });
      final eventSub = FakeEventSubService();
      final irc = FakeIrcService();
      final ircRead = FakeIrcReadService();
      final recent = FakeRecentMessagesService();

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

      expect(
        find.textContaining('UserOne', skipOffstage: false),
        findsOneWidget,
      );

      irc.triggerConnect(joinChannel: 'xqc');
      ircRead.triggerConnect(joinChannel: 'xqc');
      await tester.pump();
      await tester.enterText(find.byKey(const Key('message_input')), 'Us');
      await tester.pump();

      final dropdown = find.byKey(const Key('autocomplete_dropdown'));
      expect(dropdown, findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('autocomplete_dropdown')),
          matching: find.text('UserOne', skipOffstage: false),
        ),
        findsOneWidget,
      );
    });

    testWidgets('autocomplete inserts the picked user', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      // Resolved identity: typing needs an enabled composer, which now
      // requires the session user (not just a token).
      FlutterSecureStorage.setMockInitialValues({
        'accounts':
            '[{"login":"me","user_id":"42","access_token":"test_token"}]',
        'active_login': 'me',
      });
      final eventSub = FakeEventSubService();
      final irc = FakeIrcService();
      final ircRead = FakeIrcReadService();
      final recent = FakeRecentMessagesService();

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

      // Join channel.
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'xqc');
      await tester.tap(find.text('Join', skipOffstage: false));
      await tester.pump();

      // Populate user store so UserOne appears as a suggestion.
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

      // Type @Us to trigger autocomplete for user UserOne.
      final inputFinder = find.byKey(const Key('message_input'));
      await tester.enterText(inputFinder, '@Us');
      await tester.pump();

      // Directly invoke autocomplete callback (bypasses hit-test issues).
      final autocomplete = tester.widget<AutocompleteDropdown>(
        find.byType(AutocompleteDropdown),
      );
      autocomplete.onSelect(UserSuggestion(displayName: 'UserOne'));
      await tester.pump();

      // After autocomplete the text should be @UserOne followed by a space.
      final controller = tester.widget<TextField>(inputFinder).controller!;
      expect(controller.text, startsWith('@UserOne'));

      // Ensure the text ends with a trailing space.
      expect(controller.text, endsWith(' '));
    });

    testWidgets('dropdown hides when text fewer than 2 characters', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      // Resolved identity: typing needs an enabled composer, which now
      // requires the session user (not just a token).
      FlutterSecureStorage.setMockInitialValues({
        'accounts':
            '[{"login":"me","user_id":"42","access_token":"test_token"}]',
        'active_login': 'me',
      });
      final eventSub = FakeEventSubService();
      final irc = FakeIrcService();
      final ircRead = FakeIrcReadService();
      final recent = FakeRecentMessagesService();

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

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'xqc');
      await tester.tap(find.text('Join', skipOffstage: false));
      await tester.pump();

      irc.triggerConnect(joinChannel: 'xqc');
      ircRead.triggerConnect(joinChannel: 'xqc');
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

      await tester.enterText(find.byKey(const Key('message_input')), 'U');
      await tester.pump();

      final dropdown = find.byKey(const Key('autocomplete_dropdown'));
      expect(dropdown, findsNothing);
    });
    testWidgets('typing slash shows all commands regardless of permission', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      // Resolved identity: typing needs an enabled composer, which now
      // requires the session user (not just a token).
      FlutterSecureStorage.setMockInitialValues({
        'accounts':
            '[{"login":"me","user_id":"42","access_token":"test_token"}]',
        'active_login': 'me',
      });
      final eventSub = FakeEventSubService();
      final irc = FakeIrcService();
      final ircRead = FakeIrcReadService();
      final recent = FakeRecentMessagesService();

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

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'xqc');
      await tester.tap(find.text('Join', skipOffstage: false));
      await tester.pump();

      irc.triggerConnect(joinChannel: 'xqc');
      ircRead.triggerConnect(joinChannel: 'xqc');
      await tester.pump();

      await tester.enterText(find.byKey(const Key('message_input')), '/');
      await tester.pump();

      final dropdown = find.byKey(const Key('autocomplete_dropdown'));
      expect(dropdown, findsOneWidget);
      expect(
        find.descendant(of: dropdown, matching: find.text('/me')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dropdown, matching: find.text('/color')),
        findsOneWidget,
      );
      // Mod-only commands are suggested to everyone too; the API rejects
      // them with a clean error notice if the account cannot run them.
      expect(
        find.descendant(of: dropdown, matching: find.text('/ban')),
        findsOneWidget,
      );
    });

    testWidgets('selecting a command inserts it with a trailing space', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
      final eventSub = FakeEventSubService();
      final irc = FakeIrcService();
      final recent = FakeRecentMessagesService();

      await tester.pumpWidget(
        TwitchChatApp(
          key: UniqueKey(),
          eventSubService: eventSub,
          ircService: irc,
          recentMessagesService: recent,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'xqc');
      await tester.tap(find.text('Join', skipOffstage: false));
      await tester.pump();

      final inputFinder = find.byKey(const Key('message_input'));
      await tester.enterText(inputFinder, '/');
      await tester.pump();

      // Directly invoke autocomplete callback (bypasses hit-test issues).
      final autocomplete = tester.widget<AutocompleteDropdown>(
        find.byType(AutocompleteDropdown),
      );
      autocomplete.onSelect(const CommandSuggestion(command: '/me'));
      await tester.pump();

      final controller = tester.widget<TextField>(inputFinder).controller!;
      expect(controller.text, '/me ');
    });
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

  group('Channel bar', () {
    testWidgets(
      'Channel bar hides with no channels and returns after removal',
      (WidgetTester tester) async {
        {
          await tester.pumpWidget(TwitchChatApp(key: UniqueKey()));
          await tester.pump();

          expect(find.byType(TabBar), findsNothing);
          // Let the anonymous-mode socket attempts resolve so no timer pends.
          await tester.pumpAndSettle();
        }
        {
          await tester.pumpWidget(TwitchChatApp(key: UniqueKey()));
          await tester.pump();

          await joinChannel(tester, 'xqc');

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
        }
      },
    );

    testWidgets(
      'Joining channels selects the newest channel without landing on its neighbor',
      (WidgetTester tester) async {
        {
          await tester.pumpWidget(TwitchChatApp(key: UniqueKey()));
          await tester.pump();

          await joinChannel(tester, 'xqc');

          expect(find.text('xqc', skipOffstage: false), findsOneWidget);
        }
        {
          SharedPreferences.setMockInitialValues({});
          FlutterSecureStorage.setMockInitialValues({});
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

          final bar1 = tester.widget<TabBar>(find.byType(TabBar).first);
          expect(bar1.controller!.length, 3);
          // The new channel (gamma) is appended last and must be selected;
          // a regression lands on its neighbor (beta, index 1) instead.
          expect(bar1.controller!.index, 2);
          expect(find.text('gamma', skipOffstage: false), findsOneWidget);
        }
      },
    );

    testWidgets('Channel focus follows swipe thresholds with hysteresis', (
      WidgetTester tester,
    ) async {
      {
        await tester.pumpWidget(TwitchChatApp(key: UniqueKey()));
        await tester.pump();

        await joinChannel(tester, 'a');
        await joinChannel(tester, 'b');

        expect(
          tester
              .widget<Text>(find.text('b', skipOffstage: false))
              .style
              ?.fontWeight,
          FontWeight.w600,
        );
        expect(
          tester
              .widget<Text>(find.text('a', skipOffstage: false))
              .style
              ?.fontWeight,
          FontWeight.normal,
        );
      }
      {
        await tester.pumpWidget(TwitchChatApp(key: UniqueKey()));
        await tester.pump();
        await joinChannel(tester, 'a');
        await joinChannel(tester, 'b');
        await tapChannel(tester, 'a');

        final size = tester.getSize(find.byType(PageView));
        final center = tester.getCenter(find.byType(PageView));
        final gesture = await tester.startGesture(center);
        await gesture.moveBy(const Offset(-1, 0));
        await tester.pump();
        await gesture.moveBy(Offset(-size.width * 0.55, 0));
        await tester.pump();
        // Don't release - verify focus switched mid-drag
        expect(
          tester
              .widget<Text>(
                find.descendant(
                  of: find.byType(TabBar),
                  matching: find.text('b', skipOffstage: false),
                ),
              )
              .style
              ?.fontWeight,
          FontWeight.w600,
        );
        expect(
          tester
              .widget<Text>(
                find.descendant(
                  of: find.byType(TabBar),
                  matching: find.text('a', skipOffstage: false),
                ),
              )
              .style
              ?.fontWeight,
          FontWeight.normal,
        );

        await gesture.up();
        await tester.pumpAndSettle();
      }
      {
        await tester.pumpWidget(TwitchChatApp(key: UniqueKey()));
        await tester.pump();
        await joinChannel(tester, 'a');
        await joinChannel(tester, 'b');
        await tapChannel(tester, 'a');

        final size = tester.getSize(find.byType(PageView));
        final center = tester.getCenter(find.byType(PageView));
        final gesture = await tester.startGesture(center);
        await gesture.moveBy(const Offset(-1, 0));
        await tester.pump();
        await gesture.moveBy(Offset(-size.width * 0.45, 0)); // under 50%
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<Text>(
                find.descendant(
                  of: find.byType(TabBar),
                  matching: find.text('a', skipOffstage: false),
                ),
              )
              .style
              ?.fontWeight,
          FontWeight.w600,
        );
        expect(
          tester
              .widget<Text>(
                find.descendant(
                  of: find.byType(TabBar),
                  matching: find.text('b', skipOffstage: false),
                ),
              )
              .style
              ?.fontWeight,
          FontWeight.normal,
        );
      }
      {
        await tester.pumpWidget(TwitchChatApp(key: UniqueKey()));
        await tester.pump();
        await joinChannel(tester, 'a');
        await joinChannel(tester, 'b');
        await tapChannel(tester, 'a');

        final size = tester.getSize(find.byType(PageView));
        final center = tester.getCenter(find.byType(PageView));
        final gesture = await tester.startGesture(center);
        await gesture.moveBy(const Offset(-1, 0));
        await tester.pump();
        // Cross 50%
        await gesture.moveBy(Offset(-size.width * 0.6, 0));
        await tester.pump();
        // Return below 50%
        await gesture.moveBy(Offset(size.width * 0.3, 0));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<Text>(
                find.descendant(
                  of: find.byType(TabBar),
                  matching: find.text('a', skipOffstage: false),
                ),
              )
              .style
              ?.fontWeight,
          FontWeight.w600,
        );
      }
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
      {
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

        // Insert between Alpha and Charlie: Alpha stays in place (identical
        // element), Delta shifts down but keeps its element via keyed
        // reconciliation, and only the new cell is built.
        manager.updateSevenTvEmotes('ch', added: [sevenTv('b', 'Bravo')]);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          tester.element(find.byKey(const ValueKey('a'))),
          same(alphaElement),
        );
        expect(
          tester.element(find.byKey(const ValueKey('d'))),
          same(deltaElement),
        );
        expect(find.byKey(const ValueKey('b')), findsOneWidget);
      }
      {
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          usageFlushDelay: Duration.zero,
          removeCachedFile: (url) async {},
        );
        manager.updateSevenTvEmotes(
          'ch',
          added: [
            sevenTv('a', 'Alpha'),
            sevenTv('b', 'Bravo'),
            sevenTv('d', 'Delta'),
          ],
        );

        await tester.pumpWidget(wrapEmoteMenu(manager));
        await tester.tap(find.text('Channel', skipOffstage: false));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        final alphaElement = tester.element(find.byKey(const ValueKey('a')));
        final deltaElement = tester.element(find.byKey(const ValueKey('d')));

        manager.updateSevenTvEmotes('ch', removedIds: ['b']);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          tester.element(find.byKey(const ValueKey('a'))),
          same(alphaElement),
        );
        expect(
          tester.element(find.byKey(const ValueKey('d'))),
          same(deltaElement),
        );
        expect(find.byKey(const ValueKey('b')), findsNothing);
      }
    },
  );

  // Regression: the chat list must hug the bottom edge when its content is
  // shorter than the viewport. Plain reverse:true provides this naturally;
  // FirstItemAlign.end actively BREAKS it (pins content to the top), so this
  // test guards against reintroducing it.
  testWidgets('short chat list hugs the bottom edge', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        home: Scaffold(
          body: FlutterListView(
            reverse: true,
            delegate: FlutterListViewDelegate(
              (_, i) => SizedBox(height: 50, child: Text('row $i')),
              childCount: 3,
              keepPosition: true,
              keepPositionOffset: 120,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    Finder row(String s) => find.byWidgetPredicate(
      (w) => w is Text && w.data == s,
      skipOffstage: false,
    );
    // Newest row (index 0) sits flush against the bottom edge.
    expect(tester.getRect(row('row 0')).bottom, closeTo(600.0, 1.0));
    // Oldest row starts near the top, not pinned to the very top edge.
    expect(tester.getRect(row('row 2')).top, lessThan(460.0));
  });

  group('Chat notices and snackbars', () {
    testWidgets('notice floats above the composer without resizing the chat', (
      tester,
    ) async {
      final controller = ChatNoticeController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(noticeHarness(controller));
      final chatSize = tester.getSize(find.byKey(const Key('notice-chat')));
      controller.show('hello');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('hello'), findsOneWidget);
      final barBottom = tester.getBottomLeft(find.text('hello')).dy;
      final composerTop = tester
          .getTopLeft(find.byKey(const Key('notice-composer')))
          .dy;
      // Bar padding ends 8dp above the composer, so text sits higher still.
      expect(composerTop - barBottom, greaterThanOrEqualTo(8));
      // Overlay: the chat keeps its size instead of shrinking.
      expect(tester.getSize(find.byKey(const Key('notice-chat'))), chatSize);
      controller.dismiss();
      await tester.pump();
    });

    testWidgets('notice action runs the callback and dismisses', (
      tester,
    ) async {
      final controller = ChatNoticeController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(noticeHarness(controller));
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
    });

    testWidgets('notice horizontal swipe dismisses', (tester) async {
      final controller = ChatNoticeController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(noticeHarness(controller));
      controller.show('hello');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.fling(find.text('hello'), const Offset(400, 0), 800);
      await tester.pumpAndSettle();
      expect(find.text('hello'), findsNothing);
    });

    testWidgets('notice auto-dismisses on screen', (tester) async {
      final controller = ChatNoticeController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(noticeHarness(controller));
      controller.show('hello', duration: const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('hello'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.text('hello'), findsNothing);
    });

    testWidgets('overlay snackbar uses the shared style', (tester) async {
      await tester.pumpWidget(snackHarness());
      await tester.tap(find.text('show snack'));
      await tester.pump();
      expect(find.text('from button'), findsOneWidget);
      final bar = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(bar.behavior, SnackBarBehavior.floating);
      expect(bar.dismissDirection, DismissDirection.horizontal);
      expect(bar.duration, AppSnack.defaultDuration);
    });

    testWidgets('overlay snackbar replaces instead of queueing', (
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
    });

    testWidgets('page push pops the overlay snackbar', (tester) async {
      await tester.pumpWidget(snackHarness());
      final context = tester.element(find.text('show snack'));
      AppSnack.show(context, 'lingering');
      await tester.pump();
      expect(find.text('lingering'), findsOneWidget);
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('next'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('lingering'), findsNothing);
    });

    testWidgets('page pop pops the overlay snackbar', (tester) async {
      await tester.pumpWidget(snackHarness());
      final context = tester.element(find.text('show snack'));
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('next'))),
      );
      await tester.pumpAndSettle();
      final next = tester.element(find.text('next'));
      AppSnack.show(next, 'on next');
      await tester.pump();
      expect(find.text('on next'), findsOneWidget);
      Navigator.of(next).pop();
      await tester.pumpAndSettle();
      expect(find.text('on next'), findsNothing);
    });

    testWidgets('dialog push leaves the overlay snackbar alone', (
      tester,
    ) async {
      await tester.pumpWidget(snackHarness());
      final context = tester.element(find.text('show snack'));
      AppSnack.show(context, 'behind dialog');
      await tester.pump();
      showDialog(
        context: context,
        builder: (_) => const AlertDialog(content: Text('dialog')),
      );
      await tester.pumpAndSettle();
      expect(find.text('dialog'), findsOneWidget);
      expect(find.text('behind dialog'), findsOneWidget);
    });

    group('ChatNoticeController', () {
      test('notice show replaces the current notice', () {
        final controller = ChatNoticeController();
        controller.show('first');
        controller.show('second');
        expect(controller.current?.message, 'second');
        controller.dispose();
      });

      test('notice dismiss clears the current notice', () {
        final controller = ChatNoticeController();
        controller.show('hello');
        controller.dismiss();
        expect(controller.current, isNull);
        controller.dispose();
      });

      test('notice auto-dismisses after the duration', () async {
        final controller = ChatNoticeController();
        controller.show('hello', duration: const Duration(milliseconds: 50));
        expect(controller.current, isNotNull);
        await Future.delayed(const Duration(milliseconds: 120));
        expect(controller.current, isNull);
        controller.dispose();
      });

      test('notice replace resets the auto-dismiss timer', () async {
        final controller = ChatNoticeController();
        controller.show('first', duration: const Duration(milliseconds: 60));
        await Future.delayed(const Duration(milliseconds: 40));
        controller.show('second', duration: const Duration(milliseconds: 200));
        await Future.delayed(const Duration(milliseconds: 60));
        expect(controller.current?.message, 'second');
        controller.dispose();
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

    testWidgets('shows Mod view only when gated on', (tester) async {
      var opened = false;
      await tester.pumpWidget(
        chromeMenuHarness(showMod: true, onMod: () => opened = true),
      );
      await openChromeMenu(tester);
      await tester.tap(find.text('Mod view'));
      await tester.pumpAndSettle();
      expect(opened, isTrue);

      await tester.pumpWidget(chromeMenuHarness(showMod: false));
      await openChromeMenu(tester);
      expect(find.text('Mod view'), findsNothing);
    });

    testWidgets('Search is always shown and fires', (tester) async {
      var toggled = false;
      await tester.pumpWidget(
        chromeMenuHarness(onSearch: () => toggled = true),
      );
      await openChromeMenu(tester);
      expect(find.text('Search'), findsOneWidget);
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      expect(toggled, isTrue);
    });
  });

  group('PiP body collapse', () {
    testWidgets('video-only tree hides composer and panels', (tester) async {
      await tester.pumpWidget(pipCollapseHarness(isInPip: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pip-video')), findsOneWidget);
      expect(find.byKey(const Key('pip-composer')), findsNothing);
      expect(find.byKey(const Key('pip-thread')), findsNothing);
    });

    testWidgets('normal tree keeps composer and panels', (tester) async {
      await tester.pumpWidget(pipCollapseHarness(isInPip: false));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pip-video')), findsOneWidget);
      expect(find.byKey(const Key('pip-composer')), findsOneWidget);
      expect(find.byKey(const Key('pip-thread')), findsOneWidget);
    });
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
