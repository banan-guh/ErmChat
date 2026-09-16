import 'dart:io';
import 'dart:typed_data';

import 'package:ermchat/services/emote_images.dart';
import 'package:ermchat/widgets/emote_url_provider.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

// Growth probe for the emote completer registry. Churns many distinct emote
// URLs, each briefly attaching an ImageStreamListener, and samples
// EmoteUrlProvider.liveCount to see whether completers (and their frame work)
// pile up after listeners detach. Run with:
//   flutter test test/leak/emote_completer_lifecycle_test.dart
//
// ImageCache frees a detached completer through a post-frame callback, so the
// test schedules a frame around each sample; without that the binding's
// pump() skips the frame and disposal never runs (a test-harness effect, not
// an app behavior).

final _images = EmoteImages();

/// A valid 2x2 opaque PNG, generated once and reused for every static URL.
Uint8List _pngBytes() {
  final image = img.Image(width: 2, height: 2);
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: 2,
    y2: 2,
    color: img.ColorRgba8(255, 0, 0, 255),
  );
  return Uint8List.fromList(img.encodePng(image));
}

ImageCache get _cache => PaintingBinding.instance.imageCache;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('emote completers do not accumulate across URL churn', (
    tester,
  ) async {
    final png = _pngBytes();
    final gif = File('test/fixtures/7tv_kiss_2x.gif').readAsBytesSync();
    EmoteUrlProvider.debugFetchOverride = (url) async =>
        url.endsWith('.gif') ? gif : png;
    addTearDown(() {
      EmoteUrlProvider.debugFetchOverride = null;
      EmoteUrlProvider.debugWebpEngineFailAfter = -1;
      _cache.clear();
      _cache.clearLiveImages();
    });
    _cache.clear();
    _cache.clearLiveImages();

    final listener = ImageStreamListener((image, synchronousCall) {});
    const total = 2000;
    const batch = 200;
    final beforeClear = <int>[];
    final afterClear = <int>[];

    // Force a frame so ImageCache's post-frame handle disposal can run.
    Future<void> frame() async {
      SchedulerBinding.instance.scheduleFrame();
      await tester.pump();
    }

    stdout.writeln(
      '[leak] start: liveCount=${EmoteUrlProvider.liveCount} '
      'transientCallbacks=${SchedulerBinding.instance.transientCallbackCount}',
    );

    for (var i = 0; i < total; i++) {
      // A small animated-GIF minority exercises the streaming completer path.
      final animated = i % 100 == 0;
      final url = animated
          ? 'https://leak.test/anim_$i.gif'
          : 'https://leak.test/emote_$i.png';
      final provider = EmoteUrlProvider(url, images: _images);
      final stream = provider.resolve(ImageConfiguration.empty);
      stream.addListener(listener);
      await frame();
      stream.removeListener(listener);

      if ((i + 1) % batch == 0) {
        // Let engine decodes settle so completers reach their cached state.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await frame();
        final liveBefore = EmoteUrlProvider.liveCount;
        beforeClear.add(liveBefore);
        final animUrl = 'https://leak.test/anim_${(i ~/ 100) * 100}.gif';
        stdout.writeln(
          '[leak] anim probe ${(i ~/ 100) * 100}: '
          'hasFrames=${EmoteUrlProvider.hasFrames(animUrl)} '
          'frame=${EmoteUrlProvider.currentFrame(animUrl)}',
        );
        // Drop the cache so every absorbed completer is eligible for disposal.
        _cache.clear();
        _cache.clearLiveImages();
        await frame();
        final liveAfter = EmoteUrlProvider.liveCount;
        afterClear.add(liveAfter);
        stdout.writeln(
          '[leak] after ${i + 1} urls: liveBeforeClear=$liveBefore '
          'liveAfterClear=$liveAfter '
          'transientCallbacks=${SchedulerBinding.instance.transientCallbackCount}',
        );
      }
    }

    // Direct check: a held animated listener advances frames, and detaching it
    // stops the loop so no frame work survives.
    const heldUrl = 'https://leak.test/held.gif';
    final heldStream = EmoteUrlProvider(
      heldUrl,
      images: _images,
    ).resolve(ImageConfiguration.empty);
    heldStream.addListener(listener);
    await frame();
    for (var k = 0; k < 8; k++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      // pump with a duration fires the completer's fake-zone frame timer.
      await tester.pump(const Duration(milliseconds: 130));
    }
    final advancedFrame = EmoteUrlProvider.currentFrame(heldUrl);
    heldStream.removeListener(listener);
    await tester.pump(const Duration(seconds: 2));
    final frozenFrame = EmoteUrlProvider.currentFrame(heldUrl);
    stdout.writeln(
      '[leak] held anim: advancedFrame=$advancedFrame frozenFrame=$frozenFrame '
      'transientCallbacks=${SchedulerBinding.instance.transientCallbackCount}',
    );

    // Final clearing pass, then settle: nothing should keep scheduling frames.
    _cache.clear();
    _cache.clearLiveImages();
    await frame();
    final settledLive = EmoteUrlProvider.liveCount;
    await tester.pump(const Duration(seconds: 2));
    final settledCallbacks = SchedulerBinding.instance.transientCallbackCount;
    stdout.writeln(
      '[leak] after settling clear: liveCount=$settledLive '
      'transientCallbacks=$settledCallbacks',
    );

    // 2000 distinct URLs must not leave anywhere near that many completers once
    // the cache releases them.
    expect(
      settledLive,
      lessThan(batch),
      reason: 'completers scale with churned URLs (live=$settledLive)',
    );
    expect(
      settledCallbacks,
      0,
      reason: 'frame callbacks still scheduled after listeners detached',
    );

    // Each clearing pass must return the population to a bounded steady state.
    for (final live in afterClear) {
      expect(
        live,
        lessThan(batch),
        reason: 'liveCount did not drop after clearing the cache',
      );
    }
    stdout.writeln(
      '[leak] sample beforeClear first=${beforeClear.first} '
      'last=${beforeClear.last} afterClear first=${afterClear.first} '
      'last=${afterClear.last}',
    );
  });
}
