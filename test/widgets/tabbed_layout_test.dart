import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/widgets/tab_drag_focus.dart';
import 'package:ermchat/widgets/tabbed_layout.dart';

// Harness that lets a test trigger a TabbedLayout rebuild via setState while
// keeping the same selection (an "unrelated" rebuild, e.g. a message send), or
// change the selection to simulate a programmatic navigation. The selection is
// held in a ValueNotifier so the widget reads the live value on every rebuild.
// Callbacks also mirror HomeScreen by keeping the notifier in sync with the
// reported index, since the real app updates _selectedChannel from both focus
// and settle callbacks.
Widget _harness(
  ValueNotifier<int> selected, {
  required void Function(StateSetter) captureSetState,
  required ValueChanged<int> onFocusChanged,
  required ValueChanged<int> onSelectedIndexChanged,
  bool focusOnHalfDrag = true,
  bool fastSnap = true,
}) {
  return MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder: (context, set) {
          captureSetState(set);
          return TabbedLayout(
            key: const Key('tl'),
            tabs: const ['a', 'b', 'c'],
            selectedIndex: selected.value,
            focusOnHalfDrag: focusOnHalfDrag,
            fastSnap: fastSnap,
            onFocusChanged: onFocusChanged,
            onSelectedIndexChanged: onSelectedIndexChanged,
            pageBuilder: (_, i) => Container(
              key: Key('page-$i'),
              child: Center(child: Text(['a', 'b', 'c'][i])),
            ),
          );
        },
      ),
    ),
  );
}

double _pageDx(WidgetTester tester, int i) =>
    tester.getTopLeft(find.byKey(Key('page-$i'))).dx;

// Harness whose tab list (and thus channel count) can change across rebuilds,
// simulating HomeScreen._addChannel appending to _chatStore.channels.
Widget _addChannelHarness(
  ValueNotifier<int> selected,
  ValueNotifier<List<String>> tabs,
) {
  return MaterialApp(
    home: Scaffold(
      body: ValueListenableBuilder<List<String>>(
        valueListenable: tabs,
        builder: (_, tabList, _) => TabbedLayout(
          key: const Key('tl'),
          tabs: tabList,
          selectedIndex: selected.value,
          focusOnHalfDrag: true,
          onFocusChanged: (i) => selected.value = i,
          onSelectedIndexChanged: (i) => selected.value = i,
          pageBuilder: (_, i) => Container(
            key: Key('page-$i'),
            child: Center(child: Text(tabList[i])),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TabbedLayout channel switching', () {
    testWidgets('unrelated rebuild during a swipe does not snap the page back', (
      WidgetTester tester,
    ) async {
      final selected = ValueNotifier<int>(0);
      late StateSetter setStateTop;

      await tester.pumpWidget(
        _harness(
          selected,
          captureSetState: (set) => setStateTop = set,
          onFocusChanged: (i) {
            selected.value = i;
          },
          onSelectedIndexChanged: (i) => selected.value = i,
        ),
      );

      // Swipe past halfway so the page is heading to channel b (index 1).
      final size = tester.getSize(find.byType(PageView));
      final center = tester.getCenter(find.byType(PageView));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(-1, 0));
      await tester.pump();
      await gesture.moveBy(Offset(-size.width * 0.6, 0));
      await tester.pump();

      // An unrelated rebuild lands mid-swipe (e.g. doSendMessage -> onRebuild).
      setStateTop(() {});
      await tester.pump();

      await gesture.up();
      await tester.pumpAndSettle();

      // The page settled on b and was never yanked back to a.
      expect(_pageDx(tester, 1).abs(), lessThan(2.0));
    });

    testWidgets(
      'Programmatic selection moves the page and ignores unchanged rebuilds',
      (WidgetTester tester) async {
        final selected = ValueNotifier<int>(0);
        late StateSetter setStateTop;
        final selectedReports = <int>[];

        await tester.pumpWidget(
          _harness(
            selected,
            captureSetState: (set) => setStateTop = set,
            onFocusChanged: (i) => selected.value = i,
            onSelectedIndexChanged: (i) {
              selected.value = i;
              selectedReports.add(i);
            },
          ),
        );
        // External navigation to channel c (index 2). The view pager must
        // follow: the page is actually built/moved to index 2.
        setStateTop(() => selected.value = 2);
        await tester.pump();
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('page-2')), findsOneWidget);
        expect(_pageDx(tester, 2).abs(), lessThan(2.0));
        // The landing reports once and the parent's selection guard dedupes
        // it (the parent already committed index 2), so the state is
        // unchanged by the redundant report.
        expect(selectedReports, [2]);

        // Extra unrelated rebuilds must not move the page or re-fire.
        selectedReports.clear();
        setStateTop(() {});
        await tester.pump();
        await tester.pumpAndSettle();

        expect(selectedReports, isEmpty);
        expect(_pageDx(tester, 2).abs(), lessThan(2.0));
      },
    );
  });

  group('TabbedLayout edge exclusion zone', () {
    // Pages are full-bleed tappables so a tap at the very edge would land on
    // the page's GestureDetector if (and only if) the edge overlay lets taps
    // fall through. The selection is held in a notifier so we can observe
    // whether a drag at the edge switched the channel.
    Widget edgeHarness(
      ValueNotifier<int> selected,
      ValueNotifier<int> tapCount, {
      required ValueChanged<int> onFocusChanged,
      required ValueChanged<int> onSelectedIndexChanged,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: TabbedLayout(
            key: const Key('tl'),
            tabs: const ['a', 'b', 'c'],
            selectedIndex: selected.value,
            focusOnHalfDrag: true,
            onFocusChanged: onFocusChanged,
            onSelectedIndexChanged: onSelectedIndexChanged,
            pageBuilder: (_, i) => GestureDetector(
              key: Key('page-$i'),
              behavior: HitTestBehavior.opaque,
              onTap: () => tapCount.value++,
              child: Container(
                color: Colors.transparent,
                child: Center(child: Text(['a', 'b', 'c'][i])),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('Edge zone lets taps through but blocks channel drags', (
      WidgetTester tester,
    ) async {
      final selected = ValueNotifier<int>(0);
      final tapCount = ValueNotifier<int>(0);

      await tester.pumpWidget(
        edgeHarness(
          selected,
          tapCount,
          onFocusChanged: (i) => selected.value = i,
          onSelectedIndexChanged: (i) => selected.value = i,
        ),
      );

      final centerY = tester.getCenter(find.byType(PageView)).dy;
      final edgeX = TabbedLayout.minEdgeExclusion / 2;
      await tester.tapAt(Offset(edgeX, centerY));
      await tester.pump();

      // The edge overlay must not swallow the tap.
      expect(tapCount.value, 1);
      expect(selected.value, 0);

      final size = tester.getSize(find.byType(PageView));
      // Drag leftwards from the right edge: unblocked, this would switch to
      // the next channel (index 1). Blocked, the page stays put.
      final start = Offset(size.width - edgeX, centerY);
      final end = Offset(size.width - edgeX - size.width * 0.8, centerY);

      final gesture = await tester.startGesture(start);
      await gesture.moveBy(end - start);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // The channel did not switch; the OS back gesture keeps the edge.
      expect(selected.value, 0);
      expect(_pageDx(tester, 0).abs(), lessThan(2.0));
    });
  });

  group('TabbedLayout fastSnap', () {
    testWidgets('Swipe switches channels with fast snap enabled', (
      WidgetTester tester,
    ) async {
      final selected = ValueNotifier<int>(0);

      await tester.pumpWidget(
        _harness(
          selected,
          captureSetState: (_) {},
          onFocusChanged: (i) => selected.value = i,
          onSelectedIndexChanged: (i) => selected.value = i,
          fastSnap: true,
        ),
      );

      final size = tester.getSize(find.byType(PageView));
      final center = tester.getCenter(find.byType(PageView));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(Offset(-size.width * 0.6, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(selected.value, 1);
      expect(_pageDx(tester, 1).abs(), lessThan(2.0));
    });
  });

  group('TabbedLayout add channel', () {
    // Regression: adding a channel must land on it AND scroll the tab strip to
    // reveal it, even when the pager is already parked on the target (initialPage
    // honored) so no page-scroll notification fires to drive the strip.
    testWidgets('Adding channels lands on and reveals the new tab', (
      WidgetTester tester,
    ) async {
      {
        final selected = ValueNotifier<int>(0);
        final tabs = ValueNotifier<List<String>>(['a', 'b']);
        await tester.pumpWidget(_addChannelHarness(selected, tabs));
        await tester.pumpAndSettle();

        // Append channel c and select it (index 2), as _addChannel does.
        tabs.value = ['a', 'b', 'c'];
        selected.value = 2;
        await tester.pump();
        await tester.pumpAndSettle();

        // The pager actually lands on the new channel (not one short).
        expect(_pageDx(tester, 2).abs(), lessThan(2.0));
        // The tab strip scrolls to reveal the new tab (on-screen, not past the
        // right edge in its own scroller).
        final tabC = find.descendant(
          of: find.byType(TabBar),
          matching: find.text('c'),
        );
        expect(tabC, findsOneWidget);
        expect(tabC.hitTestable(), findsOneWidget);
      }
      {
        final selected = ValueNotifier<int>(0);
        final tabs = ValueNotifier<List<String>>([
          'a',
          'b',
          'c',
          'd',
          'e',
          'f',
          'g',
        ]);
        await tester.pumpWidget(_addChannelHarness(selected, tabs));
        await tester.pumpAndSettle();

        // Add channel h far off the current viewport and select it.
        tabs.value = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
        selected.value = 7;
        await tester.pump();
        await tester.pumpAndSettle();

        // The pager actually lands on the new channel (not one short).
        expect(_pageDx(tester, 7).abs(), lessThan(2.0));
        final tabH = find.descendant(
          of: find.byType(TabBar),
          matching: find.text('h'),
        );
        expect(tabH, findsOneWidget);
        expect(tabH.hitTestable(), findsOneWidget);
      }
    });
  });

  group('TabDragFocus half-drag', () {
    testWidgets('drag crossing 50% reports live, settle clears', (
      tester,
    ) async {
      final tab = TabController(length: 3, vsync: const TestVSync());
      addTearDown(tab.dispose);
      final focused = <int>[];
      final drag = TabDragFocus(tab: () => tab, onFocusChanged: focused.add);
      addTearDown(drag.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotificationListener<ScrollNotification>(
              onNotification: drag.onNotification,
              child: TabBarView(
                controller: tab,
                children: const [Text('p0'), Text('p1'), Text('p2')],
              ),
            ),
          ),
        ),
      );
      expect(drag.effectiveIndex, 0);

      // Quarter page: no crossing yet.
      final center = tester.getCenter(find.text('p0'));
      final gesture = await tester.startGesture(center);
      await gesture.moveTo(center + const Offset(-200, 0));
      await tester.pump();
      expect(focused, isEmpty);
      expect(drag.effectiveIndex, 0);

      // Past halfway: live focus flips.
      await gesture.moveTo(center + const Offset(-450, 0));
      await tester.pump();
      expect(focused, [1]);
      expect(drag.effectiveIndex, 1);

      // Release: settles on page 1, drag focus clears. Mid-flight the
      // focus must not revert to the stale controller index, and
      // snap-phase controller ticks must not clobber it either.
      await gesture.up();
      await tester.pump();
      expect(drag.effectiveIndex, 1);
      drag.syncFromController();
      expect(focused, [1]);
      expect(drag.effectiveIndex, 1);
      await tester.pumpAndSettle();
      expect(drag.dragFocus.value, isNull);
      expect(tab.index, 1);

      // Settle sync dedupes the already-reported index.
      drag.syncFromController();
      expect(focused, [1]);

      // Programmatic jump never flyover-commits.
      tab.animateTo(2);
      await tester.pumpAndSettle();
      expect(focused, [1]);
      drag.syncFromController();
      expect(focused, [1, 2]);
    });

    testWidgets('hold, move back, release stays in sync', (tester) async {
      final tab = TabController(length: 3, vsync: const TestVSync());
      addTearDown(tab.dispose);
      final focused = <int>[];
      final drag = TabDragFocus(tab: () => tab, onFocusChanged: focused.add);
      addTearDown(drag.dispose);
      // Production wiring: the panel listener settles through the helper.
      tab.addListener(() {
        if (!tab.indexIsChanging) drag.syncFromController();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotificationListener<ScrollNotification>(
              onNotification: drag.onNotification,
              child: TabBarView(
                controller: tab,
                children: const [Text('p0'), Text('p1'), Text('p2')],
              ),
            ),
          ),
        ),
      );

      // Swipe to page 0.9 and hold: live focus flips.
      final start = const Offset(780, 300);
      final gesture = await tester.startGesture(start);
      await gesture.moveTo(start + const Offset(-720, 0));
      await tester.pump();
      expect(focused, [1]);
      expect(drag.effectiveIndex, 1);

      // Move back to page 0.3 and hold: focus follows back.
      await gesture.moveTo(start + const Offset(-240, 0));
      await tester.pump();
      expect(focused, [1, 0]);
      expect(drag.effectiveIndex, 0);

      // Release: snaps back to 0, nothing stranded.
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tab.index, 0);
      expect(drag.dragFocus.value, isNull);
      expect(drag.effectiveIndex, 0);

      // Settle path still alive afterwards.
      tab.animateTo(2);
      await tester.pumpAndSettle();
      expect(focused, [1, 0, 2]);
      expect(drag.effectiveIndex, 2);
    });

    testWidgets('fling without drag crossing reports live mid-flight', (
      tester,
    ) async {
      final tab = TabController(length: 3, vsync: const TestVSync());
      addTearDown(tab.dispose);
      final focused = <int>[];
      final drag = TabDragFocus(tab: () => tab, onFocusChanged: focused.add);
      addTearDown(drag.dispose);
      tab.addListener(() {
        if (!tab.indexIsChanging) drag.syncFromController();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotificationListener<ScrollNotification>(
              onNotification: drag.onNotification,
              child: TabBarView(
                controller: tab,
                children: const [Text('p0'), Text('p1'), Text('p2')],
              ),
            ),
          ),
        ),
      );

      // Short drag, hard fling: the drag phase never crosses 50%, so any
      // live report must come from the ballistic flight.
      await tester.fling(find.text('p0'), const Offset(-200, 0), 2500);
      var sawLive = false;
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (focused.contains(1) && tab.index == 0) sawLive = true;
        if (sawLive && tab.index != 0) break;
      }
      expect(sawLive, isTrue);
      await tester.pumpAndSettle();
      expect(drag.dragFocus.value, isNull);
      expect(focused.last, tab.index);
      expect(drag.effectiveIndex, tab.index);
      expect(tab.index, greaterThan(0));
    });

    testWidgets('direct index jump reports landing only', (tester) async {
      final tab = TabController(length: 3, vsync: const TestVSync());
      addTearDown(tab.dispose);
      final focused = <int>[];
      final drag = TabDragFocus(tab: () => tab, onFocusChanged: focused.add);
      addTearDown(drag.dispose);
      tab.addListener(() {
        if (!tab.indexIsChanging) drag.syncFromController();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotificationListener<ScrollNotification>(
              onNotification: drag.onNotification,
              child: TabBarView(
                controller: tab,
                children: const [Text('p0'), Text('p1'), Text('p2')],
              ),
            ),
          ),
        ),
      );

      // Instant jump (the show-verb path): no travel, so only the landing
      // reports, never intermediates.
      tab.index = 2;
      await tester.pumpAndSettle();
      expect(focused, [2]);
      expect(drag.dragFocus.value, isNull);
      expect(drag.effectiveIndex, 2);

      // Adjacent jumpTo (the show-verb shape): the warp animates under
      // indexIsChanging false, but travel still swallows to one report.
      // Frame-stepped so intermediate frames rounding to 2 are observed.
      drag.jumpTo(1);
      expect(focused, [2, 1]);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(focused, [2, 1]);
      await tester.pumpAndSettle();
      expect(focused, [2, 1]);

      // Already there: pure no-op.
      drag.jumpTo(1);
      await tester.pumpAndSettle();
      expect(focused, [2, 1]);
    });

    testWidgets('tap retarget during flight converges', (tester) async {
      final tab = TabController(length: 3, vsync: const TestVSync());
      addTearDown(tab.dispose);
      final focused = <int>[];
      final drag = TabDragFocus(tab: () => tab, onFocusChanged: focused.add);
      addTearDown(drag.dispose);
      tab.addListener(() {
        if (!tab.indexIsChanging) drag.syncFromController();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotificationListener<ScrollNotification>(
              onNotification: drag.onNotification,
              child: TabBarView(
                controller: tab,
                children: const [Text('p0'), Text('p1'), Text('p2')],
              ),
            ),
          ),
        ),
      );

      // Fling toward 2; once the flight moves the index, retarget to 0
      // mid-flight like a tab tap, then prove nothing stranded.
      await tester.fling(find.text('p0'), const Offset(-200, 0), 2500);
      for (var i = 0; i < 90 && tab.index != 1; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tab.index, 1);
      tab.animateTo(0);
      await tester.pumpAndSettle();
      expect(tab.index, 0);
      expect(drag.dragFocus.value, isNull);
      expect(focused.last, 0);
      expect(drag.effectiveIndex, 0);

      // Settle path still alive afterwards: no stranded flight state.
      tab.animateTo(2);
      await tester.pumpAndSettle();
      expect(focused.last, 2);
    });

    testWidgets('fast fling across pages converges', (tester) async {
      final tab = TabController(length: 3, vsync: const TestVSync());
      addTearDown(tab.dispose);
      final focused = <int>[];
      final drag = TabDragFocus(tab: () => tab, onFocusChanged: focused.add);
      addTearDown(drag.dispose);
      tab.addListener(() {
        if (!tab.indexIsChanging) drag.syncFromController();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotificationListener<ScrollNotification>(
              onNotification: drag.onNotification,
              child: TabBarView(
                controller: tab,
                children: const [Text('p0'), Text('p1'), Text('p2')],
              ),
            ),
          ),
        ),
      );

      await tester.fling(find.text('p0'), const Offset(-800, 0), 8000);
      await tester.pumpAndSettle();
      expect(tab.index, 2);
      expect(drag.dragFocus.value, isNull);
      expect(focused.last, 2);
      expect(drag.effectiveIndex, 2);

      // Settle path still alive afterwards.
      tab.animateTo(0);
      await tester.pumpAndSettle();
      expect(focused.last, 0);
    });

    testWidgets('far animateTo never reports intermediates', (tester) async {
      final tab = TabController(length: 3, vsync: const TestVSync());
      addTearDown(tab.dispose);
      final focused = <int>[];
      final drag = TabDragFocus(tab: () => tab, onFocusChanged: focused.add);
      addTearDown(drag.dispose);
      tab.addListener(() {
        if (!tab.indexIsChanging) drag.syncFromController();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotificationListener<ScrollNotification>(
              onNotification: drag.onNotification,
              child: TabBarView(
                controller: tab,
                children: const [Text('p0'), Text('p1'), Text('p2')],
              ),
            ),
          ),
        ),
      );

      tab.animateTo(2);
      await tester.pumpAndSettle();
      expect(focused, [2]);
      expect(drag.effectiveIndex, 2);
    });

    testWidgets('exact-rest lift and mid-drag reset do not strand', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      final context = tester.element(find.byType(SizedBox));
      PageMetrics metrics(double page) => PageMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 1600,
        pixels: page * 800,
        viewportDimension: 800,
        axisDirection: AxisDirection.right,
        viewportFraction: 1,
        devicePixelRatio: 1,
      );
      ScrollNotification dragStart() => ScrollStartNotification(
        metrics: metrics(0),
        context: context,
        dragDetails: DragStartDetails(),
      );
      ScrollNotification dragUpdate(double page) => ScrollUpdateNotification(
        metrics: metrics(page),
        context: context,
        dragDetails: DragUpdateDetails(globalPosition: Offset.zero),
      );
      ScrollNotification dragEnd(double page) => ScrollEndNotification(
        metrics: metrics(page),
        context: context,
        dragDetails: DragEndDetails(),
      );

      // Exact-rest lift: out past 50%, back to pixel-exact rest, lift with
      // no velocity. No ballistic follows, so settle syncs must survive.
      {
        final tab = TabController(length: 3, vsync: const TestVSync());
        addTearDown(tab.dispose);
        final focused = <int>[];
        final drag = TabDragFocus(tab: () => tab, onFocusChanged: focused.add);
        addTearDown(drag.dispose);
        expect(drag.onNotification(dragStart()), isFalse);
        expect(drag.onNotification(dragUpdate(1)), isFalse);
        expect(drag.onNotification(dragUpdate(0)), isFalse);
        expect(focused, [1, 0]);
        expect(drag.onNotification(dragEnd(0)), isFalse);
        expect(drag.effectiveIndex, 0);
        tab.index = 2;
        drag.syncFromController();
        expect(focused, [1, 0, 2]);
      }

      // Mid-drag reset keeps the live seed: the snap-back still reports.
      {
        final tab = TabController(length: 3, vsync: const TestVSync());
        addTearDown(tab.dispose);
        final focused = <int>[];
        final drag = TabDragFocus(tab: () => tab, onFocusChanged: focused.add);
        addTearDown(drag.dispose);
        expect(drag.onNotification(dragStart()), isFalse);
        expect(drag.onNotification(dragUpdate(1)), isFalse);
        expect(focused, [1]);
        drag.reset();
        expect(drag.onNotification(dragUpdate(0)), isFalse);
        expect(focused, [1, 0]);
        expect(drag.onNotification(dragEnd(0)), isFalse);
        expect(drag.effectiveIndex, 0);
      }
    });
  });
}
