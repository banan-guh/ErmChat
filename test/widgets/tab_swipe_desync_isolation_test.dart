import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/widgets/tabbed_layout.dart';

// Isolation suite for the mid-swipe desync bug: tap a tab, catch the
// animated flight with a finger, stop it part-way. A tab tap commits its
// channel immediately (the flight is just travel); every other focus change
// commits as it crosses. After every settled gesture the focused channel
// (plain field, like HomeScreen._selectedChannel), the tab highlight
// (ValueNotifier, like _selectedTabIndex), and the visible resting page must
// all agree.
//
// Unlike tabbed_layout_test.dart's harness, this one replicates the REAL
// HomeScreen asymmetry: the focus callback mutates state WITHOUT setState,
// only the settle callback commits with setState, and both share the
// "already selected -> return" guard.
const _tabs = ['a', 'b', 'c'];

class _HomeLike {
  String selectedChannel = 'a';
  final tabIndex = ValueNotifier<int>(0);

  /// Full-commit counter per channel (settle path only).
  final commits = <String, int>{};

  /// Every channel-change event in arrival order, tagged by path.
  final log = <String>[];

  void onFocusChanged(int i) {
    final ch = _tabs[i];
    if (selectedChannel == ch) return;
    selectedChannel = ch;
    tabIndex.value = i;
    // Mirrors the unified HomeScreen commit: whichever path lands first owns
    // the bookkeeping, so both paths count.
    commits[ch] = (commits[ch] ?? 0) + 1;
    log.add('focus:$ch');
  }

  /// Settle path: mutates state first (like HomeScreen), returns whether the
  /// caller needs to setState.
  bool onSelectedIndexChanged(int i) {
    final ch = _tabs[i];
    if (selectedChannel == ch) return false;
    selectedChannel = ch;
    tabIndex.value = i;
    commits[ch] = (commits[ch] ?? 0) + 1;
    log.add('select:$ch');
    return true;
  }
}

Widget _homeLikeHarness(
  _HomeLike home,
  void Function(StateSetter) captureSetState,
) {
  return MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder: (context, set) {
          captureSetState(set);
          return TabbedLayout(
            key: const Key('tl'),
            tabs: _tabs,
            selectedIndex: _tabs.indexOf(home.selectedChannel),
            focusOnHalfDrag: true,
            fastSnap: true,
            onFocusChanged: home.onFocusChanged,
            onSelectedIndexChanged: (i) {
              // Commit mutates first, then rebuild - mirroring HomeScreen's
              // setState-wrapped field write.
              if (home.onSelectedIndexChanged(i)) set(() {});
            },
            pageBuilder: (_, i) => Container(
              key: Key('page-$i'),
              alignment: Alignment.center,
              child: Text(_tabs[i]),
            ),
          );
        },
      ),
    ),
  );
}

/// Which channel's page is visibly at rest (dx closest to zero among built
/// pages). Returns -1 when nothing resolves.
int _restingPage(WidgetTester tester) {
  var best = -1;
  var bestDx = double.infinity;
  for (var i = 0; i < _tabs.length; i++) {
    final key = find.byKey(Key('page-$i'));
    if (tester.widgetList(key).isEmpty) continue;
    final dx = tester.getTopLeft(key).dx.abs();
    if (dx < bestDx) {
      best = i;
      bestDx = dx;
    }
  }
  return best;
}

String _restingDump(WidgetTester tester) {
  final parts = <String>[];
  for (var i = 0; i < _tabs.length; i++) {
    final key = find.byKey(Key('page-$i'));
    final built = tester.widgetList(key).isNotEmpty;
    final dx = built ? tester.getTopLeft(key).dx.toStringAsFixed(1) : '-';
    parts.add('$i:$dx');
  }
  return parts.join(' ');
}

Future<void> _tapTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(TabBar), matching: find.text(label)),
  );
}

/// Catches an in-flight tab animation with a finger, then drags the page to
/// [fraction] of the way toward the next channel and holds for [holds] frames.
/// Touching down mid-flight replaces the page's driven animation with a drag,
/// exactly like a finger catching the swipe.
Future<TestGesture> _catchAndHold(
  WidgetTester tester, {
  required double fraction,
  int holds = 6,
}) async {
  final size = tester.getSize(find.byType(PageView));
  final center = tester.getCenter(find.byType(PageView));
  final gesture = await tester.startGesture(center);
  // Claim the position as a drag (stops the driven flight), then pull to the
  // target fraction. Negative dx = toward the next channel.
  await gesture.moveBy(const Offset(-8, 0));
  await tester.pump();
  await gesture.moveBy(Offset(-size.width * fraction, 0));
  await tester.pump();
  for (var i = 0; i < holds; i++) {
    await tester.pump(const Duration(milliseconds: 33));
  }
  return gesture;
}

String _dump(_HomeLike home) =>
    'log=[${home.log.join(", ")}] commits=${home.commits} '
    'focused=${home.selectedChannel} tabIndex=${home.tabIndex.value}';

/// Plain finger swipe from the current page toward the next channel.
Future<void> _swipeToNext(WidgetTester tester) async {
  final size = tester.getSize(find.byType(PageView));
  final center = tester.getCenter(find.byType(PageView));
  final gesture = await tester.startGesture(center);
  await gesture.moveBy(Offset(-size.width * 0.6, 0));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Drags [fraction] of the way toward the next channel, then has the pointer
/// stolen by the OS (ACTION_CANCEL): back gesture, notification shade, app
/// switcher. The funnel sees a drag start and scroll updates, then a
/// cancellation instead of a lift.
///
/// This is the foregrounding-shaped input: steals overwhelmingly happen
/// during OS transitions around backgrounding.
Future<void> _stealMidSwipe(
  WidgetTester tester, {
  required double fraction,
}) async {
  final size = tester.getSize(find.byType(PageView));
  final center = tester.getCenter(find.byType(PageView));
  final gesture = await tester.startGesture(center);
  await gesture.moveBy(const Offset(-8, 0));
  await tester.pump();
  await gesture.moveBy(Offset(-size.width * fraction, 0));
  await tester.pump();
  await gesture.cancel();
}

/// Stands in for HomeScreen._navigateToChannel -> _commitChannelSelection
/// (rebuild: true): mutate the selection fields first, then rebuild.
void _externalNavigate(_HomeLike home, StateSetter set, int index) {
  home.selectedChannel = _tabs[index];
  home.tabIndex.value = index;
  set(() {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mid-swipe desync isolation scenarios', (tester) async {
    Future<(_HomeLike, StateSetter)> pumpHome() async {
      final home = _HomeLike();
      late StateSetter capturedSet;
      await tester.pumpWidget(
        _homeLikeHarness(home, (realSet) => capturedSet = realSet),
      );
      await tester.pumpAndSettle();
      return (home, capturedSet);
    }

    final scenarios = <String, Future<void> Function()>{
      'R2: tap b, catch above half, release forward': () async {
        final (home, _) = await pumpHome();
        await _tapTab(tester, 'b');
        await tester.pump(const Duration(milliseconds: 40));
        final gesture = await _catchAndHold(tester, fraction: 0.65);
        await gesture.up();
        await tester.pumpAndSettle();

        expect(_restingPage(tester), 1, reason: 'page should complete to b');
        expect(home.selectedChannel, 'b', reason: _dump(home));
        expect(home.tabIndex.value, 1, reason: _dump(home));
        expect(home.commits['b'] ?? 0, 2, reason: _dump(home));
        expect(home.commits['a'] ?? 0, 1, reason: _dump(home));
      },
      'R4: pure drag past half, pull back below, gentle release': () async {
        final (home, _) = await pumpHome();
        final size = tester.getSize(find.byType(PageView));
        final center = tester.getCenter(find.byType(PageView));
        final gesture = await tester.startGesture(center);
        await gesture.moveBy(Offset(-size.width * 0.7, 0));
        await tester.pump();
        await gesture.moveBy(Offset(size.width * 0.45, 0));
        await tester.pump();
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 33));
        }
        await gesture.up();
        await tester.pumpAndSettle();

        expect(_restingPage(tester), 0);
        expect(home.selectedChannel, 'a', reason: _dump(home));
        expect(home.tabIndex.value, 0, reason: _dump(home));
      },
      'R7: pure swipe and stolen swipe commit once': () async {
        {
          final (home, _) = await pumpHome();
          final size = tester.getSize(find.byType(PageView));
          final center = tester.getCenter(find.byType(PageView));
          final gesture = await tester.startGesture(center);
          await gesture.moveBy(Offset(-size.width * 0.6, 0));
          await tester.pump();
          await gesture.up();
          await tester.pumpAndSettle();
          expect(_restingPage(tester), 1);
          expect(home.selectedChannel, 'b');
          expect(home.commits['b'] ?? 0, 1, reason: _dump(home));
        }
        {
          final (home, _) = await pumpHome();
          await _stealMidSwipe(tester, fraction: 0.30);
          await tester.pumpAndSettle();
          await _swipeToNext(tester);
          expect(_restingPage(tester), 1, reason: _restingDump(tester));
          expect(home.selectedChannel, 'b', reason: _dump(home));
          expect(home.tabIndex.value, 1, reason: _dump(home));
          expect(home.commits['b'] ?? 0, 1, reason: _dump(home));
        }
      },
      'R11: tapping the visible tab is a no-op': () async {
        final (home, _) = await pumpHome();
        await _tapTab(tester, 'a');
        await tester.pumpAndSettle();
        await _swipeToNext(tester);
        await tester.pumpAndSettle();

        expect(_restingPage(tester), 1, reason: 'swipe after tap must work');
        expect(home.selectedChannel, 'b', reason: _dump(home));
        expect(home.tabIndex.value, 1, reason: _dump(home));
        expect(home.commits['a'] ?? 0, 0, reason: _dump(home));
        expect(home.commits['b'] ?? 0, 1, reason: _dump(home));
      },
      'R12: tap c then b without catching lands on b': () async {
        final (home, _) = await pumpHome();
        await _tapTab(tester, 'c');
        await tester.pump(const Duration(milliseconds: 30));
        await _tapTab(tester, 'b');
        await tester.pumpAndSettle();

        expect(_restingPage(tester), 1, reason: 'retarget must land on b');
        expect(home.selectedChannel, 'b', reason: _dump(home));
        expect(home.commits['c'] ?? 0, 1, reason: _dump(home));
        expect(home.commits['b'] ?? 0, 1, reason: _dump(home));
      },
      'R13: caught targeted jump lands on the finger side': () async {
        final (home, _) = await pumpHome();
        await _tapTab(tester, 'c');
        await tester.pump(const Duration(milliseconds: 60));
        final gesture = await _catchAndHold(tester, fraction: 0.30);
        await gesture.up();
        await tester.pumpAndSettle();

        expect(_restingPage(tester), 0, reason: _restingDump(tester));
        expect(home.commits['c'] ?? 0, 1, reason: _dump(home));
        expect(home.commits['a'] ?? 0, 1, reason: _dump(home));
      },
      'R14: stale-prop landing still commits focus': () async {
        final (home, _) = await pumpHome();
        await _tapTab(tester, 'b');
        await tester.pumpAndSettle();
        expect(home.selectedChannel, 'b');

        final size = tester.getSize(find.byType(PageView));
        final center = tester.getCenter(find.byType(PageView));
        final gesture = await tester.startGesture(center);
        await gesture.moveBy(Offset(size.width * 0.6, 0));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(home.selectedChannel, 'a', reason: _dump(home));

        await _tapTab(tester, 'b');
        await tester.pumpAndSettle();

        expect(_restingPage(tester), 1, reason: 'page must land on b');
        expect(home.selectedChannel, 'b', reason: _dump(home));
        expect(home.tabIndex.value, 1, reason: _dump(home));
        expect(home.commits['b'] ?? 0, 2, reason: _dump(home));
      },
      'pointer steals above and below half keep navigation working': () async {
        for (final fraction in [0.70, 0.30]) {
          final (home, set) = await pumpHome();
          await _stealMidSwipe(tester, fraction: fraction);
          await tester.pumpAndSettle();
          expect(_restingPage(tester), fraction > 0.5 ? 1 : 0);
          expect(home.selectedChannel, fraction > 0.5 ? 'b' : 'a');
          expect(home.tabIndex.value, fraction > 0.5 ? 1 : 0);
          _externalNavigate(home, set, 2);
          await tester.pumpAndSettle();
          expect(_restingPage(tester), 2, reason: _restingDump(tester));
          expect(home.selectedChannel, 'c', reason: _dump(home));
          expect(home.tabIndex.value, 2, reason: _dump(home));
        }
      },
    };

    for (final entry in scenarios.entries) {
      await entry.value();
    }
  });
}
