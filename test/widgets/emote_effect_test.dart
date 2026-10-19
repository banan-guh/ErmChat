import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/widgets/emote_effect.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('every effect paints and the clock stops when unmounted', (
    tester,
  ) async {
    final clock = EmoteEffectClock.instance;
    // Each bit alone plus the combinations FFZ special-cases.
    final effects = [
      for (var bit = 1; bit <= FfzEffect.bounce; bit <<= 1) bit,
      FfzEffect.bounce | FfzEffect.flipY,
      FfzEffect.appear | FfzEffect.leave,
      FfzEffect.rotate | FfzEffect.slide,
      FfzEffect.hyperRed | FfzEffect.shake | FfzEffect.flipX,
      FfzEffect.cursed | FfzEffect.rainbow,
      for (var bit = BttvEffect.flipX; bit <= BttvEffect.shake; bit <<= 1) bit,
      BttvEffect.party | BttvEffect.shake | BttvEffect.cursed,
      BttvEffect.rotateLeft | FfzEffect.flipX,
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
                child: EmoteEffectBox(
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

    // A frozen row (TickerMode off) must not keep the shared clock running.
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: TickerMode(
          enabled: false,
          child: SizedBox(
            width: 28,
            height: 28,
            child: EmoteEffectBox(
              effects: FfzEffect.bounce,
              unit: 1,
              child: ColoredBox(color: Color(0xFF00FF00)),
            ),
          ),
        ),
      ),
    );
    expect(clock.debugListening, isFalse, reason: 'frozen effect ticks');

    await tester.pumpWidget(const SizedBox());
    expect(clock.debugListening, isFalse, reason: 'unmounted effects leak');
  });
}
