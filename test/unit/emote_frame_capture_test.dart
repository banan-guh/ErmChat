import 'dart:io';

import 'package:ermchat/services/emote_images.dart';
import 'package:ermchat/widgets/emote_url_provider.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

// Decoded-frame capture + array playback timing for EmoteUrlProvider.
//
// The engine streams animated WebP frames one at a time on the real event
// loop, so every cycle below alternates a fake-async pump (fires the frame
// timer) with a real-async delay (lets the engine decode land). A bare pump
// never elapses the timer and the loop looks frozen.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EmoteImages images;

  setUp(() {
    images = EmoteImages();
    EmoteUrlProvider.debugFetchOverride = null;
    EmoteUrlProvider.debugResetCapture();
    EmoteUrlProvider.applyGifsEnabled(true);
  });

  tearDown(() {
    EmoteUrlProvider.debugFetchOverride = null;
    EmoteUrlProvider.debugResetCapture();
    EmoteUrlProvider.applyGifsEnabled(true);
    PaintingBinding.instance.imageCache.clearLiveImages();
    PaintingBinding.instance.imageCache.clear();
  });

  /// Resolves [url], attaches a listener, and runs the decode loop. Callers can
  /// mark the URL first to make its frames capture-eligible. The returned
  /// listener must be detached before the test body ends: a running playback
  /// loop leaves a pending frame timer that fails the binding's invariant.
  Future<(ImageStream, ImageStreamListener)> startStreamUntilCaptured(
    WidgetTester tester,
    String url, {
    int maxIterations = 200,
  }) async {
    EmoteUrlProvider.markChatUse(url);
    final stream = EmoteUrlProvider(
      url,
      images: images,
    ).resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((_, _) {});
    stream.addListener(listener);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    // Break the moment the array handoff happens, before the next pump runs
    // the array clock, so the transition frame is observable.
    for (var i = 0; i < maxIterations; i++) {
      await tester.pump(const Duration(milliseconds: 70));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 35)),
      );
      if (EmoteUrlProvider.isFullyCaptured(url)) break;
    }
    return (stream, listener);
  }

  /// Resolves [url], attaches a listener, and runs the decode loop. Callers can
  /// mark the URL first to make its frames capture-eligible. The returned
  /// listener must be detached before the test body ends: a running playback
  /// loop leaves a pending frame timer that fails the binding's invariant.
  Future<(ImageStream, ImageStreamListener)> startStream(
    WidgetTester tester,
    String url, {
    required int iterations,
    bool mark = false,
  }) async {
    if (mark) EmoteUrlProvider.markChatUse(url);
    final stream = EmoteUrlProvider(
      url,
      images: images,
    ).resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((_, _) {});
    stream.addListener(listener);

    // Let the fetch and codec open settle before the first tick.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    // Keep real time (the schedule grid's clock) in step with the fake pump so
    // each tick is due: pump fires the fake timer, then a shorter real delay
    // lets the engine decode land without letting the frame go stale.
    for (var i = 0; i < iterations; i++) {
      await tester.pump(const Duration(milliseconds: 70));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 35)),
      );
    }
    return (stream, listener);
  }

  testWidgets('capture is gated to chat-surfaced urls', (tester) async {
    final webp = File('test/fixtures/7tv_kiss_2x.webp').readAsBytesSync();
    EmoteUrlProvider.debugFetchOverride = (url) async => webp;

    const unmarked = 'https://capture.test/unmarked.webp';
    final (unmarkedStream, unmarkedListener) = await startStream(
      tester,
      unmarked,
      iterations: 120,
    );
    expect(EmoteUrlProvider.capturedFrameCount(unmarked), 0);
    expect(EmoteUrlProvider.isFullyCaptured(unmarked), isFalse);
    unmarkedStream.removeListener(unmarkedListener);

    const marked = 'https://capture.test/marked.webp';
    // Stop short of a full 47-frame cycle so the in-progress count is visible
    // (a completed capture transfers its frames into the array and resets it).
    final (markedStream, markedListener) = await startStream(
      tester,
      marked,
      iterations: 60,
      mark: true,
    );
    expect(EmoteUrlProvider.capturedFrameCount(marked), greaterThan(0));
    expect(EmoteUrlProvider.isFullyCaptured(marked), isFalse);
    markedStream.removeListener(markedListener);
  });

  testWidgets(
    'a chat-surfaced emote captures a full cycle and switches to array playback',
    (tester) async {
      final webp = File('test/fixtures/7tv_kiss_2x.webp').readAsBytesSync();
      EmoteUrlProvider.debugFetchOverride = (url) async => webp;

      const url = 'https://capture.test/full.webp';
      final (stream, listener) = await startStreamUntilCaptured(tester, url);

      expect(EmoteUrlProvider.isFullyCaptured(url), isTrue);
      // The captured frames moved into the materialized array.
      expect(EmoteUrlProvider.capturedFrameCount(url), 0);
      expect(EmoteUrlProvider.hasFrames(url), isTrue);
      // Handoff continuity: the last streamed frame (index 46) is still the
      // displayed one, not the next frame (regression: off-by-one skipped it).
      expect(EmoteUrlProvider.currentFrame(url), 46);
      stream.removeListener(listener);
    },
  );

  testWidgets('array playback keeps wall-clock phase across a gap', (
    tester,
  ) async {
    final webp = File('test/fixtures/7tv_kiss_2x.webp').readAsBytesSync();
    EmoteUrlProvider.debugFetchOverride = (url) async => webp;

    const url = 'https://capture.test/phase.webp';
    final (stream, listener) = await startStream(
      tester,
      url,
      iterations: 150,
      mark: true,
    );
    expect(EmoteUrlProvider.isFullyCaptured(url), isTrue);

    final before = EmoteUrlProvider.currentFrame(url);
    // A real-time gap with no frames delivered, then one late pump. Array
    // playback indexes by elapsed wall time, so the position jumps several
    // frames instead of advancing by one.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final after = EmoteUrlProvider.currentFrame(url);
    expect((after - before + 47) % 47, greaterThanOrEqualTo(2));
    stream.removeListener(listener);
  });

  testWidgets('array playback stays frozen while animations are off', (
    tester,
  ) async {
    final webp = File('test/fixtures/7tv_kiss_2x.webp').readAsBytesSync();
    EmoteUrlProvider.debugFetchOverride = (url) async => webp;

    const url = 'https://capture.test/frozen.webp';
    final (stream, listener) = await startStreamUntilCaptured(tester, url);
    expect(EmoteUrlProvider.isFullyCaptured(url), isTrue);

    final frozenAt = EmoteUrlProvider.currentFrame(url);
    EmoteUrlProvider.applyGifsEnabled(false);
    // Reattaching must not restart playback while the setting is off.
    stream.removeListener(listener);
    stream.addListener(listener);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(EmoteUrlProvider.currentFrame(url), frozenAt);

    // Toggling back on resumes from the frozen position.
    EmoteUrlProvider.applyGifsEnabled(true);
    var resumed = false;
    for (var i = 0; i < 10 && !resumed; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      resumed = EmoteUrlProvider.currentFrame(url) != frozenAt;
    }
    expect(resumed, isTrue);
    stream.removeListener(listener);
  });

  testWidgets('capture LRU keeps the newest 20 and drops the oldest', (
    tester,
  ) async {
    for (var i = 0; i < 25; i++) {
      EmoteUrlProvider.debugSeedCaptured('https://capture.test/e$i');
    }

    expect(
      EmoteUrlProvider.capturedEmoteCount,
      EmoteUrlProvider.maxCapturedEmotes,
    );
    final captured = EmoteUrlProvider.debugCapturedEmotes;
    expect(captured, contains('https://capture.test/e24'));
    expect(captured, isNot(contains('https://capture.test/e0')));
    expect(captured, [for (var i = 5; i < 25; i++) 'https://capture.test/e$i']);
  });
}
