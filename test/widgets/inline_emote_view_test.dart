import 'dart:async';
import 'dart:typed_data';

import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/widgets/emote_image_provider.dart';
import 'package:ermchat/widgets/emote_loading_band.dart';
import 'package:ermchat/widgets/emote_text.dart';
import 'package:ermchat/widgets/inline_emote_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

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
    EmoteUrlProvider.debugDecodeOverride = null;
  });

  testWidgets('resolves and paints the loaded frame', (tester) async {
    EmoteUrlProvider.debugFetchOverride = (_) async => _pngBytes();
    const url = 'https://inline.test/plain.png';
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: InlineEmoteView(url: url, width: 28, height: 28),
          ),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    final ro = _renderOf(tester);
    expect(ro.debugFrame, isNotNull);
    expect(ro.debugAltFrame, isNull);
    expect(ro.debugShowsBand, isFalse);
  });

  testWidgets('shows the band while loading and releases it after', (
    tester,
  ) async {
    final gate = Completer<Uint8List>();
    EmoteUrlProvider.debugFetchOverride = (_) => gate.future;
    const url = 'https://inline.test/gated.png';
    await tester.pumpWidget(
      MaterialApp(home: InlineEmoteView(url: url, width: 28, height: 28)),
    );
    await tester.pump();

    final ro = _renderOf(tester);
    expect(ro.debugFrame, isNull);
    expect(ro.debugShowsBand, isTrue);
    expect(EmoteLoadingClock.isActive, isTrue);

    gate.complete(_pngBytes());
    await tester.pump();
    await _pumpUntilLoaded(tester);

    expect(ro.debugFrame, isNotNull);
    // The only consumer unhooked when the frame landed.
    expect(EmoteLoadingClock.isActive, isFalse);
  });

  testWidgets('a cached alternate shows under the faint band and clears', (
    tester,
  ) async {
    final altPng = _pngBytes();
    final altUrl = 'https://inline.test/small.png';
    final mainUrl = 'https://inline.test/big.png';
    // Warm the memory cache with the alternate (like a previously rendered
    // smaller scale).
    EmoteUrlProvider.debugFetchOverride = (_) async => altPng;
    await tester.pumpWidget(
      MaterialApp(home: InlineEmoteView(url: altUrl, width: 28, height: 28)),
    );
    await _pumpUntilLoaded(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    final mainGate = Completer<Uint8List>();
    EmoteUrlProvider.debugFetchOverride = (url) =>
        url == altUrl ? Future.value(altPng) : mainGate.future;
    await tester.pumpWidget(
      MaterialApp(
        home: InlineEmoteView(
          url: mainUrl,
          width: 28,
          height: 28,
          alternateUrls: [altUrl],
        ),
      ),
    );
    await tester.pump();

    final ro = _renderOf(tester);
    expect(ro.debugAltFrame, isNotNull);
    expect(ro.debugFrame, isNull);
    expect(EmoteLoadingClock.isActive, isTrue);

    mainGate.complete(_pngBytes());
    await tester.pump();
    await _pumpUntilLoaded(tester);

    expect(ro.debugFrame, isNotNull);
    expect(ro.debugAltFrame, isNull);
    expect(EmoteLoadingClock.isActive, isFalse);
  });

  testWidgets('a url change drops the old frame and resolves anew', (
    tester,
  ) async {
    EmoteUrlProvider.debugFetchOverride = (_) async => _pngBytes();
    const firstUrl = 'https://inline.test/a.png';
    await tester.pumpWidget(
      MaterialApp(home: InlineEmoteView(url: firstUrl, width: 28, height: 28)),
    );
    await _pumpUntilLoaded(tester);
    expect(_renderOf(tester).debugFrame, isNotNull);

    final secondGate = Completer<Uint8List>();
    EmoteUrlProvider.debugFetchOverride = (url) =>
        url == firstUrl ? Future.value(_pngBytes()) : secondGate.future;
    const secondUrl = 'https://inline.test/b.png';
    await tester.pumpWidget(
      MaterialApp(home: InlineEmoteView(url: secondUrl, width: 28, height: 28)),
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
    final emote = GenericEmote(
      id: 'kt',
      code: code,
      type: EmoteType.twitch,
      url: 'https://inline.test/tap.png',
    );
    final channelEmotes = ChannelEmotes(byCode: {code: emote}, suggestions: []);
    final tapped = <List<GenericEmote>>[];
    final spans = EmoteText.build(
      text: code,
      twitchPositions: null,
      channelEmotes: channelEmotes,
      onEmoteTap: tapped.add,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Text.rich(TextSpan(children: spans))),
      ),
    );
    await _pumpUntilLoaded(tester);

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
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: InlineEmoteView(url: url, width: 28, height: 28),
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
              children: const [
                SizedBox(
                  width: 28,
                  height: 28,
                  child: InlineEmoteView(url: url, width: 28, height: 28),
                ),
                SizedBox(
                  width: 28,
                  height: 28,
                  child: InlineEmoteView(url: url, width: 28, height: 28),
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
}
