import 'dart:async';
import 'dart:typed_data';

import 'package:ermchat/widgets/emote_image.dart';
import 'package:ermchat/widgets/emote_image_provider.dart';
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

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  await tester.pump();
}

RenderBox _emoteBox(WidgetTester tester) =>
    tester.renderObject<RenderBox>(find.byType(EmoteImage));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    EmoteUrlProvider.debugFetchOverride = null;
    EmoteUrlProvider.debugDecodeOverride = null;
  });

  // Regression: while an emote's first frame is still decoding, the loading
  // stack used to expand into whatever bounded constraints surrounded it. In
  // a ListTile leading slot that meant a full-width leader and a fatal
  // "Leading widget consumes the entire tile width" layout assertion.
  testWidgets(
    'loading and cached alternate emotes stay sized in leading slots',
    (tester) async {
      final gate = Completer<Uint8List>();
      EmoteUrlProvider.debugFetchOverride = (_) => gate.future;
      const url = 'https://leading.test/gated.png';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ListTile(
                  leading: EmoteImage(url: url, width: 28, height: 28),
                  title: const Text('emote'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(_emoteBox(tester).size, const Size(28, 28));

      gate.complete(_pngBytes());
      await _settle(tester);
      expect(tester.takeException(), isNull);

      final altPng = _pngBytes();
      final altUrl = 'https://leading.test/small.png';
      final mainUrl = 'https://leading.test/big.png';
      EmoteUrlProvider.debugFetchOverride = (_) async => altPng;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: EmoteImage(url: altUrl, width: 28, height: 28)),
          ),
        ),
      );
      await _settle(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      final mainGate = Completer<Uint8List>();
      EmoteUrlProvider.debugFetchOverride = (url) =>
          url == altUrl ? Future.value(altPng) : mainGate.future;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ListTile(
                  leading: EmoteImage(
                    url: mainUrl,
                    width: 28,
                    height: 28,
                    alternateUrls: [altUrl],
                  ),
                  title: const Text('emote'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(_emoteBox(tester).size, const Size(28, 28));

      mainGate.complete(_pngBytes());
      await _settle(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an explicit infinity dimension still fills a bounded parent', (
    tester,
  ) async {
    final gate = Completer<Uint8List>();
    EmoteUrlProvider.debugFetchOverride = (_) => gate.future;
    const url = 'https://leading.test/fill.png';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 60,
              height: 60,
              child: EmoteImage(
                url: url,
                width: double.infinity,
                height: double.infinity,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(_emoteBox(tester).size, const Size(60, 60));

    gate.complete(_pngBytes());
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(_emoteBox(tester).size, const Size(60, 60));
  });

  testWidgets('a sizeless emote in a loose slot keeps its intrinsic size', (
    tester,
  ) async {
    EmoteUrlProvider.debugFetchOverride = (_) async => _pngBytes();
    const url = 'https://leading.test/tiny.png';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [Center(child: EmoteImage(url: url))],
          ),
        ),
      ),
    );
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(_emoteBox(tester).size.width, lessThanOrEqualTo(8.0));
  });
}
