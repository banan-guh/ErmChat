import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Spike tests verifying DraggableScrollableSheet edge-case behaviors
/// before refactoring the emote/thread/mentions panels onto it.
void main() {
  group('DraggableScrollableSheet snap behavior', () {
    testWidgets(
      'releasing at intermediate position snaps to 0 or max (two-state)',
      (tester) async {
        final controller = DraggableScrollableController();
        addTearDown(() => controller.dispose());

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox.expand(
                child: DraggableScrollableSheet(
                  controller: controller,
                  initialChildSize: 0,
                  minChildSize: 0,
                  maxChildSize: 1.0,
                  snap: true,
                  // snapSizes null → min/max implicitly included → [0, 1.0]
                  builder: (context, scrollController) => Container(
                    color: Colors.blue,
                    child: ListView(
                      controller: scrollController,
                      children: List.generate(
                        50,
                        (i) => ListTile(title: Text('item $i')),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Open the sheet programmatically.
        controller.animateTo(
          1.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        await tester.pumpAndSettle();
        expect(controller.size, closeTo(1.0, 0.01));

        // Drag down to an intermediate position (~40%).
        await tester.drag(find.text('item 0'), const Offset(0, 300));
        await tester.pumpAndSettle();

        // After releasing, the sheet must have snapped — not resting at an
        // arbitrary intermediate value.
        final size = controller.size;
        final snapped = (size - 0.0).abs() < 0.05 || (size - 1.0).abs() < 0.05;
        expect(
          snapped,
          isTrue,
          reason:
              'Sheet at size $size should have snapped to 0 or 1.0, not rested '
              'at an intermediate value.',
        );
      },
    );

    testWidgets(
      'changing maxChildSize 0.55->1.0 while sheet open keeps snap binary',
      (tester) async {
        final controller = DraggableScrollableController();
        final maxChildSize = ValueNotifier<double>(0.55);
        addTearDown(() {
          controller.dispose();
          maxChildSize.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<double>(
                valueListenable: maxChildSize,
                builder: (context, maxVal, child) => SizedBox.expand(
                  child: DraggableScrollableSheet(
                    controller: controller,
                    initialChildSize: 0,
                    minChildSize: 0,
                    maxChildSize: maxVal,
                    snap: true,
                    // snapSizes null → implicit [0, maxVal]
                    builder: (context, scrollController) => Container(
                      color: Colors.blue,
                      child: ListView(
                        controller: scrollController,
                        children: List.generate(
                          50,
                          (i) => ListTile(title: Text('item $i')),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Open at max=0.55.
        controller.animateTo(
          0.55,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        await tester.pumpAndSettle();
        expect(controller.size, closeTo(0.55, 0.01));

        // Simulate keyboard opening → maxChildSize jumps to 1.0.
        maxChildSize.value = 1.0;
        await tester.pumpAndSettle();

        // Drag to a mid position and release — must still snap to 0 or 1.0.
        await tester.drag(find.text('item 0'), const Offset(0, 400));
        await tester.pumpAndSettle();

        final size = controller.size;
        final snapped = (size - 0.0).abs() < 0.05 || (size - 1.0).abs() < 0.05;
        expect(
          snapped,
          isTrue,
          reason:
              'After maxChildSize change, snap should still be binary '
              '(got size $size).',
        );
      },
    );
  });

  group('DraggableScrollableSheet + TabBarView controller wiring', () {
    testWidgets(
      'switching active tab reassigns sheet controller without exception',
      (tester) async {
        final controller = DraggableScrollableController();
        addTearDown(() => controller.dispose());

        int activeTab = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox.expand(
                child: StatefulBuilder(
                  builder: (context, setState) => DraggableScrollableSheet(
                    controller: controller,
                    initialChildSize: 1.0,
                    minChildSize: 0,
                    maxChildSize: 1.0,
                    snap: true,
                    builder: (context, scrollController) {
                      return Container(
                        color: Colors.white,
                        child: Column(
                          children: [
                            Row(
                              children: [
                                TextButton(
                                  onPressed: () =>
                                      setState(() => activeTab = 0),
                                  child: const Text('tab0'),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      setState(() => activeTab = 1),
                                  child: const Text('tab1'),
                                ),
                              ],
                            ),
                            Expanded(
                              child: IndexedStack(
                                index: activeTab,
                                children: [
                                  ListView(
                                    controller: activeTab == 0
                                        ? scrollController
                                        : null,
                                    children: List.generate(
                                      50,
                                      (i) => ListTile(title: Text('a$i')),
                                    ),
                                  ),
                                  ListView(
                                    controller: activeTab == 1
                                        ? scrollController
                                        : null,
                                    children: List.generate(
                                      50,
                                      (i) => ListTile(title: Text('b$i')),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Sheet starts open at max (1.0). Switch to tab1, then drag list b.
        await tester.tap(find.text('tab1'));
        await tester.pumpAndSettle();

        // Now list b holds the controller; dragging it should work.
        await tester.drag(find.text('b0'), const Offset(0, 100));
        await tester.pumpAndSettle();

        // No exception thrown — test passes.
        expect(controller.size, lessThanOrEqualTo(1.0));
      },
    );
  });
}
