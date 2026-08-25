// Isolation suite for the mid-swipe desync bug: tap a tab, catch the
// animated flight with a finger, stop it part-way. After every settled
// gesture the focused channel (plain field, like HomeScreen._selectedChannel),
// the tab highlight (ValueNotifier, like _selectedTabIndex), and the visible
// resting page must all agree, with exactly one full commit for the channel
// actually displayed.
//
// Unlike tabbed_layout_test.dart's harness, this one replicates the REAL
// HomeScreen asymmetry: the focus callback mutates state WITHOUT setState,
// only the settle callback commits with setState, and both share the
// "already selected -> return" guard.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/widgets/tabbed_layout.dart';

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
      bestDx = dx;
      best = i;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(_HomeLike, StateSetter)> pumpHome(WidgetTester tester) async {
    final home = _HomeLike();
    late StateSetter capturedSet;
    await tester.pumpWidget(
      _homeLikeHarness(home, (realSet) => capturedSet = realSet),
    );
    await tester.pumpAndSettle();
    return (home, capturedSet);
  }

  group('mid-swipe desync isolation', () {
    testWidgets('R1: tap b, catch below half, hold, gentle release', (
      tester,
    ) async {
      final (home, _) = await pumpHome(tester);

      await _tapTab(tester, 'b');
      await tester.pump(const Duration(milliseconds: 40));
      final gesture = await _catchAndHold(tester, fraction: 0.40);
      await gesture.up();
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print('R1 rest=[${_restingDump(tester)}] ${_dump(home)}');
      expect(_restingPage(tester), 0, reason: 'page should settle back on a');
      expect(
        home.selectedChannel,
        'a',
        reason: 'focus must follow the visible page: ${_dump(home)}',
      );
      expect(
        home.tabIndex.value,
        0,
        reason: 'tab highlight must follow: ${_dump(home)}',
      );
      // Cancelling a tap must not have committed the cancelled channel.
      expect(
        home.commits['b'] ?? 0,
        0,
        reason:
            'phantom full commit for a cancelled channel '
            '${_dump(home)}',
      );
    });

    testWidgets('R2: tap b, catch above half, release forward', (tester) async {
      final (home, _) = await pumpHome(tester);

      await _tapTab(tester, 'b');
      await tester.pump(const Duration(milliseconds: 40));
      final gesture = await _catchAndHold(tester, fraction: 0.65);
      await gesture.up();
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print('R2 rest=[${_restingDump(tester)}] ${_dump(home)}');
      expect(_restingPage(tester), 1, reason: 'page should complete to b');
      expect(home.selectedChannel, 'b', reason: _dump(home));
      expect(home.tabIndex.value, 1, reason: _dump(home));
      expect(
        home.commits['b'] ?? 0,
        1,
        reason: 'exactly one full commit expected: ${_dump(home)}',
      );
    });

    testWidgets('R3: tap b, catch below half, unrelated rebuild mid-hold, '
        'release back', (tester) async {
      final (home, set) = await pumpHome(tester);

      await _tapTab(tester, 'b');
      await tester.pump(const Duration(milliseconds: 40));
      final gesture = await _catchAndHold(tester, fraction: 0.35, holds: 2);
      // Message-arrival stand-in: unrelated rebuild while the page is held.
      set(() {});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 66));
      await gesture.up();
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print('R3 rest=[${_restingDump(tester)}] ${_dump(home)}');
      expect(_restingPage(tester), 0, reason: 'held page was yanked');
      expect(
        home.selectedChannel,
        'a',
        reason: 'focus must follow the visible page: ${_dump(home)}',
      );
      expect(home.tabIndex.value, 0, reason: _dump(home));
    });

    testWidgets('R4: pure drag past half, pull back below, gentle release', (
      tester,
    ) async {
      final (home, _) = await pumpHome(tester);

      final size = tester.getSize(find.byType(PageView));
      final center = tester.getCenter(find.byType(PageView));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(Offset(-size.width * 0.7, 0));
      await tester.pump();
      // Pull back below the halfway point while still holding.
      await gesture.moveBy(Offset(size.width * 0.45, 0));
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print('R4 rest=[${_restingDump(tester)}] ${_dump(home)}');
      expect(_restingPage(tester), 0);
      expect(home.selectedChannel, 'a', reason: _dump(home));
      expect(home.tabIndex.value, 0, reason: _dump(home));
    });

    testWidgets('R5: tap c then quickly tap b, catch, release back', (
      tester,
    ) async {
      final (home, _) = await pumpHome(tester);

      await _tapTab(tester, 'c');
      await tester.pump(const Duration(milliseconds: 30));
      await _tapTab(tester, 'b');
      await tester.pump(const Duration(milliseconds: 30));
      final gesture = await _catchAndHold(tester, fraction: 0.38);
      await gesture.up();
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print('R5 rest=[${_restingDump(tester)}] ${_dump(home)}');
      expect(
        _restingPage(tester),
        _tabs.indexOf(home.selectedChannel),
        reason: 'visible page must rest on the focused channel',
      );
    });

    testWidgets('R6: tap non-adjacent c, catch mid-warp, release back', (
      tester,
    ) async {
      final (home, _) = await pumpHome(tester);

      await _tapTab(tester, 'c');
      await tester.pump(const Duration(milliseconds: 60));
      final gesture = await _catchAndHold(tester, fraction: 0.42);
      await gesture.up();
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print('R6 rest=[${_restingDump(tester)}] ${_dump(home)}');
      expect(
        _restingPage(tester),
        _tabs.indexOf(home.selectedChannel),
        reason: 'focused channel must match the visible page',
      );
      // The catch lands mid-way between a and b, so physics settles on b;
      // what matters is consistency and that the never-reached channel c
      // was never committed.
      expect(
        home.commits['c'] ?? 0,
        0,
        reason:
            'phantom commit for the unwrapped target c '
            '${_dump(home)}',
      );
      expect(
        home.tabIndex.value,
        _restingPage(tester),
        reason: 'tab highlight must match the visible page',
      );
    });

    testWidgets('R7: pure swipe past half, release forward, side effects '
        'run once', (tester) async {
      final (home, _) = await pumpHome(tester);

      final size = tester.getSize(find.byType(PageView));
      final center = tester.getCenter(find.byType(PageView));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(Offset(-size.width * 0.6, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print('R7 rest=[${_restingDump(tester)}] ${_dump(home)}');
      expect(_restingPage(tester), 1);
      expect(home.selectedChannel, 'b');
      expect(
        home.commits['b'] ?? 0,
        1,
        reason: 'the full commit must have run for b: ${_dump(home)}',
      );
    });

    testWidgets('R9: tap b, brief catch, early release while flight is '
        'still running (completion lands after the page settles)', (
      tester,
    ) async {
      final (home, _) = await pumpHome(tester);

      await _tapTab(tester, 'b');
      await tester.pump(const Duration(milliseconds: 40));
      // Catch and release almost immediately: the 300ms controller animation
      // is still in flight when the page has already settled back on a.
      final gesture = await _catchAndHold(tester, fraction: 0.35, holds: 1);
      await gesture.up();
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print('R9 rest=[${_restingDump(tester)}] ${_dump(home)}');
      expect(
        _restingPage(tester),
        _tabs.indexOf(home.selectedChannel),
        reason: 'focused channel must match the visible page',
      );
      expect(
        home.tabIndex.value,
        _tabs.indexOf(home.selectedChannel),
        reason:
            'tab highlight must match the visible page '
            '${_dump(home)}',
      );
    });

    testWidgets('R10: plain uninterrupted tap switches channel exactly once', (
      tester,
    ) async {
      final (home, _) = await pumpHome(tester);

      await _tapTab(tester, 'b');
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print('R10 rest=[${_restingDump(tester)}] ${_dump(home)}');
      expect(_restingPage(tester), 1, reason: 'page must land on b');
      expect(home.selectedChannel, 'b', reason: _dump(home));
      expect(home.tabIndex.value, 1, reason: _dump(home));
      expect(
        home.commits['b'] ?? 0,
        1,
        reason: 'exactly one bookkeeping run for b: ${_dump(home)}',
      );
    });

    testWidgets('R11: tapping the already-visible tab is a no-op', (
      tester,
    ) async {
      final (home, _) = await pumpHome(tester);

      await _tapTab(tester, 'a');
      await tester.pumpAndSettle();

      // A zero-distance jump must not strand a jump target: if it did, the
      // flyover suppression would stay on and later swipes would stop
      // committing entirely.
      await _swipeToNext(tester);
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print('R11 rest=[${_restingDump(tester)}] ${_dump(home)}');
      expect(
        _restingPage(tester),
        1,
        reason: 'swipe after tap must still work',
      );
      expect(home.selectedChannel, 'b', reason: _dump(home));
      expect(home.tabIndex.value, 1, reason: _dump(home));
      expect(home.commits['a'] ?? 0, 0, reason: _dump(home));
      expect(home.commits['b'] ?? 0, 1, reason: _dump(home));
    });

    testWidgets('R12: tap c then tap b without catching lands on b, '
        'never commits c', (tester) async {
      final (home, _) = await pumpHome(tester);

      await _tapTab(tester, 'c');
      await tester.pump(const Duration(milliseconds: 30));
      await _tapTab(tester, 'b');
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print('R12 rest=[${_restingDump(tester)}] ${_dump(home)}');
      expect(_restingPage(tester), 1, reason: 'retarget must land on b');
      expect(home.selectedChannel, 'b', reason: _dump(home));
      expect(
        home.commits['c'] ?? 0,
        0,
        reason: 'flyover channel must not be committed: ${_dump(home)}',
      );
      expect(home.commits['b'] ?? 0, 1, reason: _dump(home));
    });

    testWidgets('R13: grabbing a targeted jump and dragging back commits '
        'only where the finger lands', (tester) async {
      final (home, _) = await pumpHome(tester);

      await _tapTab(tester, 'c');
      await tester.pump(const Duration(milliseconds: 60));
      // Grab the a->c jump while it is flying and drag it back below half.
      final gesture = await _catchAndHold(tester, fraction: 0.30);
      await gesture.up();
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print('R13 rest=[${_restingDump(tester)}] ${_dump(home)}');
      final resting = _restingPage(tester);
      expect(
        resting,
        _tabs.indexOf(home.selectedChannel),
        reason: 'focus must match the visible page',
      );
      expect(
        home.commits['c'] ?? 0,
        0,
        reason: 'the grabbed jump target must not commit: ${_dump(home)}',
      );
    });

    testWidgets('R8: sweep catch fractions below half for persistent '
        'desync', (tester) async {
      final failures = <double, String>{};
      for (final fraction in [0.30, 0.36, 0.42, 0.48, 0.51]) {
        final (home, _) = await pumpHome(tester);
        await _tapTab(tester, 'b');
        await tester.pump(const Duration(milliseconds: 40));
        final gesture = await _catchAndHold(tester, fraction: fraction);
        await gesture.up();
        await tester.pumpAndSettle();

        final resting = _restingPage(tester);
        final focusedIdx = _tabs.indexOf(home.selectedChannel);
        final highlight = home.tabIndex.value;
        final ok = resting == focusedIdx && resting == highlight;
        if (!ok) {
          failures[fraction] =
              'rest=$resting [${_restingDump(tester)}] ${_dump(home)}';
        }
      }
      expect(failures, isEmpty, reason: 'desync fractions: $failures');
    });

    testWidgets('R14: half-drag round trip then tab tap must commit focus '
        '(stale-prop landing)', (tester) async {
      final (home, _) = await pumpHome(tester);

      // Start on b.
      await _tapTab(tester, 'b');
      await tester.pumpAndSettle();
      expect(home.selectedChannel, 'b');

      // Half-drag toward a: the crossing commits focus to a WITHOUT any
      // rebuild (the focus path never rebuilds), leaving the selectedIndex
      // prop stale at b's index. Release on a's side: the page settles on a.
      final size = tester.getSize(find.byType(PageView));
      final center = tester.getCenter(find.byType(PageView));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(Offset(size.width * 0.6, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(home.selectedChannel, 'a', reason: _dump(home));

      // Tap b's tab: the flight lands on b and focus must follow the view.
      // The landing report must not be skipped against the stale prop.
      await _tapTab(tester, 'b');
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print('R14 rest=[${_restingDump(tester)}] ${_dump(home)}');
      expect(_restingPage(tester), 1, reason: 'page must land on b');
      expect(
        home.selectedChannel,
        'b',
        reason: 'focus must catch up to the view: ${_dump(home)}',
      );
      expect(home.tabIndex.value, 1, reason: _dump(home));
      expect(
        home.commits['b'] ?? 0,
        2,
        reason: 'initial tap + landing bookkeeping: ${_dump(home)}',
      );
    });
  });
}
