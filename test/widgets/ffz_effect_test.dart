import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/widgets/ffz_effect.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('every effect paints and the clock stops when unmounted', (
    tester,
  ) async {
    final clock = FfzEffectClock.instance;
    // Each bit alone plus the combinations FFZ special-cases.
    final effects = [
      for (var bit = 1; bit <= FfzEffect.bounce; bit <<= 1) bit,
      FfzEffect.bounce | FfzEffect.flipY,
      FfzEffect.appear | FfzEffect.leave,
      FfzEffect.rotate | FfzEffect.slide,
      FfzEffect.hyperRed | FfzEffect.shake | FfzEffect.flipX,
      FfzEffect.cursed | FfzEffect.rainbow,
    ];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Wrap(
          children: [
            for (final fx in effects)
              SizedBox(
                width: 28,
                height: 28,
                child: FfzEffectBox(
                  effects: fx,
                  unit: 1,
                  child: const ColoredBox(color: Color(0xFF00FF00)),
                ),
              ),
          ],
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 37));
    }
    expect(tester.takeException(), isNull);
    expect(clock.debugListening, isTrue);

    await tester.pumpWidget(const SizedBox());
    expect(clock.debugListening, isFalse, reason: 'unmounted effects leak');
  });
}
