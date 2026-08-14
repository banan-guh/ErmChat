import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import '../helpers/gif_fixture.dart';

/// Documents the engine's animated-codec behavior on fully-transparent frames
/// (the emote nuke the renderer migration works around).
///
/// Findings at the time of writing (Flutter 3.44.9, Skia via flutter_tester):
/// - `codec.getNextFrame()` does NOT throw on fully-transparent frames.
/// - Transparent pixels composite over the previous frame (disposal 0), so a
///   transparent frame renders as whatever was underneath, fully opaque.
///
/// If either assertion fails, the engine changed and the EmoteImage migration
/// rationale (animated emotes bypass the engine codec) needs revisiting.
void main() {
  group('engine animated-codec behavior on transparent frames', () {
    test('transparent frames decode without error', () async {
      final codec = await ui.instantiateImageCodec(
        buildTestGif(
          pixels: const [0, 1, 0],
          transparent: const [false, true, false],
          delays: const [10, 10, 10],
        ),
      );
      expect(codec.frameCount, greaterThanOrEqualTo(3));
      final frames = <ui.FrameInfo?>[];
      for (var i = 0; i < codec.frameCount; i++) {
        frames.add(await codec.getNextFrame());
      }
      expect(frames, hasLength(codec.frameCount));
      expect(frames.every((f) => f != null), isTrue);
    });

    test('transparent pixels composite over the previous frame', () async {
      final codec = await ui.instantiateImageCodec(
        buildTestGif(
          pixels: const [0, 1],
          transparent: const [false, true],
          delays: const [10, 10],
        ),
      );
      await codec.getNextFrame();
      final transparent = await codec.getNextFrame();
      final data = await transparent.image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      expect(data, isNotNull);
      // The transparent pixel leaves frame 0's red showing through (opaque).
      expect(data!.getUint8(0), 255); // r
      expect(data.getUint8(1), 0); // g
      expect(data.getUint8(2), 0); // b
      expect(data.getUint8(3), 255); // a
    });
  });
}
