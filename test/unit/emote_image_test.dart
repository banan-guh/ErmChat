import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shimmer/shimmer.dart';

import 'package:ermchat/widgets/emote_image.dart';

import '../helpers/gif_fixture.dart';

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
    EmoteClipRegistry.debugFetchOverride = null;
    EmoteClipRegistry.debugDecodeOverride = null;
    EmoteClipRegistry.instance.debugClear();
  });

  tearDown(() {
    EmoteClipRegistry.debugFetchOverride = null;
    EmoteClipRegistry.debugDecodeOverride = null;
    EmoteClipRegistry.instance.debugClear();
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

  group('EmoteClipRegistry', () {
    test('dedups concurrent acquires of the same URL', () async {
      var fetches = 0;
      EmoteClipRegistry.debugFetchOverride = (url) async {
        fetches++;
        return Uint8List.fromList('GIF89a'.codeUnits);
      };
      EmoteClipRegistry.debugDecodeOverride = (bytes) async => EmoteFrameData(
        frames: [await _makeImage(255, 0, 0)],
        durations: const [Duration.zero],
      );

      final url = 'https://example.com/emote.gif';
      final a = EmoteClipRegistry.instance.acquire(url);
      final b = EmoteClipRegistry.instance.acquire(url);
      await Future.wait([a, b]);
      expect(fetches, 1);

      EmoteClipRegistry.instance.release(url);
      EmoteClipRegistry.instance.release(url);
    });

    test('caps concurrent decodes with the semaphore', () async {
      var active = 0;
      var peak = 0;
      final releaseAll = Completer<void>();
      EmoteClipRegistry.debugFetchOverride = (url) async =>
          Uint8List.fromList('GIF89a'.codeUnits);
      EmoteClipRegistry.debugDecodeOverride = (bytes) async {
        active++;
        if (active > peak) peak = active;
        await releaseAll.future;
        final frame = await _makeImage(255, 0, 0);
        active--;
        return EmoteFrameData(
          frames: [frame],
          durations: const [Duration.zero],
        );
      };

      final urls = [
        for (var i = 0; i < 25; i++) 'https://example.com/emote_$i.gif',
      ];
      final acquires = [
        for (final url in urls) EmoteClipRegistry.instance.acquire(url),
      ];
      // Let the first wave reach the decode gate before releasing it.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(peak, lessThanOrEqualTo(10));
      releaseAll.complete();
      await Future.wait(acquires);
      for (final url in urls) {
        EmoteClipRegistry.instance.release(url);
      }
    });

    test(
      're-acquires after the last release uses cached frames (no re-fetch)',
      () async {
        var fetches = 0;
        EmoteClipRegistry.debugFetchOverride = (url) async {
          fetches++;
          return Uint8List.fromList('GIF89a'.codeUnits);
        };
        EmoteClipRegistry.debugDecodeOverride = (bytes) async => EmoteFrameData(
          frames: [await _makeImage(255, 0, 0)],
          durations: const [Duration.zero],
        );

        final url = 'https://example.com/emote.gif';
        await EmoteClipRegistry.instance.acquire(url);
        EmoteClipRegistry.instance.release(url);
        await EmoteClipRegistry.instance.acquire(url);
        // With the new "keep forever" behavior, re-acquire should use cached frames
        expect(fetches, 1);
        EmoteClipRegistry.instance.release(url);
      },
    );

    test('propagates fetch errors and retries on the next acquire', () async {
      var fetches = 0;
      EmoteClipRegistry.debugFetchOverride = (url) async {
        fetches++;
        if (fetches == 1) throw StateError('network down');
        return Uint8List.fromList('GIF89a'.codeUnits);
      };
      EmoteClipRegistry.debugDecodeOverride = (bytes) async => EmoteFrameData(
        frames: [await _makeImage(255, 0, 0)],
        durations: const [Duration.zero],
      );

      final url = 'https://example.com/emote.gif';
      await expectLater(
        EmoteClipRegistry.instance.acquire(url),
        throwsA(isA<StateError>()),
      );
      EmoteClipRegistry.instance.release(url);
      final retried = await EmoteClipRegistry.instance.acquire(url);
      expect(retried.frames, hasLength(1));
      expect(fetches, 2);
      EmoteClipRegistry.instance.release(url);
    });

    test('GIF bytes decode through the production pipeline', () async {
      EmoteClipRegistry.debugFetchOverride = (url) async => buildTestGif(
        pixels: const [0, 1, 0],
        transparent: const [false, true, false],
        delays: const [10, 25, 10],
      );

      final frames = await EmoteClipRegistry.instance.acquire(
        'https://x/em.gif',
      );
      expect(frames.isAnimated, isTrue);
      expect(frames.frames, hasLength(3));
      expect(frames.durations, const [
        Duration(milliseconds: 100),
        Duration(milliseconds: 250),
        Duration(milliseconds: 100),
      ]);
      EmoteClipRegistry.instance.release('https://x/em.gif');
    });

    test('PNG bytes route through the static engine-codec path', () async {
      EmoteClipRegistry.debugFetchOverride = (url) async =>
          img.encodePng(img.Image(width: 2, height: 2));

      final frames = await EmoteClipRegistry.instance.acquire(
        'https://x/em.png',
      );
      expect(frames.isAnimated, isFalse);
      expect(frames.frames, hasLength(1));
      expect(frames.frames.first.width, 2);
      EmoteClipRegistry.instance.release('https://x/em.png');
    });
  });

  group('real emote bytes decode through the production pipeline', () {
    Future<EmoteFrameData> decodeFile(String path) async {
      final bytes = File('test/fixtures/$path').readAsBytesSync();
      EmoteClipRegistry.debugFetchOverride = (url) async => bytes;
      final frames = await EmoteClipRegistry.instance.acquire(
        'file:///test/fixtures/$path',
      );
      EmoteClipRegistry.instance.release('file:///test/fixtures/$path');
      return frames;
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
      },
    );

    test('7TV animated GIF (annycatKISS) decodes all 47 frames', () async {
      final frames = await decodeFile('7tv_kiss_2x.gif');
      expect(frames.isAnimated, isTrue);
      expect(frames.frames, hasLength(47));
      expect(frames.durations, everyElement(isNot(Duration.zero)));
    });
  });

  group('EmoteImage widget', () {
    Future<void> pumpEmote(
      WidgetTester tester, {
      String url = 'https://example.com/emote.gif',
      Widget? placeholder,
      Widget? errorWidget,
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
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('shows the placeholder until the first frame', (tester) async {
      final frame = await tester.runAsync(() => _makeImage(255, 0, 0));
      final gate = Completer<Uint8List>();
      EmoteClipRegistry.debugFetchOverride = (url) => gate.future;
      EmoteClipRegistry.debugDecodeOverride = (bytes) async =>
          EmoteFrameData(frames: [frame!], durations: const [Duration.zero]);

      await pumpEmote(tester, placeholder: const Text('loading'));
      expect(find.byType(RawImage), findsNothing);
      expect(find.text('loading'), findsOneWidget);

      gate.complete(Uint8List.fromList('GIF89a'.codeUnits));
      // The fetch->decode->setState chain spans several microtask hops; the
      // second pump lets them all land.
      await tester.pump();
      await tester.pump();
      expect(find.byType(RawImage), findsOneWidget);
      expect(find.text('loading'), findsNothing);
    });

    testWidgets('shows the error widget when the fetch fails', (tester) async {
      EmoteClipRegistry.debugFetchOverride = (url) async =>
          throw StateError('boom');
      await pumpEmote(tester, errorWidget: const Icon(Icons.error));
      expect(find.byType(Icon), findsOneWidget);
      expect(find.byType(RawImage), findsNothing);
    });

    testWidgets('shows the error widget when the decode fails', (tester) async {
      EmoteClipRegistry.debugFetchOverride = (url) async =>
          Uint8List.fromList('GIF89a'.codeUnits);
      EmoteClipRegistry.debugDecodeOverride = (bytes) async =>
          throw StateError('bad bytes');
      await pumpEmote(tester, errorWidget: const Icon(Icons.error));
      expect(find.byType(Icon), findsOneWidget);
    });

    testWidgets('animates through frames at their durations', (tester) async {
      final frame0 = await tester.runAsync(() => _makeImage(255, 0, 0));
      final frame1 = await tester.runAsync(() => _makeImage(0, 0, 255));
      EmoteClipRegistry.debugFetchOverride = (url) async =>
          Uint8List.fromList('GIF89a'.codeUnits);
      EmoteClipRegistry.debugDecodeOverride = (bytes) async => EmoteFrameData(
        frames: [frame0!, frame1!],
        durations: const [
          Duration(milliseconds: 100),
          Duration(milliseconds: 200),
        ],
      );

      await pumpEmote(tester);
      RawImage raw() => tester.widget<RawImage>(find.byType(RawImage));
      expect(raw().image, same(frame0));

      await tester.pump(const Duration(milliseconds: 100));
      expect(raw().image, same(frame1));

      await tester.pump(const Duration(milliseconds: 200));
      expect(raw().image, same(frame0));

      await tester.pump(const Duration(milliseconds: 100));
      expect(raw().image, same(frame1));
    });

    testWidgets('two widgets with the same URL share one fetch', (
      tester,
    ) async {
      var fetches = 0;
      EmoteClipRegistry.debugFetchOverride = (url) async {
        fetches++;
        return Uint8List.fromList('GIF89a'.codeUnits);
      };
      EmoteClipRegistry.debugDecodeOverride = (bytes) async => EmoteFrameData(
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
      expect(find.byType(RawImage), findsNWidgets(2));
      expect(fetches, 1);
    });

    testWidgets('a new widget with a cached URL renders synchronously', (
      tester,
    ) async {
      final frame0 = await tester.runAsync(() => _makeImage(255, 0, 0));
      final frame1 = await tester.runAsync(() => _makeImage(0, 0, 255));
      EmoteClipRegistry.debugFetchOverride = (url) async =>
          Uint8List.fromList('GIF89a'.codeUnits);
      EmoteClipRegistry.debugDecodeOverride = (bytes) async => EmoteFrameData(
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
      }

      await pumpOne();
      expect(find.text('loading'), findsNothing);
      expect(find.byType(RawImage), findsOneWidget);

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
      expect(find.text('loading'), findsNothing);
      expect(find.byType(RawImage), findsOneWidget);
    });

    testWidgets('two widgets with the same URL stay in sync on one clock', (
      tester,
    ) async {
      final frame0 = await tester.runAsync(() => _makeImage(255, 0, 0));
      final frame1 = await tester.runAsync(() => _makeImage(0, 0, 255));
      EmoteClipRegistry.debugFetchOverride = (url) async =>
          Uint8List.fromList('GIF89a'.codeUnits);
      EmoteClipRegistry.debugDecodeOverride = (bytes) async => EmoteFrameData(
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
      }

      await pumpTwo();
      final raws = tester.widgetList<RawImage>(find.byType(RawImage)).toList();
      expect(raws, hasLength(2));
      expect(raws[0].image, same(frame0));
      expect(raws[1].image, same(frame0));

      await tester.pump(const Duration(milliseconds: 100));
      final raws2 = tester.widgetList<RawImage>(find.byType(RawImage)).toList();
      expect(raws2[0].image, same(frame1));
      expect(raws2[1].image, same(frame1));
    });

    group('cached smaller-scale placeholder', () {
      testWidgets('renders a cached alternate under a faint shimmer while the '
          'required URL is delayed, then swaps', (tester) async {
        final requiredFrame = await tester.runAsync(
          () => _makeImage(0, 0, 255),
        );
        final altFrame = await tester.runAsync(() => _makeImage(255, 0, 0));
        final requiredGate = Completer<Uint8List>();
        final altBytes = Uint8List.fromList([1, 2, 3]);
        final requiredBytes = Uint8List.fromList([4, 5, 6]);

        // The required URL is slow; the alternate is already decoded in the
        // registry (simulating a 1x that was rendered before).
        final altUrl = 'https://example.com/emote_1x.gif';
        EmoteClipRegistry.debugFetchOverride = (url) {
          if (url == altUrl) {
            return Future.value(altBytes);
          }
          return requiredGate.future;
        };
        // URL-aware decode: the in-flight load captured this override at
        // acquire time, so it must distinguish the two URLs' bytes itself.
        EmoteClipRegistry.debugDecodeOverride = (bytes) async => EmoteFrameData(
          frames: [listEquals(bytes, altBytes) ? altFrame! : requiredFrame!],
          durations: const [Duration.zero],
        );
        // Pre-seed the registry with the alternate so the probe finds it.
        await EmoteClipRegistry.instance.acquire(altUrl);
        EmoteClipRegistry.instance.release(altUrl);
        // The registry keeps the decoded frames after release, so a later
        // acquire is instant.

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

        // The placeholder renders the cached alternate under a Shimmer.
        final raw = tester.widget<RawImage>(find.byType(RawImage));
        expect(raw.image, same(altFrame));
        expect(find.byType(Shimmer), findsWidgets);

        // Required URL lands; the placeholder is replaced.
        requiredGate.complete(requiredBytes);
        await tester.pump();
        await tester.pump();
        final raws = tester
            .widgetList<RawImage>(find.byType(RawImage))
            .toList();
        expect(raws, hasLength(1));
        expect(raws.single.image, same(requiredFrame));
        expect(find.byType(Shimmer), findsNothing);
      });

      testWidgets('falls back to bare shimmer when no alternate is cached', (
        tester,
      ) async {
        final frame = await tester.runAsync(() => _makeImage(0, 0, 255));
        final gate = Completer<Uint8List>();
        EmoteClipRegistry.debugFetchOverride = (url) => gate.future;
        EmoteClipRegistry.debugDecodeOverride = (bytes) async =>
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

        expect(find.byType(RawImage), findsNothing);
        expect(find.byType(Shimmer), findsOneWidget);

        gate.complete(Uint8List.fromList([1, 2, 3]));
        await tester.pump();
        await tester.pump();
        expect(find.byType(RawImage), findsOneWidget);
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

      testWidgets(
        'a registry-sourced placeholder animates on the shared clock',
        (tester) async {
          final altFrame0 = await tester.runAsync(() => _makeImage(255, 0, 0));
          final altFrame1 = await tester.runAsync(() => _makeImage(0, 255, 0));
          final gate = Completer<Uint8List>();
          final altBytes = Uint8List.fromList([1, 2, 3]);

          final altUrl = 'https://example.com/emote_1x.gif';
          EmoteClipRegistry.debugFetchOverride = (url) {
            if (url == altUrl) return Future.value(altBytes);
            return gate.future;
          };
          EmoteClipRegistry.debugDecodeOverride = (bytes) async =>
              EmoteFrameData(
                frames: [altFrame0!, altFrame1!],
                durations: const [
                  Duration(milliseconds: 100),
                  Duration(milliseconds: 200),
                ],
              );
          // Pre-seed the alternate clip so the placeholder is registry-sourced.
          await EmoteClipRegistry.instance.acquire(altUrl);
          EmoteClipRegistry.instance.release(altUrl);

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

          // The placeholder follows the alternate clip's shared playback clock.
          RawImage raw() => tester.widget<RawImage>(find.byType(RawImage));
          expect(raw().image, same(altFrame0));
          await tester.pump(const Duration(milliseconds: 100));
          expect(raw().image, same(altFrame1));
        },
      );

      testWidgets('a small cached placeholder is scaled up to the frame size', (
        tester,
      ) async {
        final altFrame = await tester.runAsync(() => _makeImage(255, 0, 0));
        final gate = Completer<Uint8List>();
        final altBytes = Uint8List.fromList([1, 2, 3]);

        final altUrl = 'https://example.com/emote_1x.gif';
        EmoteClipRegistry.debugFetchOverride = (url) {
          if (url == altUrl) return Future.value(altBytes);
          return gate.future;
        };
        EmoteClipRegistry.debugDecodeOverride = (bytes) async => EmoteFrameData(
          frames: [altFrame!],
          durations: const [Duration.zero],
        );
        // Pre-seed the alternate clip so the placeholder is registry-sourced.
        await EmoteClipRegistry.instance.acquire(altUrl);
        EmoteClipRegistry.instance.release(altUrl);

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

        final raw = tester.widget<RawImage>(find.byType(RawImage));
        expect(raw.image, same(altFrame));
        expect(tester.getSize(find.byType(RawImage)), const Size(128, 128));
      });

      testWidgets('swap seeds the required clip at the placeholder position', (
        tester,
      ) async {
        final altFrame0 = await tester.runAsync(() => _makeImage(255, 0, 0));
        final altFrame1 = await tester.runAsync(() => _makeImage(0, 255, 0));
        final requiredFrame0 = await tester.runAsync(
          () => _makeImage(0, 0, 255),
        );
        final requiredFrame1 = await tester.runAsync(
          () => _makeImage(255, 255, 0),
        );
        final requiredGate = Completer<Uint8List>();
        final altBytes = Uint8List.fromList([1, 2, 3]);
        final requiredBytes = Uint8List.fromList([4, 5, 6]);

        final altUrl = 'https://example.com/emote_1x.gif';
        final requiredUrl = 'https://example.com/emote.gif';
        EmoteClipRegistry.debugFetchOverride = (url) {
          if (url == altUrl) return Future.value(altBytes);
          return requiredGate.future;
        };
        EmoteClipRegistry.debugDecodeOverride = (bytes) async {
          if (listEquals(bytes, altBytes)) {
            return EmoteFrameData(
              frames: [altFrame0!, altFrame1!],
              durations: const [
                Duration(milliseconds: 100),
                Duration(milliseconds: 200),
              ],
            );
          }
          return EmoteFrameData(
            frames: [requiredFrame0!, requiredFrame1!],
            durations: const [
              Duration(milliseconds: 100),
              Duration(milliseconds: 200),
            ],
          );
        };
        // Pre-seed the alternate clip (registry-sourced placeholder).
        await EmoteClipRegistry.instance.acquire(altUrl);
        EmoteClipRegistry.instance.release(altUrl);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EmoteImage(
                url: requiredUrl,
                width: 28,
                height: 28,
                alternateUrls: [altUrl],
              ),
            ),
          ),
        );
        await tester.pump();

        // The placeholder advances to frame 1 (100ms into the loop).
        await tester.pump(const Duration(milliseconds: 100));
        RawImage raw() => tester.widget<RawImage>(find.byType(RawImage));
        expect(raw().image, same(altFrame1));

        // Required URL lands; the new clip must pick up at the same position
        // (frame 1), not restart from frame 0.
        requiredGate.complete(requiredBytes);
        await tester.pump();
        await tester.pump();
        final raws = tester
            .widgetList<RawImage>(find.byType(RawImage))
            .toList();
        expect(raws, hasLength(1));
        expect(raws.single.image, same(requiredFrame1));
        expect(find.byType(Shimmer), findsNothing);
      });
    });
  });
}
