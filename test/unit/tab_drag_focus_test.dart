import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/widgets/tab_drag_focus.dart';

void main() {
  group('TabDragFocus', () {
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
