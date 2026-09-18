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
  });

  group('TabbedLayout tab strip stretch', () {
    // Enough tabs to overflow the viewport so the strip is scrollable; the
    // selected tab is last, so the strip rests at its trailing edge.
    Widget stretchHarness() => MaterialApp(
      home: Scaffold(
        body: TabbedLayout(
          key: const Key('tl'),
          tabs: List.generate(12, (i) => 'channel$i'),
          selectedIndex: 11,
          onSelectedIndexChanged: (_) {},
          pageBuilder: (_, i) => Center(child: Text('page$i')),
        ),
      ),
    );

    testWidgets('overscrolling the strip stretches then springs back', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(stretchHarness());
      await tester.pumpAndSettle();

      // The PageView installs a stretch indicator too, so scope to the one
      // wrapping the TabBar.
      StretchEffect tabEffect() => tester.widget<StretchEffect>(
        find.ancestor(
          of: find.byType(TabBar),
          matching: find.byType(StretchEffect),
        ),
      );

      final start = tester.getCenter(find.byType(TabBar));
      final gesture = await tester.startGesture(start);
      // Stepped moves so each drag update lands past the trailing edge and
      // builds up overscroll.
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(-20, 0));
        await tester.pump();
      }

      // Dragged past the trailing edge: content stretches.
      expect(tabEffect().stretchStrength.abs(), greaterThan(0.0));

      await gesture.up();
      await tester.pumpAndSettle();

      expect(tabEffect().stretchStrength, 0.0);
    });
  });

  group('TabbedLayout dynamic page window', () {
    testWidgets('a far jump never builds the pages it flies over', (
      tester,
    ) async {
      final selected = ValueNotifier<int>(0);
      final built = <int>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: selected,
              builder: (_, index, _) => TabbedLayout(
                key: const Key('tl'),
                tabs: List.generate(8, (i) => 'c$i'),
                selectedIndex: index,
                onSelectedIndexChanged: (i) => selected.value = i,
                pageBuilder: (_, i) {
                  built.add(i);
                  return Center(child: Text('page$i'));
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      built.clear();

      // Jump 0 -> 7. The pre-jump lands near the target, so the flight only
      // builds the pages it actually shows.
      selected.value = 7;
      await tester.pump();
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();

      expect(built, contains(7));
      expect(built, isNot(contains(1)));
      expect(built, isNot(contains(2)));
    });

    testWidgets('only the focused page has tickers enabled', (tester) async {
      final selected = ValueNotifier<int>(0);
      Widget page(int i) => Builder(
        builder: (context) => Text(
          'page$i:${TickerMode.valuesOf(context).enabled ? 'on' : 'off'}',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: selected,
              builder: (_, index, _) => TabbedLayout(
                key: const Key('tl'),
                tabs: const ['a', 'b', 'c'],
                selectedIndex: index,
                preloadAdjacentPages: true,
                onSelectedIndexChanged: (i) => selected.value = i,
                pageBuilder: (_, i) => page(i),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('page0:on', skipOffstage: false), findsOneWidget);
      expect(find.text('page1:off', skipOffstage: false), findsOneWidget);

      selected.value = 1;
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('page1:on', skipOffstage: false), findsOneWidget);
      expect(find.text('page0:off', skipOffstage: false), findsOneWidget);
    });
  });

  group('TabbedLayout tab tap focus', () {
    testWidgets('tapping a tab commits focus before the flight lands', (
      tester,
    ) async {
      final selected = ValueNotifier<int>(0);
      final reported = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: selected,
              builder: (_, index, _) => TabbedLayout(
                key: const Key('tl'),
                tabs: const ['a', 'b', 'c'],
                selectedIndex: index,
                onSelectedIndexChanged: (i) {
                  selected.value = i;
                  reported.add(i);
                },
                pageBuilder: (_, i) => Center(child: Text('page$i')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(of: find.byType(TabBar), matching: find.text('c')),
      );
      // One frame into the flight: focus already committed to c.
      await tester.pump();
      expect(reported, [2]);
      expect(selected.value, 2);

      await tester.pumpAndSettle();
      // The landing dedups against the tap commit.
      expect(reported, [2]);
    });
  });
}
