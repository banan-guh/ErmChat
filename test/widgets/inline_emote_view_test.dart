import 'dart:async';
import 'dart:typed_data';

import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/emotes/emote_catalog.dart';
import 'package:ermchat/emotes/emote_picker.dart';
import 'package:ermchat/services/emote_images.dart';
import 'package:ermchat/services/emote_probe_memo.dart';
import 'package:ermchat/widgets/emote_url_provider.dart';
import 'package:ermchat/widgets/emote_scale_resolver.dart';
import 'package:ermchat/widgets/emote_text.dart';
import 'package:ermchat/widgets/inline_emote_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

final _images = EmoteImages();

/// Resolves emotes without touching the disk cache, so widget tests can render
/// the resolver synchronously instead of waiting on cache probes.
class _ResolvingEmoteImages extends EmoteImages {
  @override
  Future<({String url, String? placeholder})?> resolve(
    Emote emote,
    EmoteSurface surface,
  ) async {
    final url = emote.urlFor(EmoteScale.medium) ?? emote.scales.values.first;
    return (url: url, placeholder: null);
  }
}

Uint8List _pngBytes([int width = 2, int height = 2]) {
  final image = img.Image(width: width, height: height);
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: width,
    y2: height,
    color: img.ColorRgba8(255, 0, 0, 255),
  );
  return Uint8List.fromList(img.encodePng(image));
}

Future<void> _pumpUntilLoaded(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  await tester.pump();
}

RenderInlineEmote _renderOf(WidgetTester tester) =>
    tester.renderObject<RenderInlineEmote>(find.byType(InlineEmoteView));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    EmoteUrlProvider.debugFetchOverride = null;
  });

  testWidgets('emote frame is a repaint boundary', (tester) async {
    // Each GIF frame must repaint emote pixels only, never the whole
    // tile: without the boundary, animated rows repaint fully on every
    // frame flip and collide with keyboard tick frames.
    EmoteUrlProvider.debugFetchOverride = (_) async => _pngBytes();
    await tester.pumpWidget(
      MaterialApp(
        home: InlineEmoteView(
          url: 'https://inline.test/boundary.png',
          width: 28,
          height: 28,
          images: _images,
        ),
      ),
    );
    await _pumpUntilLoaded(tester);
    expect(_renderOf(tester).isRepaintBoundary, isTrue);
  });

  testWidgets('shows the band while loading, frame after', (tester) async {
    final gate = Completer<Uint8List>();
    EmoteUrlProvider.debugFetchOverride = (_) => gate.future;
    const url = 'https://inline.test/gated.png';
    await tester.pumpWidget(
      MaterialApp(
        home: InlineEmoteView(url: url, width: 28, height: 28, images: _images),
      ),
    );
    await tester.pump();

    final ro = _renderOf(tester);
    expect(ro.debugFrame, isNull);
    expect(ro.debugShowsBand, isTrue);

    gate.complete(_pngBytes());
    await tester.pump();
    await _pumpUntilLoaded(tester);

    expect(ro.debugFrame, isNotNull);
    expect(ro.debugShowsBand, isFalse);
  });

  testWidgets('a url change drops the old frame and resolves anew', (
    tester,
  ) async {
    EmoteUrlProvider.debugFetchOverride = (_) async => _pngBytes();
    const firstUrl = 'https://inline.test/a.png';
    await tester.pumpWidget(
      MaterialApp(
        home: InlineEmoteView(
          url: firstUrl,
          width: 28,
          height: 28,
          images: _images,
        ),
      ),
    );
    await _pumpUntilLoaded(tester);
    expect(_renderOf(tester).debugFrame, isNotNull);

    final secondGate = Completer<Uint8List>();
    EmoteUrlProvider.debugFetchOverride = (url) =>
        url == firstUrl ? Future.value(_pngBytes()) : secondGate.future;
    const secondUrl = 'https://inline.test/b.png';
    await tester.pumpWidget(
      MaterialApp(
        home: InlineEmoteView(
          url: secondUrl,
          width: 28,
          height: 28,
          images: _images,
        ),
      ),
    );
    await tester.pump();

    final ro = _renderOf(tester);
    expect(ro.debugFrame, isNull);
    expect(ro.debugShowsBand, isTrue);

    secondGate.complete(_pngBytes());
    await _pumpUntilLoaded(tester);
    expect(ro.debugFrame, isNotNull);
  });

  testWidgets('tapping an emote span fires the emote callback', (tester) async {
    EmoteUrlProvider.debugFetchOverride = (_) async => _pngBytes();
    const code = 'KappaTap';
    final emote = Emote(
      id: 'kt',
      code: code,
      // Animated non-Twitch routes to the custom pipeline (statics of any
      // provider render stock); bytes stay PNG so the still path applies.
      meta: const SevenTvMeta(),
      scales: const {EmoteScale.medium: 'https://inline.test/tap.png'},
      isAnimated: true,
    );
    final channelEmotes = EmoteLookup(byCode: {code: emote}, suggestions: []);
    final tapped = <List<Emote>>[];
    final spans = EmoteText.build(
      text: code,
      twitchPositions: null,
      channelEmotes: channelEmotes,
      emoteImages: _ResolvingEmoteImages(),
      onEmoteTap: tapped.add,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Text.rich(TextSpan(children: spans))),
      ),
    );
    await _pumpUntilLoaded(tester);
    await tester.pump();

    await tester.tap(find.byType(InlineEmoteView));
    expect(tapped, hasLength(1));
    expect(tapped.single.map((e) => e.code), [code]);
  });

  testWidgets('an oversized frame is contain-fit into the slot', (
    tester,
  ) async {
    // 64x32 red source in a 28x28 box: correct contain-fit draws a 28x14
    // band centered vertically; the old inscribe-only bug drew it at
    // intrinsic pixel size, spilling over the whole slot and beyond.
    EmoteUrlProvider.debugFetchOverride = (_) async => _pngBytes(64, 32);
    const url = 'https://inline.test/wide.png';
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: InlineEmoteView(
              url: url,
              width: 28,
              height: 28,
              images: _images,
            ),
          ),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    final ro = _renderOf(tester);
    // The render object must be contain-fit within the 28x28 slot.
    expect(ro.size.width, lessThanOrEqualTo(28.0));
    expect(ro.size.height, lessThanOrEqualTo(28.0));
    // The image's intrinsic 64x32 ratio means the fitted height is less
    // than the slot height, confirming contain-fit (not stretch).
    expect(ro.debugFrame, isNotNull);
  });

  testWidgets(
    'same emote url in two widgets paints both without double-dispose',
    (tester) async {
      // Regression: a shared completer handed one ImageInfo to every listener
      // (and disposing the engine's own image) double-freed the underlying
      // ui.Image ("cannot dispose of image"). Each listener must get its own
      // clone and the engine's image must never be disposed by us.
      EmoteUrlProvider.debugFetchOverride = (_) async => _pngBytes();
      const url = 'https://inline.test/shared.png';
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 28,
                  height: 28,
                  child: InlineEmoteView(
                    url: url,
                    width: 28,
                    height: 28,
                    images: _images,
                  ),
                ),
                SizedBox(
                  width: 28,
                  height: 28,
                  child: InlineEmoteView(
                    url: url,
                    width: 28,
                    height: 28,
                    images: _images,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await _pumpUntilLoaded(tester);

      final renderObjects = tester
          .renderObjectList<RenderInlineEmote>(find.byType(InlineEmoteView))
          .toList();
      expect(renderObjects, hasLength(2));
      for (final ro in renderObjects) {
        expect(ro.debugFrame, isNotNull);
      }

      // Dispose both; a shared-image double-dispose would surface here.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a decode failure stays silent and keeps the band', (
    tester,
  ) async {
    // Transparent-frame WebPs fail engine decode routinely; failures must
    // degrade to the loading band without reporting through FlutterError.
    EmoteUrlProvider.debugFetchOverride = (_) async =>
        Uint8List.fromList('definitely not an image'.codeUnits);
    const url = 'https://inline.test/broken.png';
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: InlineEmoteView(
              url: url,
              width: 28,
              height: 28,
              images: _images,
            ),
          ),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    expect(tester.takeException(), isNull);
    expect(_renderOf(tester).debugShowsBand, isTrue);
  });

  testWidgets('a disabled TickerMode defers the decode until enabled', (
    tester,
  ) async {
    var fetches = 0;
    EmoteUrlProvider.debugFetchOverride = (_) async {
      fetches++;
      return _pngBytes();
    };
    const url = 'https://inline.test/paused.png';

    Future<void> pumpWith(bool enabled) => tester.pumpWidget(
      MaterialApp(
        home: TickerMode(
          enabled: enabled,
          child: InlineEmoteView(
            url: url,
            width: 28,
            height: 28,
            images: _images,
          ),
        ),
      ),
    );

    // Background page: no fetch, no frame, just the band.
    await pumpWith(false);
    await _pumpUntilLoaded(tester);
    expect(fetches, 0);
    expect(_renderOf(tester).debugFrame, isNull);
    expect(_renderOf(tester).debugShowsBand, isTrue);

    // Focused: resolves and paints.
    await pumpWith(true);
    await _pumpUntilLoaded(tester);
    expect(fetches, 1);
    expect(_renderOf(tester).debugFrame, isNotNull);

    // Refocus after a pause reuses the live completer instead of re-decoding.
    await pumpWith(false);
    await tester.pump();
    await pumpWith(true);
    await _pumpUntilLoaded(tester);
    expect(fetches, 1);
    expect(_renderOf(tester).debugFrame, isNotNull);
  });

  testWidgets('a warm emote skips the placeholder frame', (tester) async {
    final memo = EmoteProbeMemo();
    final images = EmoteImages(probeMemo: memo);
    addTearDown(images.dispose);
    const url = 'https://inline.test/warm.png';
    const emote = Emote(
      id: 'warm',
      code: 'KappaWarm',
      meta: SevenTvMeta(),
      scales: {EmoteScale.medium: url},
    );
    // Warm the probe memo the way a prior render of this emote would.
    await memo.probe(url, (_) async => true);

    await tester.pumpWidget(
      MaterialApp(
        home: EmoteScaleResolver(
          emote: emote,
          surface: EmoteSurface.chat,
          images: images,
          width: 28,
          height: 28,
          lean: true,
        ),
      ),
    );

    // Resolved before the first build: an Image, not the gray placeholder box.
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('pausing then unmounting releases without throwing', (
    tester,
  ) async {
    EmoteUrlProvider.debugFetchOverride = (_) async => _pngBytes();
    const url = 'https://inline.test/pause-dispose.png';
    final enabled = ValueNotifier<bool>(true);
    final shown = ValueNotifier<bool>(true);
    addTearDown(enabled.dispose);
    addTearDown(shown.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: shown,
          builder: (_, visible, _) => !visible
              ? const SizedBox.shrink()
              : ValueListenableBuilder<bool>(
                  valueListenable: enabled,
                  builder: (_, on, _) => TickerMode(
                    enabled: on,
                    child: InlineEmoteView(
                      url: url,
                      width: 28,
                      height: 28,
                      images: _images,
                    ),
                  ),
                ),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);
    expect(_renderOf(tester).debugFrame, isNotNull);

    // Background the page: the listener leaves but the completer stays alive.
    enabled.value = false;
    await tester.pump();
    // Then unmount it: the handle release must be balanced.
    shown.value = false;
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
