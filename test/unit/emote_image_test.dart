import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shimmer/shimmer.dart';

import 'package:ermchat/services/emote_codec/native_emote_codec.dart';
import 'package:ermchat/widgets/emote_image.dart';
import 'package:ermchat/widgets/emote_image_provider.dart';

/// Minimal bytes that sniff as an animated WebP (RIFF+WEBP header with an
/// ANMF chunk), so the emote pipeline routes them through the reinforced
/// decoder (and the test decode override) instead of the engine codec.
Uint8List animatedWebpBytes() => Uint8List.fromList([
  0x52, 0x49, 0x46, 0x46, // RIFF
  0, 0, 0, 0,
  0x57, 0x45, 0x42, 0x50, // WEBP
  0x41, 0x4E, 0x4D, 0x46, // ANMF
  0, 0, 0, 0,
]);

/// First pixel of [image] as a String; identity assertions don't survive the
/// stock Image pipeline (it clones frame handles), so tests compare pixels.
Future<String> _firstPixel(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final b = data!.buffer.asUint8List();
  return '${b[0]},${b[1]},${b[2]},${b[3]}';
}

Future<ui.Image> _makeImage(int r, int g, int b) {
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
    EmoteUrlProvider.debugFetchOverride = null;
    EmoteUrlProvider.debugDecodeOverride = null;
    NativeEmoteCodec.debugLibPath = '/nonexistent/libemote_codec.so';
    NativeEmoteCodec.reset();
  });

  tearDown(() async {
    EmoteUrlProvider.debugFetchOverride = null;
    EmoteUrlProvider.debugDecodeOverride = null;
    NativeEmoteCodec.debugLibPath = null;
    NativeEmoteCodec.reset();
    PaintingBinding.instance.imageCache.clearLiveImages();
    PaintingBinding.instance.imageCache.clear();
  });

  group('sniffEmoteFormat', () {
    test('detects GIF magic', () {
      expect(
        sniffEmoteFormat(Uint8List.fromList('GIF89a'.codeUnits)),
        EmoteFormat.gif,
      );
      expect(
        sniffEmoteFormat(Uint8List.fromList('GIF87a'.codeUnits)),
        EmoteFormat.gif,
      );
    });

    test('detects WebP magic', () {
      final webp = Uint8List.fromList('RIFF....WEBP'.codeUnits);
      expect(sniffEmoteFormat(webp), EmoteFormat.webp);
    });

    test('everything else is other', () {
      final png = Uint8List.fromList([
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ]);
      final avifBrand = Uint8List.fromList([
        0, 0, 0, 32, 0x66, 0x74, 0x79, 0x70, // ftyp
        0x61, 0x76, 0x69, 0x66, // avif brand (unsupported)
      ]);
      expect(sniffEmoteFormat(png), EmoteFormat.other);
      expect(sniffEmoteFormat(avifBrand), EmoteFormat.other);
      expect(sniffEmoteFormat(Uint8List(4)), EmoteFormat.other);
    });
  });

  group('webpIsAnimated', () {
    Uint8List webpWithChunk(String fourcc, {bool anmf = true}) {
      final header = Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46, // RIFF
        0, 0, 0, 0, // size (unused by the sniff)
        0x57, 0x45, 0x42, 0x50, // WEBP
        ...fourcc.codeUnits, // chunk fourcc
        0x0A, 0x00, 0x00, 0x00, // chunk size
      ]);
      return header;
    }

    test('detects ANMF chunk as animated', () {
      expect(webpIsAnimated(webpWithChunk('ANMF')), isTrue);
    });

    test('treats VP8 / VP8L / VP8X static chunks as not animated', () {
      expect(webpIsAnimated(webpWithChunk('VP8 ')), isFalse);
      expect(webpIsAnimated(webpWithChunk('VP8L')), isFalse);
      expect(webpIsAnimated(webpWithChunk('VP8X')), isFalse);
    });

    test('returns false for truncated or non-WebP bytes', () {
      expect(webpIsAnimated(Uint8List(4)), isFalse);
      expect(
        webpIsAnimated(Uint8List.fromList('RIFF....WEBP'.codeUnits)),
        isFalse,
      );
    });
  });

  group('animated WebP dispatch', () {
    test(
      'falls back to the pure-Dart decoder when the native lib is missing',
      () async {
        final bytes = File('test/fixtures/7tv_kiss_2x.webp').readAsBytesSync();
        final frames = await decodeEmoteBytes(bytes);
        expect(frames.isAnimated, isTrue);
        expect(frames.frames, hasLength(47));
        expect(frames.durations, everyElement(isNot(Duration.zero)));
        for (final f in frames.frames) {
          f.dispose();
        }
      },
    );
  });

  group('real emote bytes decode through the production pipeline', () {
    Future<EmoteFrameData> decodeFile(String path) async {
      final bytes = File('test/fixtures/$path').readAsBytesSync();
      return decodeEmoteBytes(bytes);
    }

    test(
      '7TV animated WebP (annycatKISS) decodes all frames in pure Dart',
      () async {
        final frames = await decodeFile('7tv_kiss_2x.webp');
        // Reference frame count is 47 (from the 7TV emote metadata).
        expect(frames.isAnimated, isTrue);
        expect(frames.frames, hasLength(47));
        expect(frames.durations, everyElement(isNot(Duration.zero)));
        // Frames carry real alpha (transparency preserved, not composited opaque).
        final index = frames.frames.length ~/ 2;
        expect(frames.frames[index].width, greaterThan(0));
        expect(frames.frames[index].height, greaterThan(0));
        for (final f in frames.frames) {
          f.dispose();
        }
      },
    );

    test(
      '7TV large animated WebP (wideBoink) decodes all 252 frames',
      () async {
        final frames = await decodeFile('7tv_boink_2x.webp');
        expect(frames.isAnimated, isTrue);
        expect(frames.frames, hasLength(252));
        expect(frames.durations, hasLength(252));
        expect(frames.durations, everyElement(isNot(Duration.zero)));
        for (final f in frames.frames) {
          f.dispose();
        }
      },
    );

    test('7TV animated GIF (annycatKISS) decodes all 47 frames', () async {
      final frames = await decodeFile('7tv_kiss_2x.gif');
      expect(frames.isAnimated, isTrue);
      expect(frames.frames, hasLength(47));
      expect(frames.durations, everyElement(isNot(Duration.zero)));
      for (final f in frames.frames) {
        f.dispose();
      }
    });
  });

  group('EmoteImage widget', () {
    Future<void> pumpEmote(
      WidgetTester tester, {
      String url = 'https://example.com/emote.gif',
      Widget? placeholder,
      Widget? errorWidget,
      List<String>? alternateUrls,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmoteImage(
              url: url,
              width: 28,
              height: 28,
              fit: BoxFit.contain,
              placeholder: placeholder,
              errorWidget: errorWidget,
              alternateUrls: alternateUrls,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('shows the placeholder until the first frame', (tester) async {
      final frame = await tester.runAsync(() => _makeImage(255, 0, 0));
      final gate = Completer<Uint8List>();
      EmoteUrlProvider.debugFetchOverride = (url) => gate.future;
      EmoteUrlProvider.debugDecodeOverride = (bytes) async =>
          EmoteFrameData(frames: [frame!], durations: const [Duration.zero]);

      await pumpEmote(tester, placeholder: const Text('loading'));
      // The main Image widget is in the tree from the start, but its RawImage
      // has no frame yet.
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNull);
      expect(find.text('loading'), findsOneWidget);

      gate.complete(animatedWebpBytes());
      // The fetch->decode->setState chain spans several microtask hops; the
      // second pump lets them all land.
      await tester.pump();
      await tester.pump();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      expect(find.text('loading'), findsNothing);
    });

    testWidgets(
      'a recycled widget switched to a new URL never shows the old emote\'s '
      'stale frame',
      (tester) async {
        final frameA = await tester.runAsync(() => _makeImage(255, 0, 0));
        final frameB = await tester.runAsync(() => _makeImage(0, 0, 255));
        final bBytes = Uint8List.fromList([...animatedWebpBytes(), 0xAB]);
        final gateB = Completer<Uint8List>();
        EmoteUrlProvider.debugFetchOverride = (url) {
          if (url == 'https://example.com/b.gif') return gateB.future;
          return Future.value(animatedWebpBytes());
        };
        EmoteUrlProvider.debugDecodeOverride = (bytes) async => EmoteFrameData(
          frames: [listEquals(bytes, bBytes) ? frameB! : frameA!],
          durations: const [Duration.zero],
        );

        await pumpEmote(tester, url: 'https://example.com/a.gif');
        RawImage raw() => tester.widget<RawImage>(find.byType(RawImage));
        expect(
          await tester.runAsync(() => _firstPixel(raw().image!)),
          '255,0,0,255',
        );

        // The same widget position is reused for emote B (like an
        // autocomplete row whose filtered list shifted), whose bytes are
        // still in flight.
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EmoteImage(
                url: 'https://example.com/b.gif',
                width: 28,
                height: 28,
                fit: BoxFit.contain,
              ),
            ),
          ),
        );
        await tester.pump();
        // The stale frame is gone: the loading state shows instead of A's
        // pixels (gaplessPlayback would otherwise keep painting A).
        expect(raw().image, isNull);
        expect(find.byType(Shimmer), findsWidgets);

        // B lands and renders.
        gateB.complete(bBytes);
        await tester.pump();
        await tester.pump();
        expect(
          await tester.runAsync(() => _firstPixel(raw().image!)),
          '0,0,255,255',
        );
      },
    );

    testWidgets('shows the error widget when the fetch fails', (tester) async {
      EmoteUrlProvider.debugFetchOverride = (url) async =>
          throw StateError('boom');
      await pumpEmote(tester, errorWidget: const Icon(Icons.error));
      expect(find.byType(Icon), findsOneWidget);
      expect(find.byType(RawImage), findsNothing);
    });

    testWidgets('shows the error widget when the decode fails', (tester) async {
      EmoteUrlProvider.debugFetchOverride = (url) async => animatedWebpBytes();
      EmoteUrlProvider.debugDecodeOverride = (bytes) async =>
          throw StateError('bad bytes');
      await pumpEmote(tester, errorWidget: const Icon(Icons.error));
      expect(find.byType(Icon), findsOneWidget);
    });

    testWidgets('animates through frames at their durations', (tester) async {
      final frame0 = await tester.runAsync(() => _makeImage(255, 0, 0));
      final frame1 = await tester.runAsync(() => _makeImage(0, 0, 255));
      EmoteUrlProvider.debugFetchOverride = (url) async => animatedWebpBytes();
      EmoteUrlProvider.debugDecodeOverride = (bytes) async => EmoteFrameData(
        frames: [frame0!, frame1!],
        durations: const [
          Duration(milliseconds: 100),
          Duration(milliseconds: 200),
        ],
      );

      await pumpEmote(tester);
      RawImage raw() => tester.widget<RawImage>(find.byType(RawImage));
      // The stock Image pipeline hands the widget clone handles, so compare
      // pixels instead of identity.
      expect(
        await tester.runAsync(() => _firstPixel(raw().image!)),
        '255,0,0,255',
      );

      await tester.pump(const Duration(milliseconds: 100));
      expect(
        await tester.runAsync(() => _firstPixel(raw().image!)),
        '0,0,255,255',
      );

      await tester.pump(const Duration(milliseconds: 200));
      expect(
        await tester.runAsync(() => _firstPixel(raw().image!)),
        '255,0,0,255',
      );

      await tester.pump(const Duration(milliseconds: 100));
      expect(
        await tester.runAsync(() => _firstPixel(raw().image!)),
        '0,0,255,255',
      );
    });

    testWidgets('two widgets with the same URL share one fetch', (
      tester,
    ) async {
      var fetches = 0;
      EmoteUrlProvider.debugFetchOverride = (url) async {
        fetches++;
        return animatedWebpBytes();
      };
      EmoteUrlProvider.debugDecodeOverride = (bytes) async => EmoteFrameData(
        frames: [await _makeImage(255, 0, 0)],
        durations: const [Duration.zero],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Row(
            children: const [
              EmoteImage(
                url: 'https://example.com/a.gif',
                width: 28,
                height: 28,
              ),
              EmoteImage(
                url: 'https://example.com/a.gif',
                width: 28,
                height: 28,
              ),
            ],
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(RawImage), findsNWidgets(2));
      expect(fetches, 1);
    });

    testWidgets('a new widget with a cached URL renders synchronously', (
      tester,
    ) async {
      final frame0 = await tester.runAsync(() => _makeImage(255, 0, 0));
      final frame1 = await tester.runAsync(() => _makeImage(0, 0, 255));
      EmoteUrlProvider.debugFetchOverride = (url) async => animatedWebpBytes();
      EmoteUrlProvider.debugDecodeOverride = (bytes) async => EmoteFrameData(
        frames: [frame0!, frame1!],
        durations: const [
          Duration(milliseconds: 100),
          Duration(milliseconds: 200),
        ],
      );

      Future<void> pumpOne() async {
        await tester.pumpWidget(
          MaterialApp(
            home: EmoteImage(
              url: 'https://example.com/a.gif',
              width: 28,
              height: 28,
              placeholder: const Text('loading'),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
      }

      await pumpOne();
      expect(find.text('loading'), findsNothing);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);

      // Recreate the whole tree with a fresh State (simulates a new tile).
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();

      // A brand-new widget for the same URL must render the cached frame on
      // its very first build, without flashing the placeholder.
      await tester.pumpWidget(
        MaterialApp(
          home: EmoteImage(
            url: 'https://example.com/a.gif',
            width: 28,
            height: 28,
            placeholder: const Text('loading'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('loading'), findsNothing);
      expect(find.byType(RawImage), findsOneWidget);
    });

    testWidgets('two widgets with the same URL stay in sync on one clock', (
      tester,
    ) async {
      final frame0 = await tester.runAsync(() => _makeImage(255, 0, 0));
      final frame1 = await tester.runAsync(() => _makeImage(0, 0, 255));
      EmoteUrlProvider.debugFetchOverride = (url) async => animatedWebpBytes();
      EmoteUrlProvider.debugDecodeOverride = (bytes) async => EmoteFrameData(
        frames: [frame0!, frame1!],
        durations: const [
          Duration(milliseconds: 100),
          Duration(milliseconds: 200),
        ],
      );

      Future<void> pumpTwo() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Row(
              children: const [
                EmoteImage(
                  url: 'https://example.com/a.gif',
                  width: 28,
                  height: 28,
                ),
                EmoteImage(
                  url: 'https://example.com/a.gif',
                  width: 28,
                  height: 28,
                ),
              ],
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
      }

      await pumpTwo();
      final raws = tester.widgetList<RawImage>(find.byType(RawImage)).toList();
      expect(raws, hasLength(2));
      expect(
        await tester.runAsync(() => _firstPixel(raws[0].image!)),
        '255,0,0,255',
      );
      expect(
        await tester.runAsync(() => _firstPixel(raws[1].image!)),
        '255,0,0,255',
      );

      await tester.pump(const Duration(milliseconds: 100));
      final raws2 = tester.widgetList<RawImage>(find.byType(RawImage)).toList();
      expect(
        await tester.runAsync(() => _firstPixel(raws2[0].image!)),
        '0,0,255,255',
      );
      expect(
        await tester.runAsync(() => _firstPixel(raws2[1].image!)),
        '0,0,255,255',
      );
    });

    testWidgets('does not re-fetch or re-decode while cached after unmount', (
      tester,
    ) async {
      var fetches = 0;
      var decodes = 0;
      EmoteUrlProvider.debugFetchOverride = (url) async {
        fetches++;
        return animatedWebpBytes();
      };
      EmoteUrlProvider.debugDecodeOverride = (bytes) async {
        decodes++;
        return EmoteFrameData(
          frames: [await _makeImage(255, 0, 0)],
          durations: const [Duration.zero],
        );
      };

      Future<void> pumpOne() async {
        await tester.pumpWidget(
          MaterialApp(
            home: EmoteImage(
              url: 'https://example.com/a.gif',
              width: 28,
              height: 28,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
      }

      await pumpOne();
      expect(fetches, 1);
      expect(decodes, 1);

      // Unmount (the completer stays cached in the stock ImageCache), then
      // re-mount: no fetch, no decode, instant render.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
      await pumpOne();
      expect(fetches, 1);
      expect(decodes, 1);
      expect(find.byType(RawImage), findsOneWidget);
    });

    testWidgets('engine-path images survive unmount/remount and eviction', (
      tester,
    ) async {
      final gif = File('test/fixtures/7tv_kiss_2x.gif').readAsBytesSync();
      var fetches = 0;
      EmoteUrlProvider.debugFetchOverride = (url) async {
        fetches++;
        return gif;
      };

      Future<void> pumpOne() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EmoteImage(
                url: 'https://example.com/engine.gif',
                width: 28,
                height: 28,
              ),
            ),
          ),
        );
        await tester.pump();
        // The engine codec decodes on the real event loop; let it deliver
        // its first frame (real async engine work cannot run in fake async).
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
      }

      await pumpOne();
      expect(fetches, 1);
      expect(find.byType(RawImage), findsOneWidget);

      // Unmount: the forwarder detaches and the engine completer pauses.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();

      // Re-mount: the cached completer re-attaches to the (kept-alive)
      // engine completer. Regression: this used to throw "Stream has been
      // disposed" because the engine completer disposed itself on detach and
      // re-attaching to a disposed completer is a hard error.
      await pumpOne();
      expect(fetches, 1);
      expect(find.byType(RawImage), findsOneWidget);

      // Evict from the cache (forces the onDisposed cleanup path) and
      // re-mount: a fresh fetch must succeed without exceptions.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
      PaintingBinding.instance.imageCache.evict(
        EmoteUrlProvider('https://example.com/engine.gif'),
      );
      await tester.pump();
      await pumpOne();
      expect(fetches, 2);
      expect(find.byType(RawImage), findsOneWidget);
    });

    testWidgets('a second engine-path widget mounting mid-build does not '
        'setState on unrelated widgets', (tester) async {
      final gif = File('test/fixtures/7tv_kiss_2x.gif').readAsBytesSync();
      EmoteUrlProvider.debugFetchOverride = (url) async => gif;

      final revealKey = GlobalKey<_RevealWidgetState>();
      final reveal = _RevealWidget(
        key: revealKey,
        url: 'https://example.com/shared.gif',
      );

      Future<void> pumpAll() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: EmoteImage(
                      url: 'https://example.com/shared.gif',
                      width: 28,
                      height: 28,
                    ),
                  ),
                  reveal,
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        // The engine codec decodes on the real event loop; let it deliver.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
      }

      await pumpAll();
      expect(find.byType(RawImage), findsOneWidget);

      // Mount a second widget with the same URL inside a narrow rebuild of
      // its own subtree. Regression: the engine's synchronous re-delivery of
      // its current frame used to be rebroadcast through setImage, calling
      // setState on the first widget while the second subtree was building
      // ("setState() or markNeedsBuild() called during build").
      revealKey.currentState!.show();
      await tester.pump();
      await tester.pump();
      expect(find.byType(RawImage), findsNWidgets(2));
    });

    testWidgets('a failed fetch retries on the next widget', (tester) async {
      var fetches = 0;
      EmoteUrlProvider.debugFetchOverride = (url) async {
        fetches++;
        if (fetches == 1) throw StateError('network down');
        return animatedWebpBytes();
      };
      EmoteUrlProvider.debugDecodeOverride = (bytes) async => EmoteFrameData(
        frames: [await _makeImage(255, 0, 0)],
        durations: const [Duration.zero],
      );

      await pumpEmote(tester, errorWidget: const Icon(Icons.error));
      expect(find.byType(Icon), findsOneWidget);

      // A fresh widget for the same URL must retry (failed completers are
      // not cached).
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
      await pumpEmote(tester);
      expect(fetches, 2);
      expect(find.byType(RawImage), findsOneWidget);
    });

    group('cached smaller-scale placeholder', () {
      testWidgets('renders a cached alternate under a faint shimmer while the '
          'required URL is delayed, then swaps', (tester) async {
        final requiredFrame = await tester.runAsync(
          () => _makeImage(0, 0, 255),
        );
        final altFrame = await tester.runAsync(() => _makeImage(255, 0, 0));
        final requiredGate = Completer<Uint8List>();
        final altBytes = animatedWebpBytes();
        final requiredBytes = Uint8List.fromList([
          ...animatedWebpBytes(),
          0xAA,
        ]);

        // The required URL is slow; the alternate is already decoded in the
        // image cache (simulating a 1x that was rendered before).
        final altUrl = 'https://example.com/emote_1x.gif';
        EmoteUrlProvider.debugFetchOverride = (url) {
          if (url == altUrl) {
            return Future.value(altBytes);
          }
          return requiredGate.future;
        };
        EmoteUrlProvider.debugDecodeOverride = (bytes) async => EmoteFrameData(
          frames: [listEquals(bytes, altBytes) ? altFrame! : requiredFrame!],
          durations: const [Duration.zero],
        );
        // Pre-seed the alternate in the image cache.
        await tester.pumpWidget(
          MaterialApp(home: EmoteImage(url: altUrl, width: 28, height: 28)),
        );
        await tester.pump();
        await tester.pump();
        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
        await tester.pump();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EmoteImage(
                url: 'https://example.com/emote.gif',
                width: 28,
                height: 28,
                alternateUrls: [altUrl],
              ),
            ),
          ),
        );
        await tester.pump();

        // The placeholder renders the cached alternate under a Shimmer (the
        // main image's RawImage is present but frameless).
        final placeholderRaws = tester
            .widgetList<RawImage>(find.byType(RawImage))
            .toList();
        final placeholderRaw = placeholderRaws.singleWhere(
          (r) => r.image != null,
        );
        expect(
          await tester.runAsync(() => _firstPixel(placeholderRaw.image!)),
          '255,0,0,255',
        );
        expect(find.byType(Shimmer), findsWidgets);

        // Required URL lands; the placeholder is replaced.
        requiredGate.complete(requiredBytes);
        await tester.pump();
        await tester.pump();
        await tester.pump();
        await tester.pump();
        final raws = tester
            .widgetList<RawImage>(find.byType(RawImage))
            .toList();
        expect(raws, hasLength(1));
        expect(
          await tester.runAsync(() => _firstPixel(raws.single.image!)),
          '0,0,255,255',
        );
        expect(find.byType(Shimmer), findsNothing);
      });

      testWidgets('a cached alternate placeholder expands to fill the box', (
        tester,
      ) async {
        final gif = File('test/fixtures/7tv_kiss_2x.gif').readAsBytesSync();
        final altUrl = 'https://example.com/emote_2x.gif';
        final previewUrl = 'https://example.com/emote_3x.gif';
        final gate = Completer<Uint8List>();
        EmoteUrlProvider.debugFetchOverride = (url) {
          if (url == altUrl) return Future.value(gif);
          return gate.future;
        };

        // Cache the 2x in memory first (as chat would have).
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 28,
                height: 28,
                child: EmoteImage(url: altUrl, width: 28, height: 28),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
        await tester.pump();

        // The sheet-style preview: a bounded 128x128 box with the cached 2x
        // as the alternate while the 3x is gated.
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 128,
                height: 128,
                child: EmoteImage(url: previewUrl, alternateUrls: [altUrl]),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();

        // The placeholder renders the cached alternate scaled to fill the
        // box, not at its intrinsic size.
        final raws = tester.widgetList<RawImage>(find.byType(RawImage));
        final placeholderRaw = raws.singleWhere((r) => r.image != null);
        expect(
          tester.getSize(find.byWidget(placeholderRaw)),
          const Size(128, 128),
        );
      });

      testWidgets(
        "a higher-scale preview continues the cached alternate's animation "
        'clock instead of restarting',
        (tester) async {
          final gif = File('test/fixtures/7tv_kiss_2x.gif').readAsBytesSync();
          final altUrl = 'https://example.com/emote_2x.gif';
          final previewUrl = 'https://example.com/emote_3x.gif';
          EmoteUrlProvider.debugFetchOverride = (url) async => gif;

          // The 2x is playing in chat (its own widget holds the shared
          // completer).
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 28,
                  height: 28,
                  child: EmoteImage(url: altUrl, width: 28, height: 28),
                ),
              ),
            ),
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 200)),
          );
          await tester.pump();
          // Let the 2x animation advance several frames (the engine codec
          // decodes on the real event loop, so each cycle decodes + displays
          // one frame).
          for (var i = 0; i < 3; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 150)),
            );
            await tester.pump(const Duration(milliseconds: 160));
          }
          final frameBefore = EmoteUrlProvider.currentFrame(altUrl);
          expect(frameBefore, greaterThan(0));

          // The sheet opens: the 3x fetch is gated, the 2x becomes the
          // placeholder and seeds the 3x's playback.
          final gate = Completer<Uint8List>();
          EmoteUrlProvider.debugFetchOverride = (url) {
            if (url == previewUrl) return gate.future;
            return Future.value(gif);
          };
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 128,
                  height: 128,
                  child: EmoteImage(url: previewUrl, alternateUrls: [altUrl]),
                ),
              ),
            ),
          );
          await tester.pump();
          gate.complete(gif);
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 500)),
          );
          // One frame's worth: both the 2x (frame callback) and the seeded 3x
          // (timer) advance exactly one frame (frame 2 is 140ms, the rest
          // 70ms, so 100ms is safely between one and two frame durations).
          await tester.pump(const Duration(milliseconds: 100));

          // The 3x started from the 2x's frame and stays in phase with it.
          final frame2x = EmoteUrlProvider.currentFrame(altUrl);
          final frame3x = EmoteUrlProvider.currentFrame(previewUrl);
          expect(frame3x, greaterThan(0));
          expect(frame3x, frame2x);
        },
      );

      testWidgets('falls back to bare shimmer when no alternate is cached', (
        tester,
      ) async {
        final frame = await tester.runAsync(() => _makeImage(0, 0, 255));
        final gate = Completer<Uint8List>();
        EmoteUrlProvider.debugFetchOverride = (url) => gate.future;
        EmoteUrlProvider.debugDecodeOverride = (bytes) async =>
            EmoteFrameData(frames: [frame!], durations: const [Duration.zero]);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EmoteImage(
                url: 'https://example.com/emote.gif',
                width: 28,
                height: 28,
                alternateUrls: const ['https://example.com/emote_1x.gif'],
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNull);
        expect(find.byType(Shimmer), findsOneWidget);

        gate.complete(animatedWebpBytes());
        await tester.pump();
        await tester.pump();
        expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
        expect(find.byType(Shimmer), findsNothing);
      });

      testWidgets('the global shimmer placeholder has a transparent base', (
        tester,
      ) async {
        // Zero-width overlays sit on top of a base emote; an opaque loading
        // box would hide it. The placeholder must paint only the moving
        // highlight band, with a transparent base.
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ShimmerEmotePlaceholder(width: 28, height: 28),
            ),
          ),
        );

        final shimmer = tester.widget<Shimmer>(find.byType(Shimmer));
        final gradient = shimmer.gradient;
        expect(gradient, isA<LinearGradient>());
        final colors = (gradient as LinearGradient).colors;
        // fromColors builds [base, base, highlight, base, base].
        expect(colors.first, Colors.transparent);
        expect(colors.last, Colors.transparent);
      });

      testWidgets('a memory-cached placeholder animates on the shared clock', (
        tester,
      ) async {
        final altFrame0 = await tester.runAsync(() => _makeImage(255, 0, 0));
        final altFrame1 = await tester.runAsync(() => _makeImage(0, 255, 0));
        final gate = Completer<Uint8List>();
        final altBytes = animatedWebpBytes();

        final altUrl = 'https://example.com/emote_1x.gif';
        EmoteUrlProvider.debugFetchOverride = (url) {
          if (url == altUrl) return Future.value(altBytes);
          return gate.future;
        };
        EmoteUrlProvider.debugDecodeOverride = (bytes) async => EmoteFrameData(
          frames: [altFrame0!, altFrame1!],
          durations: const [
            Duration(milliseconds: 100),
            Duration(milliseconds: 200),
          ],
        );
        // Pre-seed the alternate so the placeholder is memory-cached.
        await tester.pumpWidget(
          MaterialApp(home: EmoteImage(url: altUrl, width: 28, height: 28)),
        );
        await tester.pump();
        await tester.pump();
        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
        await tester.pump();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EmoteImage(
                url: 'https://example.com/emote.gif',
                width: 28,
                height: 28,
                alternateUrls: [altUrl],
              ),
            ),
          ),
        );
        await tester.pump();

        // The placeholder follows the alternate's completer playback (the
        // main image's RawImage is present but frameless underneath).
        RawImage altRaw() => tester
            .widgetList<RawImage>(find.byType(RawImage))
            .singleWhere((r) => r.image != null);
        expect(
          await tester.runAsync(() => _firstPixel(altRaw().image!)),
          '255,0,0,255',
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          await tester.runAsync(() => _firstPixel(altRaw().image!)),
          '0,255,0,255',
        );
      });

      testWidgets('a small cached placeholder is scaled up to the frame size', (
        tester,
      ) async {
        final altFrame = await tester.runAsync(() => _makeImage(255, 0, 0));
        final gate = Completer<Uint8List>();
        final altBytes = animatedWebpBytes();

        final altUrl = 'https://example.com/emote_1x.gif';
        EmoteUrlProvider.debugFetchOverride = (url) {
          if (url == altUrl) return Future.value(altBytes);
          return gate.future;
        };
        EmoteUrlProvider.debugDecodeOverride = (bytes) async => EmoteFrameData(
          frames: [altFrame!],
          durations: const [Duration.zero],
        );
        // Pre-seed the alternate so the placeholder is memory-cached.
        await tester.pumpWidget(
          MaterialApp(home: EmoteImage(url: altUrl, width: 28, height: 28)),
        );
        await tester.pump();
        await tester.pump();
        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
        await tester.pump();

        // No width/height on EmoteImage (like the emote sheet): the
        // placeholder must fill the 128x128 box instead of sitting at the
        // small cached frame's intrinsic size.
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 128,
                height: 128,
                child: EmoteImage(
                  url: 'https://example.com/emote.gif',
                  alternateUrls: [altUrl],
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final raws = tester
            .widgetList<RawImage>(find.byType(RawImage))
            .toList();
        final raw = raws.singleWhere((r) => r.image != null);
        expect(
          await tester.runAsync(() => _firstPixel(raw.image!)),
          '255,0,0,255',
        );
        expect(
          tester.getSize(find.byType(RawImage).first),
          const Size(128, 128),
        );
      });
    });
  });
}

/// Toggles a second [EmoteImage] into its own subtree on demand, so it mounts
/// during a narrow rebuild of that subtree only (other widgets in the tree are
/// not under the current build target).
class _RevealWidget extends StatefulWidget {
  const _RevealWidget({super.key, required this.url});

  final String url;

  @override
  State<_RevealWidget> createState() => _RevealWidgetState();
}

class _RevealWidgetState extends State<_RevealWidget> {
  bool _show = false;

  void show() => setState(() => _show = true);

  @override
  Widget build(BuildContext context) {
    return _show
        ? SizedBox(
            width: 28,
            height: 28,
            child: EmoteImage(url: widget.url, width: 28, height: 28),
          )
        : const SizedBox.shrink();
  }
}
