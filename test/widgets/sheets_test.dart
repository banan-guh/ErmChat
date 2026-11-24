import 'package:http/http.dart' as http;

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

  group('emote sheet', () {
    testWidgets('emote sheet keeps full-box canvas with keyboard open', (
      WidgetTester tester,
    ) async {
      // The Scaffold strips viewInsets from its body subtree, so ChatBody
      // reads the true keyboard height from the view.
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.8125;
      tester.view.viewInsets = FakeViewPadding(bottom: 0);
      addTearDown(tester.view.reset);

      double? seenH;
      double? seenKbH;
      final ctrl = DraggableScrollableController();
      Widget body() {
        return MaterialApp(
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
                    seenKbH = keyboardH;
                    return const SizedBox.expand();
                  },
              threadPanel: const SizedBox.shrink(),
              mentionsPanel: const SizedBox.shrink(),
              modViewPanel: const SizedBox.shrink(),
              emotePickerBuilder:
                  (context, {required sheetBoxHeight, required inset}) {
                    seenH = sheetBoxHeight;
                    return Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      height: sheetBoxHeight,
                      child: DraggableScrollableSheet(
                        controller: ctrl,
                        initialChildSize: 0,
                        minChildSize: 0,
                        maxChildSize: 0.6,
                        snap: true,
                        builder: (context, scrollController) => ListView(
                          key: const Key('sheet'),
                          controller: scrollController,
                          children: const [SizedBox(height: 2000)],
                        ),
                      ),
                    );
                  },
              autocomplete: const SizedBox.shrink(),
              emoteMaxFraction: 0.6,
              composer: const SizedBox(height: 56),
            ),
          ),
        );
      }

      await tester.pumpWidget(body());
      await tester.pumpAndSettle();
      expect(seenKbH, 0);
      final closedH = seenH;

      tester.view.viewInsets = FakeViewPadding(bottom: 298 * 2.8125);
      await tester.pumpWidget(body());
      await tester.pumpAndSettle();
      expect(seenKbH, 298);
      expect(seenH, closedH, reason: 'the keyboard keeps the sheet canvas');

      ctrl.jumpTo(0.6);
      await tester.pumpAndSettle();

      final sheetSize = tester.getSize(find.byKey(const Key('sheet')));
      final sheetBottomDy = tester
          .getBottomLeft(find.byKey(const Key('sheet')))
          .dy;
      final stackBox =
          tester
                  .element(find.byWidgetPredicate((w) => w is Stack).first)
                  .renderObject!
              as RenderBox;
      final stackBottom = stackBox.localToGlobal(
        Offset(0, stackBox.size.height),
      );
      expect(sheetSize.height, moreOrLessEquals(closedH! * 0.6, epsilon: 1.0));
      expect(sheetBottomDy, moreOrLessEquals(stackBottom.dy, epsilon: 1.0));
    });
  });

  group('user profile sheet', () {
    TwitchApi createApi() {
      return TwitchApi(
        client: MockClient(
          (_) async => http.Response(
            '{"data": [{"id": "123", "login": "testuser", "display_name": "TestUser", "created_at": "2020-01-01T00:00:00Z", "profile_image_url": "https://example.com/img.png"}]}',
            200,
          ),
        ),
      );
    }

    Widget wrapUserProfileWithHistory(
      TwitchApi api,
      List<TwitchMessage> messages,
    ) {
      return MaterialApp(
        key: UniqueKey(),
        home: Scaffold(
          body: UserProfileSheet(
            username: 'testuser',
            userId: '123',
            displayName: 'TestUser',
            twitchApi: api,
            twitchAuth: TwitchAuth()..accessToken = 'test-token',
            messageController: TextEditingController(),
            focusNode: FocusNode(),
            onClose: () {},
            userMessages: messages,
            messageRowBuilder: (context, msg) => Text('row:${msg.text}'),
          ),
        ),
      );
    }

    // The jump arrow is always in the tree (faded via AnimatedOpacity), so
    // visibility is asserted on opacity, not presence.
    double arrowOpacity(WidgetTester tester) {
      final fade = find.ancestor(
        of: find.byIcon(Icons.keyboard_arrow_down),
        matching: find.byType(AnimatedOpacity),
      );
      return tester.widget<AnimatedOpacity>(fade).opacity;
    }

    testWidgets('User profile never overflows a short screen', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        wrapUserProfileWithHistory(createApi(), [
          for (var i = 0; i < 30; i++)
            TwitchMessage(
              login: 'testuser',
              text: 'm$i',
              channel: 'somechannel',
            ),
        ]),
      );
      await tester.pumpAndSettle();

      // Clipped, never striped: identity and latest stay visible.
      expect(tester.takeException(), isNull);
      expect(find.text('TestUser'), findsOneWidget);
      expect(find.text('row:m29'), findsOneWidget);
    });

    testWidgets('User profile sheet keeps detents, arrow jumps to latest', (
      WidgetTester tester,
    ) async {
      // Test env has no status bar, so max extent is the full height.
      const maxExtent = 1.0;
      // Default test viewport height; the settle math divides by it.
      const screenH = 600.0;
      var sheetController = DraggableScrollableController();
      // Mirrors production: detents track the measured card size.
      var cardExtent = 0.4;
      Future<void> openSheet() async {
        sheetController = DraggableScrollableController();
        cardExtent = 0.4;
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  return TextButton(
                    onPressed: () {
                      showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        enableDrag: false,
                        builder: (ctx) {
                          // Mirrors production wiring (immediate eased settle).
                          var tracker = VelocityTracker.withKind(
                            PointerDeviceKind.touch,
                          );
                          var sizeAtDown = 0.4;
                          ScrollController? listController;
                          var listOffsetAtDown = 0.0;
                          var listMoved = false;
                          return Listener(
                            onPointerDown: (e) {
                              sizeAtDown = sheetController.isAttached
                                  ? sheetController.size
                                  : 0.4;
                              tracker = VelocityTracker.withKind(
                                PointerDeviceKind.touch,
                              );
                              tracker.addPosition(e.timeStamp, e.position);
                              listMoved = false;
                              if (listController?.hasClients ?? false) {
                                listOffsetAtDown = listController!.offset;
                              }
                            },
                            onPointerMove: (e) =>
                                tracker.addPosition(e.timeStamp, e.position),
                            onPointerUp: (_) {
                              if (!sheetController.isAttached) return;
                              if (listController?.hasClients ?? false) {
                                listMoved =
                                    (listController!.offset - listOffsetAtDown)
                                        .abs() >
                                    4;
                              }
                              final size = sheetController.size;
                              final sizeMoved =
                                  (size - sizeAtDown).abs() > 0.001;
                              final velocityDy = tracker
                                  .getVelocity()
                                  .pixelsPerSecond
                                  .dy;
                              final target = userSheetTargetDetent(
                                size,
                                minExtent: 0.25,
                                cardExtent: cardExtent,
                                maxExtent: maxExtent,
                                velocityDy: velocityDy,
                              );
                              final flingDown =
                                  velocityDy >= kUserSheetFlingVelocity;
                              if (target == 0.25) {
                                // Pure list gestures never dismiss; taps stay.
                                if (listMoved || (!sizeMoved && !flingDown)) {
                                  return;
                                }
                                sheetController.jumpTo(size);
                                if (ModalRoute.of(ctx)?.isCurrent ?? false) {
                                  Navigator.pop(ctx);
                                }
                                return;
                              }
                              if (!sizeMoved) return;
                              if ((target - size).abs() <= 0.02) return;
                              sheetController.animateTo(
                                target,
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeOutCubic,
                              );
                            },
                            child: DraggableScrollableSheet(
                              controller: sheetController,
                              initialChildSize: 0.4,
                              minChildSize: 0.25,
                              maxChildSize: maxExtent,
                              expand: false,
                              snap: false,
                              shouldCloseOnMinExtent: false,
                              builder: (_, scrollController) {
                                final historyController = ScrollController();
                                listController = historyController;
                                return UserProfileSheet(
                                  username: 'testuser',
                                  userId: '123',
                                  displayName: 'TestUser',
                                  twitchApi: createApi(),
                                  twitchAuth: TwitchAuth()
                                    ..accessToken = 'test-token',
                                  messageController: TextEditingController(),
                                  focusNode: FocusNode(),
                                  onClose: () => Navigator.pop(ctx),
                                  scrollController: historyController,
                                  anchor: scrollController,
                                  sheetController: sheetController,
                                  sheetMinExtent: 0.25,
                                  onCardMeasured: (naturalH) {
                                    // Test padding is zero, so availH is screenH.
                                    cardExtent = (naturalH / screenH)
                                        .clamp(0.25, maxExtent)
                                        .toDouble();
                                    if (!sheetController.isAttached) return;
                                    if ((sheetController.size - cardExtent)
                                            .abs() >
                                        0.02) {
                                      sheetController.animateTo(
                                        cardExtent,
                                        duration: const Duration(
                                          milliseconds: 250,
                                        ),
                                        curve: Curves.easeOutCubic,
                                      );
                                    }
                                  },
                                  userMessages: [
                                    // Oldest first, like production.
                                    for (var i = 0; i < 30; i++)
                                      TwitchMessage(
                                        login: 'testuser',
                                        text: 'm$i',
                                        channel: 'somechannel',
                                      ),
                                  ],
                                  messageRowBuilder: (context, msg) =>
                                      Text('row:${msg.text}'),
                                );
                              },
                            ),
                          );
                        },
                      ).whenComplete(sheetController.dispose);
                    },
                    child: const Text('open-card'),
                  );
                },
              ),
            ),
          ),
        );
        await tester.tap(find.text('open-card'));
        await tester.pumpAndSettle();
      }

      // Opens settled onto the measured card: full card plus history peek,
      // latest message visible, jump arrow hidden.
      // Opens parked exactly on the card: full card, history hidden below
      // the fold like a garage door (zero-height region), jump arrow hidden.
      await openSheet();
      final settled = sheetController.size;
      expect(settled, greaterThan(0.25));
      expect(find.text('TestUser'), findsOneWidget);
      expect(find.text('Report'), findsOneWidget);
      final history = find.byType(ListView);
      expect(
        history.evaluate().isEmpty || tester.getSize(history).height < 1,
        isTrue,
        reason: 'history stays below the fold (unbuilt or zero-height)',
      );
      expect(find.text('row:m0'), findsNothing);
      expect(arrowOpacity(tester), 0);

      // Card drags resize the sheet and settle back onto the card.
      // Two moves: the first clears touch slop, the second drags.
      final cardDrag = await tester.startGesture(const Offset(400, 500));
      await cardDrag.moveBy(const Offset(0, -20));
      await tester.pump();
      await cardDrag.moveBy(const Offset(0, -50));
      await tester.pump();
      expect(sheetController.size, greaterThan(settled + 0.05));
      await cardDrag.up();
      await tester.pumpAndSettle();
      expect(sheetController.size, closeTo(settled, 0.03));

      // Upward fling grows to full height, revealing the history pinned to
      // the latest message.
      await tester.flingFrom(
        const Offset(400, 450),
        const Offset(0, -300),
        1500,
      );
      await tester.pumpAndSettle();
      expect(sheetController.size, maxExtent);
      expect(find.text('row:m29'), findsOneWidget);
      expect(arrowOpacity(tester), 0);

      // Scrolling down toward older messages reveals the jump arrow, and
      // tapping it jumps back to the latest without moving the sheet.
      await tester.dragFrom(const Offset(400, 500), const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(sheetController.size, maxExtent);
      expect(arrowOpacity(tester), 1);
      // Down at the card the history is gone, and its arrow with it; back
      // up, the arrow returns since the list is still scrolled.
      sheetController.jumpTo(settled);
      await tester.pumpAndSettle();
      expect(arrowOpacity(tester), 0, reason: 'arrow left over the card');
      sheetController.jumpTo(maxExtent);
      await tester.pumpAndSettle();
      expect(arrowOpacity(tester), 1);
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pumpAndSettle();
      expect(find.text('row:m29'), findsOneWidget);
      expect(sheetController.size, maxExtent);
      expect(arrowOpacity(tester), 0);

      // Slow downward drag on the card eases back to the measured card.
      await tester.dragFrom(const Offset(400, 100), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(sheetController.size, closeTo(settled, 0.03));

      // Same sheet, second expand: the history must stay bottom-anchored,
      // so the garage-door reveal repeats instead of moving with the panel.
      await tester.flingFrom(
        const Offset(400, 450),
        const Offset(0, -300),
        1500,
      );
      await tester.pumpAndSettle();
      expect(sheetController.size, maxExtent);
      expect(find.text('row:m29'), findsOneWidget);
      expect(arrowOpacity(tester), 0);

      // Stepping the sheet back down must not drag the latest row with
      // it: the row stays glued to the viewport bottom as the card lifts.
      final yFull = tester.getTopLeft(find.text('row:m29')).dy;
      sheetController.jumpTo((settled + maxExtent) / 2);
      // Two frames: the resize lays out, then the post-frame pin lands.
      await tester.pump();
      await tester.pump();
      expect(find.text('row:m29'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('row:m29')).dy,
        moreOrLessEquals(yFull, epsilon: 1.0),
      );
      expect(arrowOpacity(tester), 0);

      // Pushing up past the latest row scrolls the list only; it must not
      // resize the sheet (the list is decoupled from the sheet).
      sheetController.jumpTo(maxExtent);
      await tester.pumpAndSettle();
      final bottomDrag = await tester.startGesture(
        tester.getCenter(find.text('row:m29')),
      );
      await bottomDrag.moveBy(const Offset(0, -20));
      await tester.pump();
      await bottomDrag.moveBy(const Offset(0, -60));
      await tester.pump();
      expect(sheetController.size, maxExtent);
      await bottomDrag.up();
      await tester.pumpAndSettle();
      expect(sheetController.size, maxExtent);
      expect(find.text('row:m29'), findsOneWidget);
      expect(arrowOpacity(tester), 0);

      // Overscrolling at the oldest end must not resize the sheet either.
      await tester.drag(find.byType(ListView), const Offset(0, 2000));
      await tester.pumpAndSettle();
      expect(find.text('row:m0'), findsOneWidget);
      final topDrag = await tester.startGesture(
        tester.getCenter(find.text('row:m0')),
      );
      await topDrag.moveBy(const Offset(0, 20));
      await tester.pump();
      await topDrag.moveBy(const Offset(0, 60));
      await tester.pump();
      expect(sheetController.size, maxExtent);
      await topDrag.up();
      await tester.pumpAndSettle();
      expect(sheetController.size, maxExtent);

      // Fresh card, upward fling eases directly to full height.
      await openSheet();
      await tester.flingFrom(
        const Offset(400, 450),
        const Offset(0, -300),
        1500,
      );
      await tester.pumpAndSettle();
      expect(sheetController.size, maxExtent);

      // Fresh card, dragging the card past the minimum dismisses in one
      // gesture, no mid stop.
      await openSheet();
      await tester.dragFrom(const Offset(400, 500), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(find.text('row:m0'), findsNothing);
    });

    testWidgets('User profile dismisses from min on fast card fling', (
      WidgetTester tester,
    ) async {
      const maxExtent = 1.0;
      const screenH = 600.0;
      var sheetController = DraggableScrollableController();
      var cardExtent = 0.4;
      Future<void> openSheet() async {
        sheetController = DraggableScrollableController();
        cardExtent = 0.4;
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  return TextButton(
                    onPressed: () {
                      showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        enableDrag: false,
                        builder: (ctx) {
                          var tracker = VelocityTracker.withKind(
                            PointerDeviceKind.touch,
                          );
                          var sizeAtDown = 0.4;
                          ScrollController? listController;
                          var listOffsetAtDown = 0.0;
                          var listMoved = false;
                          return Listener(
                            onPointerDown: (e) {
                              sizeAtDown = sheetController.isAttached
                                  ? sheetController.size
                                  : 0.4;
                              tracker = VelocityTracker.withKind(
                                PointerDeviceKind.touch,
                              );
                              tracker.addPosition(e.timeStamp, e.position);
                              listMoved = false;
                              if (listController?.hasClients ?? false) {
                                listOffsetAtDown = listController!.offset;
                              }
                            },
                            onPointerMove: (e) =>
                                tracker.addPosition(e.timeStamp, e.position),
                            onPointerUp: (_) {
                              if (!sheetController.isAttached) return;
                              if (listController?.hasClients ?? false) {
                                listMoved =
                                    (listController!.offset - listOffsetAtDown)
                                        .abs() >
                                    4;
                              }
                              final size = sheetController.size;
                              final sizeMoved =
                                  (size - sizeAtDown).abs() > 0.001;
                              final velocityDy = tracker
                                  .getVelocity()
                                  .pixelsPerSecond
                                  .dy;
                              final target = userSheetTargetDetent(
                                size,
                                minExtent: 0.25,
                                cardExtent: cardExtent,
                                maxExtent: maxExtent,
                                velocityDy: velocityDy,
                              );
                              final flingDown =
                                  velocityDy >= kUserSheetFlingVelocity;
                              if (target == 0.25) {
                                // Pure list gestures never dismiss; taps stay.
                                if (listMoved || (!sizeMoved && !flingDown)) {
                                  return;
                                }
                                sheetController.jumpTo(size);
                                if (ModalRoute.of(ctx)?.isCurrent ?? false) {
                                  Navigator.pop(ctx);
                                }
                                return;
                              }
                              if (!sizeMoved) return;
                              if ((target - size).abs() <= 0.02) return;
                              sheetController.animateTo(
                                target,
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeOutCubic,
                              );
                            },
                            child: DraggableScrollableSheet(
                              controller: sheetController,
                              initialChildSize: 0.4,
                              minChildSize: 0.25,
                              maxChildSize: maxExtent,
                              expand: false,
                              snap: false,
                              shouldCloseOnMinExtent: false,
                              builder: (_, scrollController) {
                                final historyController = ScrollController();
                                listController = historyController;
                                return UserProfileSheet(
                                  username: 'testuser',
                                  userId: '123',
                                  displayName: 'TestUser',
                                  twitchApi: createApi(),
                                  twitchAuth: TwitchAuth()
                                    ..accessToken = 'test-token',
                                  messageController: TextEditingController(),
                                  focusNode: FocusNode(),
                                  onClose: () => Navigator.pop(ctx),
                                  scrollController: historyController,
                                  anchor: scrollController,
                                  sheetController: sheetController,
                                  sheetMinExtent: 0.25,
                                  onCardMeasured: (naturalH) {
                                    cardExtent = (naturalH / screenH)
                                        .clamp(0.25, maxExtent)
                                        .toDouble();
                                    if (!sheetController.isAttached) return;
                                    if ((sheetController.size - cardExtent)
                                            .abs() >
                                        0.02) {
                                      sheetController.animateTo(
                                        cardExtent,
                                        duration: const Duration(
                                          milliseconds: 250,
                                        ),
                                        curve: Curves.easeOutCubic,
                                      );
                                    }
                                  },
                                  userMessages: [
                                    for (var i = 0; i < 30; i++)
                                      TwitchMessage(
                                        login: 'testuser',
                                        text: 'm$i',
                                        channel: 'somechannel',
                                      ),
                                  ],
                                  messageRowBuilder: (context, msg) =>
                                      Text('row:${msg.text}'),
                                );
                              },
                            ),
                          );
                        },
                      ).whenComplete(sheetController.dispose);
                    },
                    child: const Text('open-card'),
                  );
                },
              ),
            ),
          ),
        );
        await tester.tap(find.text('open-card'));
        await tester.pumpAndSettle();
      }

      await openSheet();
      expect(find.text('Report'), findsOneWidget);
      sheetController.jumpTo(0.25);
      await tester.pump();
      // Fast downward fling on the card dismisses even though size sticks.
      await tester.flingFrom(
        const Offset(400, 460),
        const Offset(0, 200),
        1500,
      );
      await tester.pumpAndSettle();
      expect(find.text('TestUser'), findsNothing);
    });

    testWidgets('User profile keeps route on fast history fling', (
      WidgetTester tester,
    ) async {
      const maxExtent = 1.0;
      const screenH = 600.0;
      var sheetController = DraggableScrollableController();
      var cardExtent = 0.4;
      Future<void> openSheet() async {
        sheetController = DraggableScrollableController();
        cardExtent = 0.4;
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  return TextButton(
                    onPressed: () {
                      showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        enableDrag: false,
                        builder: (ctx) {
                          var tracker = VelocityTracker.withKind(
                            PointerDeviceKind.touch,
                          );
                          var sizeAtDown = 0.4;
                          ScrollController? listController;
                          var listOffsetAtDown = 0.0;
                          var listMoved = false;
                          return Listener(
                            onPointerDown: (e) {
                              sizeAtDown = sheetController.isAttached
                                  ? sheetController.size
                                  : 0.4;
                              tracker = VelocityTracker.withKind(
                                PointerDeviceKind.touch,
                              );
                              tracker.addPosition(e.timeStamp, e.position);
                              listMoved = false;
                              if (listController?.hasClients ?? false) {
                                listOffsetAtDown = listController!.offset;
                              }
                            },
                            onPointerMove: (e) =>
                                tracker.addPosition(e.timeStamp, e.position),
                            onPointerUp: (_) {
                              if (!sheetController.isAttached) return;
                              if (listController?.hasClients ?? false) {
                                listMoved =
                                    (listController!.offset - listOffsetAtDown)
                                        .abs() >
                                    4;
                              }
                              final size = sheetController.size;
                              final sizeMoved =
                                  (size - sizeAtDown).abs() > 0.001;
                              final velocityDy = tracker
                                  .getVelocity()
                                  .pixelsPerSecond
                                  .dy;
                              final target = userSheetTargetDetent(
                                size,
                                minExtent: 0.25,
                                cardExtent: cardExtent,
                                maxExtent: maxExtent,
                                velocityDy: velocityDy,
                              );
                              final flingDown =
                                  velocityDy >= kUserSheetFlingVelocity;
                              if (target == 0.25) {
                                // Pure list gestures never dismiss; taps stay.
                                if (listMoved || (!sizeMoved && !flingDown)) {
                                  return;
                                }
                                sheetController.jumpTo(size);
                                if (ModalRoute.of(ctx)?.isCurrent ?? false) {
                                  Navigator.pop(ctx);
                                }
                                return;
                              }
                              if (!sizeMoved) return;
                              if ((target - size).abs() <= 0.02) return;
                              sheetController.animateTo(
                                target,
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeOutCubic,
                              );
                            },
                            child: DraggableScrollableSheet(
                              controller: sheetController,
                              initialChildSize: 0.4,
                              minChildSize: 0.25,
                              maxChildSize: maxExtent,
                              expand: false,
                              snap: false,
                              shouldCloseOnMinExtent: false,
                              builder: (_, scrollController) {
                                final historyController = ScrollController();
                                listController = historyController;
                                return UserProfileSheet(
                                  username: 'testuser',
                                  userId: '123',
                                  displayName: 'TestUser',
                                  twitchApi: createApi(),
                                  twitchAuth: TwitchAuth()
                                    ..accessToken = 'test-token',
                                  messageController: TextEditingController(),
                                  focusNode: FocusNode(),
                                  onClose: () => Navigator.pop(ctx),
                                  scrollController: historyController,
                                  anchor: scrollController,
                                  sheetController: sheetController,
                                  sheetMinExtent: 0.25,
                                  onCardMeasured: (naturalH) {
                                    cardExtent = (naturalH / screenH)
                                        .clamp(0.25, maxExtent)
                                        .toDouble();
                                    if (!sheetController.isAttached) return;
                                    if ((sheetController.size - cardExtent)
                                            .abs() >
                                        0.02) {
                                      sheetController.animateTo(
                                        cardExtent,
                                        duration: const Duration(
                                          milliseconds: 250,
                                        ),
                                        curve: Curves.easeOutCubic,
                                      );
                                    }
                                  },
                                  userMessages: [
                                    for (var i = 0; i < 30; i++)
                                      TwitchMessage(
                                        login: 'testuser',
                                        text: 'm$i',
                                        channel: 'somechannel',
                                      ),
                                  ],
                                  messageRowBuilder: (context, msg) =>
                                      Text('row:${msg.text}'),
                                );
                              },
                            ),
                          );
                        },
                      ).whenComplete(sheetController.dispose);
                    },
                    child: const Text('open-card'),
                  );
                },
              ),
            ),
          ),
        );
        await tester.tap(find.text('open-card'));
        await tester.pumpAndSettle();
      }

      await openSheet();
      expect(find.text('Report'), findsOneWidget);
      // Expand first: at the card detent the history hides below the fold.
      await tester.flingFrom(
        const Offset(400, 450),
        const Offset(0, -300),
        1500,
      );
      await tester.pumpAndSettle();
      expect(sheetController.size, maxExtent);
      // Fast downward fling on history never dismisses the route (the
      // sheet may coast to a mid stop, unsnapped, but stays open).
      await tester.flingFrom(
        const Offset(400, 560),
        const Offset(0, 200),
        1500,
      );
      await tester.pumpAndSettle();
      expect(find.text('TestUser'), findsOneWidget);
    });
  });
}
