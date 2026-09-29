import 'package:ermchat/util/layout_density.dart';
import 'package:ermchat/util/prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('resolveCompact', () {
    test('auto goes compact on short phones only', () {
      const devices = {
        'iPhone 8': Size(375, 667),
        'small Android': Size(360, 720),
        'iPhone mini': Size(375, 812),
        'S24 FE': Size(384, 832),
        'iPhone 13': Size(390, 844),
      };
      final compact = {
        for (final e in devices.entries)
          e.key: resolveCompact(LayoutDensity.auto, e.value),
      };
      expect(compact, {
        'iPhone 8': true,
        'small Android': true,
        'iPhone mini': false,
        'S24 FE': false,
        'iPhone 13': false,
      });
    });

    test('auto never flips on rotation', () {
      for (final size in const [Size(375, 667), Size(390, 844)]) {
        expect(
          resolveCompact(LayoutDensity.auto, size.flipped),
          resolveCompact(LayoutDensity.auto, size),
        );
      }
    });

    test('manual choices ignore the screen', () {
      const small = Size(375, 667);
      const big = Size(412, 915);
      expect(resolveCompact(LayoutDensity.compact, big), isTrue);
      expect(resolveCompact(LayoutDensity.full, small), isFalse);
    });
  });

  group('layoutDensity pref', () {
    test('defaults to auto and round-trips', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await Prefs.load();
      expect(prefs.layoutDensity, LayoutDensity.auto);
      await prefs.setLayoutDensity(LayoutDensity.compact);
      expect(prefs.layoutDensity, LayoutDensity.compact);
    });

    test('unknown stored value falls back to auto', () async {
      SharedPreferences.setMockInitialValues({'layout_density': 'huge'});
      expect((await Prefs.load()).layoutDensity, LayoutDensity.auto);
    });
  });

  group('compactLayoutRoot', () {
    Widget app(LayoutDensity density) => MaterialApp(
      builder: (context, child) =>
          compactLayoutRoot(context, density: density, child: child!),
      home: const _Counter(),
    );

    testWidgets('flipping density never moves the app subtree', (tester) async {
      _CounterState.reattaches = 0;
      await tester.pumpWidget(app(LayoutDensity.full));
      await tester.tap(find.byType(TextButton));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      expect(isCompactLayout(tester.element(find.byType(_Counter))), isFalse);

      await tester.pumpWidget(app(LayoutDensity.compact));
      final ctx = tester.element(find.byType(_Counter));
      expect(find.text('1'), findsOneWidget);
      expect(isCompactLayout(ctx), isTrue);
      expect(Theme.of(ctx).visualDensity, VisualDensity.compact);

      await tester.pumpWidget(app(LayoutDensity.full));
      expect(find.text('1'), findsOneWidget);
      expect(isCompactLayout(tester.element(find.byType(_Counter))), isFalse);
      expect(_CounterState.reattaches, 0);
    });

    testWidgets('auto follows the screen', (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.view.physicalSize = const Size(375, 667);
      await tester.pumpWidget(app(LayoutDensity.auto));
      expect(isCompactLayout(tester.element(find.byType(_Counter))), isTrue);

      tester.view.physicalSize = const Size(667, 375);
      await tester.pump();
      expect(isCompactLayout(tester.element(find.byType(_Counter))), isTrue);

      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
      expect(isCompactLayout(tester.element(find.byType(_Counter))), isFalse);
    });
  });
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  // A GlobalKey move reattaches the subtree (activate) even though state
  // survives, and a reattach can drop focus and the keyboard.
  static int reattaches = 0;
  int _n = 0;

  @override
  void activate() {
    super.activate();
    reattaches++;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(onPressed: () => setState(() => _n++), child: Text('$_n')),
  );
}
