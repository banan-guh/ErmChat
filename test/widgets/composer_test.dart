import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/client/session.dart';
import 'package:ermchat/composer/composer_controller.dart';
import 'package:ermchat/emotes/emote_catalog.dart';
import 'package:ermchat/l10n/l10n.dart';
import 'package:ermchat/services/chat_connection_manager.dart';
import 'package:ermchat/services/chat_sender.dart';
import 'package:ermchat/services/command_handler.dart';
import 'package:ermchat/services/emote_usage_registry.dart';
import 'package:ermchat/services/user_store.dart';
import 'package:ermchat/widgets/panel_manager.dart';

import 'widget_test_harness.dart';

mixin _Unimplemented {
  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$runtimeType.${invocation.memberName}');
}

class _UnusedCommandHandler with _Unimplemented implements CommandHandler {}

class _UnusedEmotes with _Unimplemented implements EmoteLookupSource {
  @override
  EmoteLookup? lookup(String channel, String? senderTwitchId) => null;
}

class _SpamConn with _Unimplemented implements ChatConnectionManager {
  _SpamConn(this.session, this.auth, this.macros) : irc = IrcService() {
    sender = ChatSender(
      irc: irc,
      session: session,
      twitchAuth: auth,
      onCommand: (_, _, _) {},
      getReplyToMsg: () => null,
      setReplyToMsg: (_) {},
      onSystemMessage: (_, _) {},
      slowModeSeconds: (_) => 0,
      selfBadges: (_) => const {},
      getMacros: () => macros,
    );
  }

  final Session session;
  final TwitchAuth auth;
  final Map<String, String> macros;
  final IrcService irc;
  @override
  late final ChatSender sender;
  final delays = <Duration>[];
  final sent = <String>[];
  int delayCalls = 0;

  @override
  bool get isChatPipeConnected => true;

  @override
  bool isCommandText(String text) => sender.isCommandText(text);

  @override
  Duration repeatDelay(
    String channel, {
    Duration? gap,
    Duration? privilegedGap,
  }) {
    delayCalls++;
    return delays.isEmpty ? const Duration(seconds: 1) : delays.removeAt(0);
  }

  @override
  Future<void> doSendMessage(
    String text,
    String channel, {
    TwitchMessage? replyTo,
  }) async {
    sent.add(text);
  }

  @override
  int? remainingSelfTimeout(String channel) => null;

  @override
  int? remainingSlowCooldown(String channel) => null;

  @override
  void dispose() {
    sender.dispose();
    irc.dispose();
  }
}

({ComposerController composer, _SpamConn conn}) _spamComposer(
  Map<String, String> macros, {
  List<Duration> delays = const [],
}) {
  final session = Session()..seed('viewer');
  final auth = TwitchAuth()..accessToken = 'test-token';
  final conn = _SpamConn(session, auth, macros)..delays.addAll(delays);
  final chat = Chat()..ensure('test');
  final usage = EmoteUsageRegistry(capacity: () => 300);
  final composer = ComposerController(
    chatConn: conn,
    commandHandler: _UnusedCommandHandler(),
    twitchAuth: auth,
    emoteSource: _UnusedEmotes(),
    emoteUsage: usage,
    userStore: UserStore(),
    chat: chat,
    session: session,
    setReplyTo: (_) {},
    getSelectedChannel: () => 'test',
    isWhispersTabActive: () => false,
    whisperTarget: () => null,
    activePanel: () => OverlayPanel.closed,
    threadsTabIndex: () => 0,
    openThreadRoot: () => null,
    replyToRoot: () => false,
    preferEmotesFirst: () => false,
    sendSwipeMenu: () => false,
    spamIntervalMs: () => 1000,
    spamIntervalModMs: () => 1000,
    computeThreadMessages: () => const [],
    channelChatReady: () => true,
    replayingVod: () => false,
    showNotice: (_) {},
    strings: englishStrings,
    emoteSheetOpen: () => false,
    closeEmoteSheet: () async {},
    showEmoteMenu: () {},
    markDirty: () {},
  );
  addTearDown(conn.dispose);
  addTearDown(chat.dispose);
  addTearDown(usage.dispose);
  addTearDown(session.dispose);
  addTearDown(auth.dispose);
  return (composer: composer, conn: conn);
}

// Composer regressions:
//  - the field must focus on a plain tap;
//  - the shared inputBarKey must never mount twice and must keep the
//    composer's FocusNode alive as the island moves between paths;
//  - the island floats one margin above the body safe area.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    HomeScreen.disableJoinSpinner = true;
  });

  testWidgets('spam never starts or continues for a command macro', (
    tester,
  ) async {
    final macros = <String, String>{'repeat': 'hello'};
    final blocked = _spamComposer(macros);
    macros['repeat'] = '/ban friend';
    blocked.composer.messageController.text = 'repeat friend';
    blocked.composer.startSpam();
    await tester.pump(const Duration(seconds: 2));
    expect(blocked.conn.sent, isEmpty, reason: 'command macro started spam');
    expect(blocked.conn.delayCalls, 0, reason: 'command macro created a timer');

    macros['repeat'] = 'hello';
    final edited = _spamComposer(macros, delays: [const Duration(seconds: 1)]);
    edited.composer.messageController.text = 'repeat friend';
    edited.composer.startSpam();
    expect(edited.conn.delayCalls, 1);
    macros['repeat'] = '/ban friend';
    await tester.pump(const Duration(seconds: 1));
    expect(
      edited.conn.sent,
      isEmpty,
      reason: 'spam continued after the macro became a command',
    );
    expect(
      edited.conn.delayCalls,
      1,
      reason: 'command macro reached the repeat loop',
    );
    blocked.composer.dispose();
    edited.composer.dispose();
  });

  testWidgets('a zero repeat delay sends once without a zero-delay loop', (
    tester,
  ) async {
    final spam = _spamComposer(
      {},
      delays: [Duration.zero, Duration.zero, Duration.zero],
    );
    spam.composer.messageController.text = 'hello';
    spam.composer.startSpam();
    await tester.pump(const Duration(seconds: 5));
    expect(spam.conn.sent, ['hello']);
    expect(
      spam.conn.delayCalls,
      3,
      reason: 'a zero delay re-armed the repeat timer',
    );
    spam.composer.dispose();
  });

  test('sent history keeps newest first, collapses repeats, and caps', () {
    final c = _spamComposer({});
    void send(String text) {
      c.composer.messageController.text = text;
      c.composer.send();
    }

    send('one');
    send('two');
    send('two');
    send('three');
    expect(c.composer.sentHistory.value, ['three', 'two', 'one']);

    for (var i = 0; i < ComposerController.maxSentHistory + 5; i++) {
      send('m$i');
    }
    expect(
      c.composer.sentHistory.value.length,
      ComposerController.maxSentHistory,
    );
    expect(c.composer.sentHistory.value.first, 'm54');

    c.composer.messageController.text = 'draft';
    c.composer.loadFromHistory('two');
    expect(c.composer.messageController.text, 'two');
    c.composer.dispose();
  });

  // Bare ChatBody harness: geometry and hit-testing without the whole app.
  Future<void> pumpBody(
    WidgetTester tester, {
    required FocusNode focus,
    bool dismissUnfocuses = false,
    List<double>? keyboardHs,
    bool bodyReadsKeyboard = true,
    bool keyboardHidesButtons = false,
    bool islandFlush = false,
    Widget? bottomBar,
    Widget? islandFooter,
    double Function(String channel)? islandFooterHeightFor,
    Listenable? busyListenable,
    bool Function()? isBusy,
    TextEditingController? text,
    int maxLines = 1,
    void Function(BuildContext body)? onBodyBuild,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        home: Scaffold(
          body: ChatBody(
            keyboardHidesButtons: keyboardHidesButtons,
            islandFlush: islandFlush,
            emoteMaxFraction: 0.5,
            onKeyboardDismissed: dismissUnfocuses ? focus.unfocus : null,
            bodyReadsKeyboard: bodyReadsKeyboard,
            composer: TextField(
              key: const Key('message_input'),
              controller: text,
              focusNode: focus,
              minLines: 1,
              maxLines: maxLines,
            ),
            bottomBar: bottomBar,
            islandFooter: islandFooter,
            islandFooterHeightFor: islandFooterHeightFor,
            busyListenable: busyListenable,
            isBusy: isBusy,
            bodyBuilder:
                (
                  context, {
                  required hideChromeForKeyboard,
                  required maxWidth,
                  required maxHeight,
                  required keyboardH,
                  required composerH,
                }) {
                  keyboardHs?.add(keyboardH);
                  if (onBodyBuild == null) return const SizedBox.expand();
                  return Builder(
                    builder: (inner) {
                      onBodyBuild(inner);
                      return const SizedBox.expand();
                    },
                  );
                },
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
  }

  // Shipped bug (#38): panels asked the footer for their own channel
  // (@whispers, @mentions), got none, and the island's status line covered
  // their newest row.
  testWidgets('panel lists clear the footer on screen', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final status = ValueNotifier(20.0);
    addTearDown(status.dispose);
    IslandScope? scope;
    await pumpBody(
      tester,
      focus: focus,
      bottomBar: const SizedBox(height: 48),
      islandFooter: ValueListenableBuilder<double>(
        valueListenable: status,
        builder: (_, h, _) => SizedBox(height: h),
      ),
      islandFooterHeightFor: (channel) => channel == 'chan' ? 20 : 0,
      onBodyBuild: (inner) => scope = IslandScope.maybeOf(inner),
    );
    await tester.pumpAndSettle();
    double islandGap() =>
        800 - tester.getRect(find.byKey(const ValueKey('composer_island'))).top;

    expect(
      scope!.metrics.clearance(),
      moreOrLessEquals(islandGap(), epsilon: 1),
    );
    expect(
      scope!.metrics.clearance(page: 'chan'),
      moreOrLessEquals(islandGap(), epsilon: 1),
      reason: 'the selected page clears the same island',
    );

    // The footer grows with the panel open: a panel only heard of a footer
    // coming or going and kept its first frame's height.
    status.value = 40;
    await tester.pumpAndSettle();
    expect(
      scope!.metrics.clearance(),
      moreOrLessEquals(islandGap(), epsilon: 1),
    );
  });

  // Shipped bug: the body's viewPadding loses the nav bar under the keyboard,
  // so a closing keyboard dragged the field past its rest, and it climbed
  // back as the row reappeared.
  testWidgets('a keyboard close never dips the field below its rest', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 42);
    tester.view.viewPadding = const FakeViewPadding(bottom: 42);
    addTearDown(tester.view.reset);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await pumpBody(
      tester,
      focus: focus,
      keyboardHidesButtons: true,
      bottomBar: const SizedBox(height: 48),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('message_input'));
    final rest = tester.getRect(field).bottom;
    focus.requestFocus();
    await tester.pump();
    for (var kb = 0.0; kb <= 300; kb += 30) {
      tester.view.viewInsets = FakeViewPadding(bottom: kb);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    for (var kb = 300.0; kb >= 0; kb -= 20) {
      tester.view.viewInsets = FakeViewPadding(bottom: kb);
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getRect(field).bottom,
        lessThanOrEqualTo(rest + 0.5),
        reason: 'keyboard at $kb dragged the field below its rest',
      );
    }
  });

  testWidgets('a flush island and its rows clear the nav bar together', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 42);
    tester.view.viewPadding = const FakeViewPadding(bottom: 42);
    addTearDown(tester.view.reset);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    IslandMetrics? metrics;
    double clearance() => metrics?.clearance() ?? 0;
    await pumpBody(
      tester,
      focus: focus,
      islandFlush: true,
      onBodyBuild: (body) => metrics = IslandScope.maybeOf(body)?.metrics,
    );
    await tester.pumpAndSettle();
    final island = find.byKey(const ValueKey('composer_island'));
    focus.requestFocus();
    await tester.pump();
    void moveKeyboard(double kb) {
      tester.view.viewInsets = FakeViewPadding(bottom: kb);
      // The system pads the nav bar only where the keyboard leaves it.
      tester.view.padding = FakeViewPadding(bottom: kb >= 42 ? 0 : 42 - kb);
    }

    for (var kb = 0.0; kb <= 300; kb += 30) {
      moveKeyboard(kb);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    // The last stretch of a close uncovers the nav bar, growing the
    // island's own padding every frame; the rows must track it, not lag.
    for (var kb = 60.0; kb >= 0; kb -= 6) {
      moveKeyboard(kb);
      await tester.pump(const Duration(milliseconds: 16));
      final top = tester.getRect(island).top;
      expect(
        clearance(),
        moreOrLessEquals(800 - kb - top, epsilon: 0.5),
        reason: 'keyboard at $kb: rows lag the island',
      );
    }
  });

  // #56: the edge-to-edge bar can collapse its row while typing, not just
  // the floating island.
  testWidgets('a flush row hides while typing', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await pumpBody(
      tester,
      focus: focus,
      islandFlush: true,
      keyboardHidesButtons: true,
      bottomBar: const SizedBox(key: Key('test_bar'), height: 48),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('message_input'));
    final island = find.byKey(const ValueKey('composer_island'));
    final bar = find.byKey(const Key('test_bar'));
    final openHeight = tester.getSize(island).height;
    expect(
      tester.getRect(bar).top,
      greaterThanOrEqualTo(tester.getRect(field).bottom - 0.5),
      reason: 'the row sits under the field while closed',
    );

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      tester.getRect(island).bottom,
      closeTo(800 - 300, 0.5),
      reason: 'edge to edge stays on the body bottom',
    );
    expect(
      tester.getSize(island).height,
      closeTo(tester.getSize(field).height, 1.0),
      reason: 'the row is clipped away, leaving the field',
    );
    expect(
      tester.getSize(island).height,
      lessThan(openHeight),
      reason: 'the bar collapses while typing',
    );
  });

  // A short screen collapses chrome once the keyboard opens (the iPhone
  // case). The island must stay put: only the focus glow changes.
  testWidgets('keyboard chrome collapse keeps the island', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    tester.view.physicalSize = const Size(400, 550);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpBody(tester, focus: focus);
    await tester.pumpAndSettle();
    final island = find.byKey(const ValueKey('composer_island'));
    final width = tester.getSize(island).width;
    await tester.tap(find.byKey(const Key('message_input')));
    await tester.pump();

    for (var kb = 50.0; kb <= 350; kb += 50) {
      tester.view.viewInsets = FakeViewPadding(bottom: kb);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();

    expect(island, findsOneWidget);
    expect(tester.getSize(island).width, width);
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(
      find.descendant(
        of: find.byType(ComposerFocusGlow),
        matching: find.byType(AnimatedContainer),
      ),
      findsOneWidget,
    );
  });

  Future<void> moveKeyboard(WidgetTester tester, List<double> insets) async {
    for (final kb in insets) {
      tester.view.viewInsets = FakeViewPadding(bottom: kb);
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  // A tap right after a close asks for the keyboard before the IME's first
  // tick lands; the close's pending unfocus then closed it again.
  testWidgets('retap after a close keeps the keyboard', (tester) async {
    for (final gap in [60, 100]) {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = FakeViewPadding.zero;
      addTearDown(tester.view.reset);
      await pumpBody(tester, focus: focus, dismissUnfocuses: true);
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('message_input'));
      await tester.tap(field);
      await tester.pump();
      await moveKeyboard(tester, [100, 200, 300]);
      await tester.pump(const Duration(milliseconds: 400));
      await moveKeyboard(tester, [200, 100, 0]);

      await tester.pump(Duration(milliseconds: gap));
      await tester.tap(field);
      await tester.pump(const Duration(milliseconds: 80));
      await moveKeyboard(tester, [100, 200, 300]);
      await tester.pump(const Duration(milliseconds: 400));

      expect(focus.hasFocus, isTrue, reason: 'gap ${gap}ms');
      expect(tester.testTextInput.isVisible, isTrue, reason: 'gap ${gap}ms');
    }
  });

  testWidgets(
    'keyboard ticks cache the body, request frames, and learn height',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      Future<FocusNode> fresh() async {
        tester.view.viewInsets = FakeViewPadding.zero;
        tester.view.padding = FakeViewPadding.zero;
        tester.view.viewPadding = FakeViewPadding.zero;
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await pumpBody(tester, focus: focus, dismissUnfocuses: true);
        await tester.pumpAndSettle();
        return focus;
      }

      // Without a stacked player the body ignores the keyboard numbers, so a
      // gesture must not rebuild it (a few hundred elements on open and close).
      await fresh();
      final builds = <double>[];
      final blindFocus = FocusNode();
      addTearDown(blindFocus.dispose);
      await pumpBody(
        tester,
        focus: blindFocus,
        keyboardHs: builds,
        bodyReadsKeyboard: false,
      );
      await tester.pumpAndSettle();
      builds.clear();
      await moveKeyboard(tester, [100, 200, 300]);
      await tester.pump(const Duration(milliseconds: 400));
      await moveKeyboard(tester, [200, 100, 0]);
      await tester.pump(const Duration(milliseconds: 400));
      expect(builds, isEmpty);

      // Inset ticks land inside Android's frame. With no frame already
      // requested, each one missed its vsync and a reopen after unfocus drew
      // at 30fps.
      await fresh();
      for (final kb in <double>[100, 200, 300]) {
        tester.view.viewInsets = FakeViewPadding(bottom: kb);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.binding.hasScheduledFrame, isTrue, reason: 'kb=$kb');
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'settled');

      // An IME that stalls mid-close settles at a partial height. Learning it
      // made the next open assume that height, then flip decisions on settle.
      final focus = await fresh();
      final keyboardHs = <double>[];
      await pumpBody(tester, focus: focus, keyboardHs: keyboardHs);
      await tester.pumpAndSettle();
      await moveKeyboard(tester, [100, 200, 300]);
      await tester.pump(const Duration(milliseconds: 400));
      await moveKeyboard(tester, [250, 200]);
      await tester.pump(const Duration(milliseconds: 200));
      await moveKeyboard(tester, [100, 0]);
      await tester.pump(const Duration(milliseconds: 400));

      keyboardHs.clear();
      await moveKeyboard(tester, [30]);
      expect(keyboardHs.first, 300, reason: 'next open uses the real height');
    },
  );

  // A real Samsung close (from a device trace) eases out in sub-pixel steps
  // while the nav-bar padding grows back. The step onto closed was dropped
  // as noise and the field never unfocused.
  testWidgets('a sub-pixel keyboard close still unfocuses', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.viewPadding = const FakeViewPadding(bottom: 15);
    addTearDown(tester.view.reset);
    await pumpBody(tester, focus: focus, dismissUnfocuses: true);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('message_input')));
    await tester.pump();
    Future<void> tick(double kb) async {
      tester.view.viewInsets = FakeViewPadding(bottom: kb);
      tester.view.padding = FakeViewPadding(bottom: kb >= 15 ? 0 : 15 - kb);
      await tester.pump(const Duration(milliseconds: 16));
    }

    for (final kb in <double>[100, 200, 300]) {
      await tick(kb);
    }
    await tester.pump(const Duration(milliseconds: 400));
    for (final kb in <double>[
      100,
      50,
      20,
      12.1,
      8.2,
      4.6,
      2.5,
      1.4,
      1.1,
      0.7,
      0.4,
      0.4,
      0.0,
      0.0,
    ]) {
      await tick(kb);
    }
    await tester.pump(const Duration(milliseconds: 400));

    expect(focus.hasFocus, isFalse);
  });

  // Full-app harness: the real HomeScreen wiring, joined and connected, so the
  // field is enabled and a plain tap can be checked.
  Future<void> pumpJoined(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    tester.view.viewInsets = FakeViewPadding.zero;
    tester.view.viewPadding = const FakeViewPadding(bottom: 45.0);
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
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

  testWidgets('full app composer keeps focus across rebuilds and sheets', (
    WidgetTester tester,
  ) async {
    await pumpJoined(tester);

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

    expect(node.hasFocus, isTrue, reason: 'tapping the composer must focus it');
    expect(tester.takeException(), isNull);

    // Back with the keyboard up skipped the IME's predictive dip: any rebuild
    // while focused claimed back for the app, outranking the IME's callback.
    tester.element(find.byType(HomeScreen)).markNeedsBuild();
    await tester.pump();

    final scope = tester.widget<PopScope>(
      find
          .descendant(
            of: find.byType(HomeScreen),
            matching: find.byWidgetPredicate((w) => w is PopScope),
          )
          .first,
    );
    expect(scope.canPop, isTrue, reason: 'the IME must own back');

    // A sheet over the chat took focus and handed it back on pop, reopening
    // the IME cold; when Android ignored that show the field stayed focused
    // with no keyboard, and back closed the app instead of unfocusing.
    final home = tester.element(find.byType(HomeScreen));
    unawaited(
      showModalBottomSheet<void>(
        context: home,
        builder: (_) => const SizedBox(height: 200),
      ),
    );
    await tester.pumpAndSettle();
    Navigator.of(home).pop();
    await tester.pumpAndSettle();

    expect(node.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('typing a new line lifts the chat with the growing field', (
    tester,
  ) async {
    IslandMetrics? metrics;
    double clearance() => metrics?.clearance() ?? 0;
    final text = TextEditingController();
    final focus = FocusNode();
    addTearDown(text.dispose);
    addTearDown(focus.dispose);
    await pumpBody(
      tester,
      focus: focus,
      text: text,
      maxLines: 6,
      bottomBar: const SizedBox(height: 48),
      onBodyBuild: (inner) {
        metrics = IslandScope.maybeOf(inner)?.metrics;
      },
    );
    await tester.pumpAndSettle();
    final screenH =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    double fieldGap() =>
        screenH - tester.getRect(find.byKey(const Key('message_input'))).top;
    focus.requestFocus();
    await tester.pump();
    for (var line = 2; line <= 4; line++) {
      // One keystroke grows the field; nothing else rebuilds while its
      // height animates.
      text.text = '${text.text}a\n';
      await tester.pump();
      for (var f = 0; f < 20; f++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        clearance(),
        moreOrLessEquals(fieldGap(), epsilon: 1),
        reason: 'line $line left the newest message under the field',
      );
    }

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding.zero;
    addTearDown(tester.view.reset);
    IslandMetrics? hiddenMetrics;
    double hiddenClearance() => hiddenMetrics?.clearance() ?? 0;
    final hiddenText = TextEditingController(text: 'a\nb');
    final hiddenFocus = FocusNode();
    addTearDown(hiddenText.dispose);
    addTearDown(hiddenFocus.dispose);
    await pumpBody(
      tester,
      focus: hiddenFocus,
      text: hiddenText,
      maxLines: 6,
      keyboardHidesButtons: true,
      bottomBar: const SizedBox(key: Key('test_bar'), height: 48),
      onBodyBuild: (inner) {
        hiddenMetrics = IslandScope.maybeOf(inner)?.metrics;
      },
    );
    await tester.pumpAndSettle();
    final island = find.byKey(const ValueKey('composer_island'));
    final bar = find.byKey(const Key('test_bar'));
    double hiddenFieldGap() =>
        tester.getRect(find.byType(ChatBody)).bottom -
        tester.getRect(find.byKey(const Key('message_input'))).top;
    // Two lines typed before the keyboard opens and hides the row.
    hiddenFocus.requestFocus();
    await tester.pump();
    await moveKeyboard(tester, [for (var kb = 0.0; kb <= 300; kb += 30) kb]);
    await tester.pumpAndSettle();
    expect(hiddenClearance(), moreOrLessEquals(hiddenFieldGap(), epsilon: 1));

    hiddenText.clear();
    await tester.pumpAndSettle();
    expect(
      hiddenClearance(),
      moreOrLessEquals(hiddenFieldGap(), epsilon: 1),
      reason: 'sending left a gap under the newest message',
    );

    // Shipped bug: while the field grew, the row read as shorter than it is
    // and peeked out under the field until the animation ended.
    hiddenText.text = 'a\nb';
    for (var f = 0; f < 20; f++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getRect(bar).top,
        greaterThanOrEqualTo(tester.getRect(island).bottom - 0.5),
        reason: 'frame $f showed the hidden row',
      );
    }
    await tester.pumpAndSettle();
    expect(
      hiddenClearance(),
      moreOrLessEquals(hiddenFieldGap(), epsilon: 1),
      reason: 'a typed line slid the field over the newest message',
    );
  });
}
