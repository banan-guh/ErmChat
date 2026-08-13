import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:ermchat/main.dart';
import 'package:ermchat/widgets/tabbed_layout.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> joinChannel(WidgetTester tester, String name) async {
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, name);
    await tester.tap(find.text('Join').last);
    await tester.pumpAndSettle();
    await tester.pump();
  }

  Future<void> tapChannel(WidgetTester tester, String channel) async {
    final barText = find.text(channel).first;
    await tester.ensureVisible(barText);
    await tester.pump();
    await tester.tap(barText);
    await tester.pumpAndSettle();
    await tester.pump();
  }

  group('Channel bar', () {
    testWidgets('is absent when no channels are joined', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      expect(find.byType(TabBar), findsNothing);
    });

    testWidgets('renders channel name after joining', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'xqc');

      expect(find.text('xqc'), findsOneWidget);
    });

    testWidgets('first channel is selected by default', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'xqc');

      final text = tester.widget<Text>(find.text('xqc'));
      expect(text.style?.fontWeight, FontWeight.w600);
    });

    testWidgets('tapping a channel selects it', (WidgetTester tester) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'a');
      await joinChannel(tester, 'b');

      await tapChannel(tester, 'b');

      expect(
        tester.widget<Text>(find.text('b')).style?.fontWeight,
        FontWeight.w600,
      );
      expect(
        tester.widget<Text>(find.text('a')).style?.fontWeight,
        FontWeight.normal,
      );
    });

    testWidgets('tab bar has an underline indicator', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'xqc');

      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabBar.indicator, isNotNull);
    });

    testWidgets('selected channel text uses primary color', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'xqc');

      final text = tester.widget<Text>(find.text('xqc'));
      expect(text.style?.color, isNotNull);
    });

    testWidgets('channel bar disappears when last channel is removed', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'xqc');

      await tester.tap(find.byIcon(Icons.settings));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Channels'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.remove_circle_outline));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('xqc'), findsNothing);
      expect(find.byType(TabBar), findsNothing);
    });

    testWidgets('multiple channels render in the bar', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'c1');
      await joinChannel(tester, 'c2');
      await joinChannel(tester, 'c3');

      expect(find.text('c1'), findsOneWidget);
      expect(find.text('c2'), findsOneWidget);
      expect(find.text('c3'), findsOneWidget);
    });

    testWidgets('unselected channel has normal font weight', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'a');
      await joinChannel(tester, 'b');

      expect(
        tester.widget<Text>(find.text('b')).style?.fontWeight,
        FontWeight.w600,
      );
      expect(
        tester.widget<Text>(find.text('a')).style?.fontWeight,
        FontWeight.normal,
      );
    });
  });

  group('Channel focus on swipe', () {
    testWidgets('swiping past halfway switches focus before settle', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();
      await joinChannel(tester, 'a');
      await joinChannel(tester, 'b');
      await tapChannel(tester, 'a');

      final size = tester.getSize(find.byType(TabBarView));
      final center = tester.getCenter(find.byType(TabBarView));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(-1, 0));
      await tester.pump();
      await gesture.moveBy(Offset(-size.width * 0.55, 0));
      await tester.pump();
      // Don't release — verify focus switched mid-drag
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byType(TabBar),
                matching: find.text('b'),
              ),
            )
            .style
            ?.fontWeight,
        FontWeight.w600,
      );
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byType(TabBar),
                matching: find.text('a'),
              ),
            )
            .style
            ?.fontWeight,
        FontWeight.normal,
      );

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('dragging under halfway keeps focus unchanged', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();
      await joinChannel(tester, 'a');
      await joinChannel(tester, 'b');
      await tapChannel(tester, 'a');

      final size = tester.getSize(find.byType(TabBarView));
      final center = tester.getCenter(find.byType(TabBarView));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(-1, 0));
      await tester.pump();
      await gesture.moveBy(Offset(-size.width * 0.45, 0)); // under 50%
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byType(TabBar),
                matching: find.text('a'),
              ),
            )
            .style
            ?.fontWeight,
        FontWeight.w600,
      );
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byType(TabBar),
                matching: find.text('b'),
              ),
            )
            .style
            ?.fontWeight,
        FontWeight.normal,
      );
    });

    testWidgets('crossing then returning before release restores focus', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();
      await joinChannel(tester, 'a');
      await joinChannel(tester, 'b');
      await tapChannel(tester, 'a');

      final size = tester.getSize(find.byType(TabBarView));
      final center = tester.getCenter(find.byType(TabBarView));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(-1, 0));
      await tester.pump();
      // Cross 50%
      await gesture.moveBy(Offset(-size.width * 0.6, 0));
      await tester.pump();
      // Return below 50%
      await gesture.moveBy(Offset(size.width * 0.3, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byType(TabBar),
                matching: find.text('a'),
              ),
            )
            .style
            ?.fontWeight,
        FontWeight.w600,
      );
    });
  });

  group('Channel switch races', () {
    Future<void> pumpHarness(
      WidgetTester tester, {
      required ValueNotifier<int> selected,
      required List<int> changedLog,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: selected,
              builder: (_, idx, _) => TabbedLayout(
                tabs: const ['a', 'b', 'c'],
                selectedIndex: idx,
                onSelectedIndexChanged: (i) {
                  changedLog.add(i);
                  selected.value = i;
                },
                focusOnHalfDrag: true,
                pageBuilder: (_, i) => Center(child: Text('PAGE $i')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    String? visiblePage(WidgetTester tester) {
      for (var i = 0; i < 3; i++) {
        if (find.text('PAGE $i').hitTestable().evaluate().isNotEmpty) {
          return '$i';
        }
      }
      return null;
    }

    testWidgets(
      'tapping back while a switch is animating lands on the tapped channel',
      (WidgetTester tester) async {
        final selected = ValueNotifier<int>(0);
        final changedLog = <int>[];
        await pumpHarness(tester, selected: selected, changedLog: changedLog);

        // Tap 'c' (index 2), then immediately tap 'a' (index 0) before the
        // switch animation finishes.
        await tester.tap(find.text('c'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text('a'));
        await tester.pumpAndSettle();
        await tester.pump();

        // The viewport must end on the last-tapped channel ('a' = page 0),
        // not stay stuck on 'c' (page 2) while the selection moved to 'a'.
        expect(visiblePage(tester), '0');
        expect(find.text('PAGE 2').hitTestable(), findsNothing);
      },
    );

    testWidgets(
      'rapid forward then reverse taps settle on the final tapped channel',
      (WidgetTester tester) async {
        final selected = ValueNotifier<int>(0);
        final changedLog = <int>[];
        await pumpHarness(tester, selected: selected, changedLog: changedLog);

        await tester.tap(find.text('c'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text('b'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text('c'));
        await tester.pumpAndSettle();
        await tester.pump();

        expect(visiblePage(tester), '2');
        expect(find.text('PAGE 0').hitTestable(), findsNothing);
      },
    );
  });
}
