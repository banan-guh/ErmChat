import 'package:ermchat/widgets/eased_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('progress eases up, jumps down, and holds once cleared', (
    tester,
  ) async {
    final progress = ValueNotifier<double?>(null);
    addTearDown(progress.dispose);
    late double shown;
    late bool active;
    await tester.pumpWidget(
      EasedProgress(
        progress: progress,
        builder: (_, value, isActive) {
          shown = value;
          active = isActive;
          return const SizedBox();
        },
      ),
    );

    progress.value = 0.5;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(shown, inExclusiveRange(0, 0.5), reason: 'a rise eases');
    await tester.pump(const Duration(seconds: 1));
    expect(shown, 0.5);
    expect(active, isTrue);

    progress.value = 1;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    progress.value = null;
    await tester.pump();
    expect(shown, 1, reason: 'a finished run holds full while it fades');
    expect(active, isFalse);

    progress.value = 0;
    await tester.pump();
    expect(shown, 0, reason: 'a new run starts over at once, not unwinding');
  });
}
