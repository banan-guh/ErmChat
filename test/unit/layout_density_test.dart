import 'package:ermchat/util/layout_density.dart';
import 'package:ermchat/util/prefs.dart';
import 'package:ermchat/util/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('resolveCompact', () {
    test('auto never flips on rotation', () {
      for (final size in const [Size(375, 667), Size(390, 844)]) {
        expect(
          resolveCompact(LayoutDensity.auto, size.flipped),
          resolveCompact(LayoutDensity.auto, size),
        );
      }
    });
  });

  group('layoutDensity pref', () {
    test('unknown stored value falls back to auto', () async {
      SharedPreferences.setMockInitialValues({'layout_density': 'huge'});
      await Prefs.load();
      expect(Settings.layoutDensity.value, LayoutDensity.auto);
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
