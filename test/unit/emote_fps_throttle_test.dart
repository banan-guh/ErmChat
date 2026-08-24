import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ermchat/widgets/emote_image.dart';
import 'package:ermchat/widgets/emote_image_provider.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _animatedWebpBytes() => Uint8List.fromList([
  0x52, 0x49, 0x46, 0x46, // RIFF
  0, 0, 0, 0,
  0x57, 0x45, 0x42, 0x50, // WEBP
  0x41, 0x4E, 0x4D, 0x46, // ANMF
  0, 0, 0, 0,
]);

Future<ui.Image> _solidImage(int r, int g, int b) {
  final bytes = Uint8List(4 * 2 * 2);
  for (var i = 0; i < bytes.length; i += 4) {
    bytes[i] = r;
    bytes[i + 1] = g;
    bytes[i + 2] = b;
    bytes[i + 3] = 255;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    bytes,
    2,
    2,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    EmoteUrlProvider.fpsCap = 30;
    EmoteUrlProvider.adaptiveThrottle = true;
  });

  tearDown(() {
    EmoteUrlProvider.debugFetchOverride = null;
    EmoteUrlProvider.debugDecodeOverride = null;
  });

  group('autoCapFor', () {
    test('keeps the user cap up to the soft limit', () {
      expect(EmoteUrlProvider.autoCapFor(0, 30), 30);
      expect(EmoteUrlProvider.autoCapFor(60, 30), 30);
      expect(EmoteUrlProvider.autoCapFor(60, 60), 60);
    });

    test('halves between soft and hard limits', () {
      expect(EmoteUrlProvider.autoCapFor(61, 30), 15);
      expect(EmoteUrlProvider.autoCapFor(150, 30), 15);
    });

    test('quarters between hard and stop limits', () {
      expect(EmoteUrlProvider.autoCapFor(151, 30), 7);
      expect(EmoteUrlProvider.autoCapFor(300, 30), 7);
    });

    test('pauses above the stop limit', () {
      expect(EmoteUrlProvider.autoCapFor(301, 30), 0);
      expect(EmoteUrlProvider.autoCapFor(1000, 60), 0);
    });

    test('floors at one frame until the stop tier', () {
      expect(EmoteUrlProvider.autoCapFor(61, 1), 1);
      expect(EmoteUrlProvider.autoCapFor(151, 2), 1);
    });

    test('a user cap of zero stays zero at every tier', () {
      expect(EmoteUrlProvider.autoCapFor(10, 0), 0);
      expect(EmoteUrlProvider.autoCapFor(500, 0), 0);
    });
  });

  testWidgets('visible animated load lowers live completers through the '
      'tiers', (tester) async {
    final red = await tester.runAsync(() => _solidImage(255, 0, 0));
    final blue = await tester.runAsync(() => _solidImage(0, 0, 255));
    EmoteUrlProvider.debugFetchOverride = (_) async => _animatedWebpBytes();
    EmoteUrlProvider.debugDecodeOverride = (bytes) async => EmoteFrameData(
      frames: [red!, blue!],
      durations: const [Duration(milliseconds: 80), Duration(milliseconds: 80)],
    );

    final streams = <ImageStream>[];
    final listeners = <ImageStreamListener>[];
    const firstUrl = 'https://throttle.test/0.webp';
    for (var i = 0; i < 65; i++) {
      final url = 'https://throttle.test/$i.webp';
      final stream = EmoteUrlProvider(url).resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener((_, _) {});
      stream.addListener(listener);
      streams.add(stream);
      listeners.add(listener);
    }
    // Let the gated decodes complete.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    // 65 animated listeners: past the soft limit, the cap halves.
    expect(EmoteUrlProvider.animatedListenerCount, 65);
    expect(EmoteUrlProvider.debugEffectiveCap(firstUrl), 15);

    // Dropping back under the limit restores the user cap.
    for (var i = 1; i < streams.length; i++) {
      streams[i].removeListener(listeners[i]);
    }
    await tester.pump();

    expect(EmoteUrlProvider.animatedListenerCount, 1);
    expect(EmoteUrlProvider.debugEffectiveCap(firstUrl), 30);

    streams[0].removeListener(listeners[0]);
    await tester.pump();
  });

  testWidgets('the toggle disables tiering without touching the user cap', (
    tester,
  ) async {
    final red = await tester.runAsync(() => _solidImage(255, 0, 0));
    final blue = await tester.runAsync(() => _solidImage(0, 0, 255));
    EmoteUrlProvider.debugFetchOverride = (_) async => _animatedWebpBytes();
    EmoteUrlProvider.debugDecodeOverride = (bytes) async => EmoteFrameData(
      frames: [red!, blue!],
      durations: const [Duration(milliseconds: 80), Duration(milliseconds: 80)],
    );

    const url = 'https://toggle.webp.test/0.webp';
    final stream = EmoteUrlProvider(url).resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((_, _) {});
    stream.addListener(listener);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    // Single visible animation: base cap either way.
    expect(EmoteUrlProvider.debugEffectiveCap(url), 30);

    // Simulate heavy load with the throttle off: no tiering.
    EmoteUrlProvider.applyAdaptiveThrottle(false);
    expect(EmoteUrlProvider.debugEffectiveCap(url), 30);

    // Re-enabling re-evaluates live loops immediately.
    EmoteUrlProvider.applyAdaptiveThrottle(true);
    expect(EmoteUrlProvider.debugEffectiveCap(url), 30);

    stream.removeListener(listener);
    await tester.pump();
  });
}
