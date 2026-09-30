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

/// Resolves every emote to nothing, standing in for the nothing tier with an
/// uncached emote so the resolver takes its text fallback.
class _UnresolvingEmoteImages extends EmoteImages {
  @override
  Future<({String url, String? placeholder})?> resolve(
    Emote emote,
    EmoteSurface surface,
  ) async => null;
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

  testWidgets('shows the band while loading and after a url change', (
    tester,
  ) async {
    final firstGate = Completer<Uint8List>();
    EmoteUrlProvider.debugFetchOverride = (_) => firstGate.future;
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
    await tester.pump();
    expect(_renderOf(tester).debugFrame, isNull);
    expect(_renderOf(tester).debugShowsBand, isTrue);

    firstGate.complete(_pngBytes());
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

  testWidgets('an unresolvable emote renders its code as normal text', (
    tester,
  ) async {
    const code = 'FRICK';
    final emote = Emote(
      id: 'frick',
      code: code,
      meta: const SevenTvMeta(),
      scales: const {EmoteScale.medium: 'https://inline.test/frick.png'},
    );
    final channelEmotes = EmoteLookup(byCode: {code: emote}, suggestions: []);
    final spans = EmoteText.build(
      text: code,
      twitchPositions: null,
      channelEmotes: channelEmotes,
      emoteImages: _UnresolvingEmoteImages(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Text.rich(TextSpan(children: spans))),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The code flows at its natural width instead of wrapping inside a 28px
    // emote box. A boxed fallback would be 28 wide with two lines.
    expect(find.text(code), findsOneWidget);
    expect(tester.getSize(find.text(code)).width, greaterThan(28));
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

    // Pausing then unmounting balances the completer handle release.
    await pumpWith(false);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
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

  testWidgets('a stock Twitch GIF pauses while emotes are frozen', (
    tester,
  ) async {
    addTearDown(() => EmoteUrlProvider.applyFrameRate(60));
    const emote = Emote(
      id: 'gif',
      code: 'KappaGif',
      meta: TwitchMeta(kind: TwitchEmoteKind.standard),
      scales: {EmoteScale.medium: 'https://inline.test/gif.gif'},
      isAnimated: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: EmoteScaleResolver(
          emote: emote,
          surface: EmoteSurface.chat,
          images: _ResolvingEmoteImages(),
          width: 28,
          height: 28,
          lean: true,
        ),
      ),
    );
    await tester.pump();

    // Playing Twitch GIFs take the stock path, which only TickerMode pauses.
    expect(find.byType(InlineEmoteView), findsNothing);
    bool ticking() =>
        TickerMode.valuesOf(tester.element(find.byType(Image))).enabled;
    expect(ticking(), isTrue);

    EmoteUrlProvider.applyFrameRate(0);
    await tester.pump();
    expect(ticking(), isFalse);

    EmoteUrlProvider.applyFrameRate(30);
    await tester.pump();
    expect(ticking(), isTrue);
  });

  testWidgets('a cache evict does not spawn a second decoder for a live url', (
    tester,
  ) async {
    EmoteUrlProvider.debugFetchOverride = (_) async => _pngBytes();
    const url = 'https://inline.test/shared-evict.png';

    Widget column(int count) => MaterialApp(
      home: Column(
        children: [
          for (var i = 0; i < count; i++)
            InlineEmoteView(url: url, width: 28, height: 28, images: _images),
        ],
      ),
    );

    await tester.pumpWidget(column(1));
    await _pumpUntilLoaded(tester);
    final buildsAfterFirst = EmoteUrlProvider.debugCompleterBuilds;

    // Drop the cache bookmark while the row still holds the playing completer,
    // mimicking the capture cleanup and the load-error eviction.
    PaintingBinding.instance.imageCache.evict(
      EmoteUrlProvider(url, images: _images),
    );
    await tester.pump();

    // A second row for the same url must attach to the same completer instead
    // of building a fresh playback clock.
    await tester.pumpWidget(column(2));
    await _pumpUntilLoaded(tester);

    expect(EmoteUrlProvider.debugCompleterBuilds, buildsAfterFirst);
    expect(
      tester
          .renderObject<RenderInlineEmote>(find.byType(InlineEmoteView).first)
          .debugFrame,
      isNotNull,
    );
  });
}
