import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TabbedLayout channel switching', () {
    testWidgets('unrelated rebuild during a swipe does not snap the page back', (
      WidgetTester tester,
    ) async {
      final selected = ValueNotifier<int>(0);
      late StateSetter setStateTop;
      final focuses = <int>[];

      await tester.pumpWidget(
        _harness(
          selected,
          captureSetState: (set) => setStateTop = set,
          onFocusChanged: (i) {
            selected.value = i;
            focuses.add(i);
          },
          onSelectedIndexChanged: (i) => selected.value = i,
        ),
      );

      // Swipe past halfway so the page is heading to channel b (index 1).
      final size = tester.getSize(find.byType(TabBarView));
      final center = tester.getCenter(find.byType(TabBarView));
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
      'programmatic selection change moves the visible page to that channel',
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
        // Only the first page is live before any navigation.
        expect(find.byKey(const Key('page-0')), findsOneWidget);
        expect(find.byKey(const Key('page-2')), findsNothing);

        // External navigation to channel c (index 2). The view pager must
        // follow: the page is actually built/moved to index 2.
        setStateTop(() => selected.value = 2);
        await tester.pump();
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('page-2')), findsOneWidget);
        expect(_pageDx(tester, 2).abs(), lessThan(2.0));
        // The parent already knew the target, so no redundant report fired.
        expect(selectedReports, isEmpty);
      },
    );

    testWidgets(
      'rebuild with unchanged selection after a programmatic switch is a no-op',
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

        setStateTop(() => selected.value = 1);
        await tester.pump();
        await tester.pumpAndSettle();
        expect(_pageDx(tester, 1).abs(), lessThan(2.0));

        // Extra unrelated rebuilds must not move the page or re-fire.
        selectedReports.clear();
        setStateTop(() {});
        await tester.pump();
        await tester.pumpAndSettle();

        expect(selectedReports, isEmpty);
        expect(_pageDx(tester, 1).abs(), lessThan(2.0));
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

    testWidgets('tap at the edge falls through to the page content', (
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

      final centerY = tester.getCenter(find.byType(TabBarView)).dy;
      await tester.tapAt(Offset(2, centerY));
      await tester.pump();

      // The edge overlay must not swallow the tap.
      expect(tapCount.value, 1);
    });

    testWidgets(
      'horizontal drag starting at the edge does not switch the channel',
      (WidgetTester tester) async {
        final selected = ValueNotifier<int>(0);

        await tester.pumpWidget(
          edgeHarness(
            selected,
            ValueNotifier<int>(0),
            onFocusChanged: (i) => selected.value = i,
            onSelectedIndexChanged: (i) => selected.value = i,
          ),
        );

        final size = tester.getSize(find.byType(TabBarView));
        final centerY = tester.getCenter(find.byType(TabBarView)).dy;
        // Drag leftwards from the right edge: unblocked, this would switch to
        // the next channel (index 1). Blocked, the page stays put.
        final start = Offset(size.width - 2, centerY);
        final end = Offset(size.width - 2 - size.width * 0.8, centerY);

        final gesture = await tester.startGesture(start);
        await gesture.moveBy(end - start);
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        // The channel did not switch; the OS back gesture keeps the edge.
        expect(selected.value, 0);
        expect(_pageDx(tester, 0).abs(), lessThan(2.0));
      },
    );
  });

  group('TabbedLayout fastSnap', () {
    // Swipes to the next channel with both physics modes; the toggle must not
    // change the switching behaviour, only the settle spring.
    for (final fastSnap in [true, false]) {
      testWidgets('swipe switches channels with fastSnap: $fastSnap', (
        WidgetTester tester,
      ) async {
        final selected = ValueNotifier<int>(0);

        await tester.pumpWidget(
          _harness(
            selected,
            captureSetState: (_) {},
            onFocusChanged: (i) => selected.value = i,
            onSelectedIndexChanged: (i) => selected.value = i,
            fastSnap: fastSnap,
          ),
        );

        final size = tester.getSize(find.byType(TabBarView));
        final center = tester.getCenter(find.byType(TabBarView));
        final gesture = await tester.startGesture(center);
        await gesture.moveBy(Offset(-size.width * 0.6, 0));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        expect(selected.value, 1);
        expect(_pageDx(tester, 1).abs(), lessThan(2.0));
      });
    }
  });
}
