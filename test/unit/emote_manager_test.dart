import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/services/emote_cache_manager.dart';
import '../helpers/fake_cache_repo.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ermchat/widgets/emote_loading_band.dart';
import 'package:ermchat/widgets/emote_image.dart';
import 'package:ermchat/widgets/emote_probe_memo.dart';
import 'package:ermchat/widgets/emote_image_provider.dart';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ermchat/models/emote_fetch_tier.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/services/emote_meta_store.dart';
import 'package:ermchat/services/emote_providers/bttv_emotes.dart';
import 'package:ermchat/services/emote_providers/ffz_emotes.dart';
import 'package:ermchat/services/emote_providers/seven_tv_emotes.dart';
import '../helpers.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/seven_tv_event_client.dart';
import 'package:ermchat/widgets/emote_text.dart';
import 'package:ermchat/models/twitch_command.dart';
import 'package:ermchat/services/suggestion.dart';
import 'package:ermchat/util/webp_anim.dart';

CacheObject _obj(String url, DateTime touched, {int? id}) => CacheObject(
  url,
  id: id,
  relativePath: 'file_${url.hashCode}.png',
  validTill: DateTime(2030),
  touched: touched,
);

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

class _FakePathProvider extends PathProviderPlatform {
  final String tempDir;
  _FakePathProvider(this.tempDir);

  @override
  Future<String?> getTemporaryPath() async => tempDir;

  @override
  Future<String?> getApplicationSupportPath() async => tempDir;
}

/// A cache manager with a no-op repo and an in-memory file system, so unit
/// tests exercise the cap/priority wiring without touching path_provider.
EmoteCacheManager testCacheManager() => EmoteCacheManager.forTesting(
  Config(
    'test',
    repo: NonStoringObjectProvider(),
    fileSystem: MemoryCacheSystem(),
  ),
);

ChannelEmotes _makeEmotes(Map<String, GenericEmote> byCode) {
  return ChannelEmotes(byCode: byCode, suggestions: byCode.values.toList());
}

Map<String, dynamic> _host(String name, {int width = 32, int height = 32}) => {
  'url': '//cdn.7tv.app/emote/1/1x',
  'files': [
    {'name': name, 'format': 'WEBP', 'width': width, 'height': height},
  ],
};

GenericEmote _e(String id, String code, [EmoteType type = EmoteType.bttv]) =>
    GenericEmote(
      id: id,
      code: code,
      type: type,
      url: 'https://example.com/$id.png',
    );

const _commands = <TwitchCommand>[
  TwitchCommand(name: '/me'),
  TwitchCommand(name: '/color'),
  TwitchCommand(name: '/ban'),
];

List<String> _codes(List<Suggestion> suggestions) =>
    suggestions.map((s) => s.displayText).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The meta store is a process-wide singleton with sticky state (resolved
    // directory, migration flag, in-memory fallback); tests must not inherit
    // each other's blobs.
    EmoteMetaStore.I.reset();
  });

  late FakeCacheRepo repo;
  late EmoteCacheManager manager;

  setUp(() {
    EmoteProbeMemo.instance.reset();
    repo = FakeCacheRepo();
    manager = EmoteCacheManager.forTesting(
      Config('test', repo: repo, fileSystem: MemoryCacheSystem()),
    );
  });

  test(
    'evicts down to maxObjects and makes room for writes by priority',
    () async {
      final t = DateTime(2026, 1, 1, 12);
      repo.seed([
        _obj('https://example.com/a.png', t, id: 1),
        _obj(
          'https://example.com/b.png',
          t.add(const Duration(hours: 1)),
          id: 2,
        ),
        _obj(
          'https://example.com/c.png',
          t.add(const Duration(hours: 2)),
          id: 3,
        ),
        _obj(
          'https://example.com/d.png',
          t.add(const Duration(hours: 3)),
          id: 4,
        ),
        _obj(
          'https://example.com/e.png',
          t.add(const Duration(hours: 4)),
          id: 5,
        ),
      ]);
      manager.maxObjects = 3;

      await manager.enforceNow();

      expect(repo.keys, [
        'https://example.com/c.png',
        'https://example.com/d.png',
        'https://example.com/e.png',
      ]);

      expect(await manager.isFull(), isTrue);

      // The write evicts the lowest-priority file (c, oldest by far) before
      // attempting the download. The mocked 400 download then fails, so the
      // repo keeps the two higher-priority files and gains nothing.
      await expectLater(
        manager.getFileStream('https://example.com/new.png'),
        emitsError(anything),
      );

      expect(repo.keys, [
        'https://example.com/d.png',
        'https://example.com/e.png',
      ]);
    },
  );

  test('registry priority overrides the file touched time', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([
      // a: recently touched on disk, but long-unused per the registry.
      _obj('https://example.com/a.png', t.add(const Duration(hours: 5)), id: 1),
      // b: long untouched on disk, but recently used per the registry.
      _obj('https://example.com/b.png', t, id: 2),
    ]);
    manager.maxObjects = 1;
    manager.priorityScore = (url) => url.contains('b.png') ? 1.0 : 0.0;

    await manager.enforceNow();

    expect(repo.keys, ['https://example.com/b.png']);
  });

  test('write-time eviction skips candidates within the read grace', () async {
    // All candidates were used/stored within the grace window, so nothing is
    // evictable and the write falls back to the temp-file path: the mocked
    // download fails but the repo stays untouched (the overflow grace is
    // covered by the 30s temp-file policy, not repo eviction).
    final t = DateTime.now();
    repo.seed([
      _obj('https://example.com/a.png', t, id: 1),
      _obj('https://example.com/b.png', t, id: 2),
      _obj('https://example.com/c.png', t, id: 3),
    ]);
    manager.maxObjects = 3;

    await expectLater(
      manager.getFileStream('https://example.com/new1.png'),
      emitsError(anything),
    );
    await expectLater(
      manager.getFileStream('https://example.com/new2.png'),
      emitsError(anything),
    );

    expect(repo.keys, hasLength(3));
  });

  test('write-time eviction picks the lowest-scored entry', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([
      _obj('https://example.com/a.png', t, id: 1),
      _obj('https://example.com/b.png', t, id: 2),
      _obj('https://example.com/c.png', t, id: 3),
    ]);
    manager.maxObjects = 3;
    // b is the lowest-scored emote even though it is not the oldest on disk.
    manager.priorityScore = (url) => switch (url) {
      'https://example.com/a.png' => 1.0,
      'https://example.com/b.png' => 0.2,
      _ => 0.9,
    };
    manager.lastUsedAt = (url) => t.add(const Duration(days: 1));

    await expectLater(
      manager.getFileStream('https://example.com/new.png'),
      emitsError(anything),
    );

    expect(repo.keys, [
      'https://example.com/a.png',
      'https://example.com/c.png',
    ]);
  });

  test('repeated isFull within the TTL reuses one repo scan', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([
      _obj('https://example.com/a.png', t, id: 1),
      _obj('https://example.com/b.png', t, id: 2),
    ]);
    manager.maxObjects = 3;

    // A burst of sequential fetches: each isFull must not re-scan the repo.
    expect(await manager.isFull(), isFalse);
    expect(await manager.isFull(), isFalse);
    expect(await manager.isFull(), isFalse);

    expect(repo.getAllObjectsCalls, 1);
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    EmoteUrlProvider.debugFetchOverride = null;
    EmoteUrlProvider.debugDecodeOverride = null;
    // Uncapped baseline: the production default (30) grid-aligns wake times,
    // which would stretch frame deltas across short pumps and skew the
    // timing-sensitive playback tests below. Cap behavior gets explicit
    // coverage in the 'emote fps cap' group.
    EmoteUrlProvider.fpsCap = 60;
    EmoteUrlProvider.alwaysAnimatePanel = true;
  });

  tearDown(() async {
    EmoteUrlProvider.debugFetchOverride = null;
    EmoteUrlProvider.debugDecodeOverride = null;
    EmoteUrlProvider.fpsCap = 60;
    EmoteUrlProvider.alwaysAnimatePanel = true;
    PaintingBinding.instance.imageCache.clearLiveImages();
    PaintingBinding.instance.imageCache.clear();
  });

  group('sniffEmoteFormat', () {
    Uint8List webpWithChunk(String fourcc) {
      return Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46, // RIFF
        0, 0, 0, 0, // size (unused by the sniff)
        0x57, 0x45, 0x42, 0x50, // WEBP
        ...fourcc.codeUnits, // chunk fourcc
        0x0A, 0x00, 0x00, 0x00, // chunk size
      ]);
    }

    test('sniffs GIF and WebP magic plus animated chunks', () {
      expect(
        sniffEmoteFormat(Uint8List.fromList('GIF89a'.codeUnits)),
        EmoteFormat.gif,
      );
      expect(
        sniffEmoteFormat(Uint8List.fromList('GIF87a'.codeUnits)),
        EmoteFormat.gif,
      );
      final webp = Uint8List.fromList('RIFF....WEBP'.codeUnits);
      expect(sniffEmoteFormat(webp), EmoteFormat.webp);
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

      expect(webpIsAnimated(webpWithChunk('ANMF')), isTrue);
      expect(webpIsAnimated(webpWithChunk('VP8 ')), isFalse);
      expect(webpIsAnimated(webpWithChunk('VP8L')), isFalse);
      expect(webpIsAnimated(webpWithChunk('VP8X')), isFalse);
      expect(webpIsAnimated(Uint8List(4)), isFalse);
      expect(
        webpIsAnimated(Uint8List.fromList('RIFF....WEBP'.codeUnits)),
        isFalse,
      );
    });
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

    test('7TV animated GIF (annycatKISS) decodes all 47 frames', () async {
      final frames = await decodeFile('7tv_kiss_2x.gif');
      expect(frames.isAnimated, isTrue);
      expect(frames.frames, hasLength(47));
      expect(frames.durations, everyElement(isNot(Duration.zero)));
      for (final f in frames.frames) {
        f.dispose();
      }
    });

    test('every decoded frame stays clone-able after the pipeline', () async {
      // Regression: the fallback compositor disposed previous outputs, which
      // the frames list still owned; playback clone() then threw "Cannot
      // clone a disposed image".
      final frames = await decodeFile('7tv_kiss_2x.webp');
      for (final f in frames.frames) {
        final clone = f.clone();
        clone.dispose();
      }
      for (final f in frames.frames) {
        f.dispose();
      }

      final bytes = File('test/fixtures/7tv_boink_2x.webp').readAsBytesSync();
      final meta = parseWebpAnim(bytes);
      expect(meta.frames, isNotEmpty);
      final compositor = WebpEngineCompositor(meta.canvasW, meta.canvasH);
      final outputs = <ui.Image>[];
      for (var i = 0; i < meta.frames.length && i < 5; i++) {
        final f = meta.frames[i];
        final codec = await ui.instantiateImageCodec(
          buildStandaloneFrameWebp(f),
        );
        final hi = await codec.getNextFrame();
        final prev = i > 0 ? meta.frames[i - 1] : null;
        outputs.add(await compositor.composite(prev, f, hi.image));
        hi.image.dispose();
        codec.dispose();
      }
      for (final out in outputs) {
        final clone = out.clone();
        clone.dispose();
      }
      for (final out in outputs) {
        out.dispose();
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
        expect(find.byType(LoadingBand), findsWidgets);

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

    testWidgets('shows the error widget when fetch or decode fails', (
      tester,
    ) async {
      EmoteUrlProvider.debugFetchOverride = (url) async =>
          throw StateError('boom');
      await pumpEmote(tester, errorWidget: const Icon(Icons.error));
      expect(find.byType(Icon), findsOneWidget);
      expect(find.byType(RawImage), findsNothing);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();

      EmoteUrlProvider.debugFetchOverride = (url) async => animatedWebpBytes();
      EmoteUrlProvider.debugDecodeOverride = (bytes) async =>
          throw StateError('bad bytes');
      await pumpEmote(
        tester,
        url: 'https://example.com/other.gif',
        errorWidget: const Icon(Icons.error),
      );
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

    testWidgets('two widgets with the same URL share one fetch and clock', (
      tester,
    ) async {
      var fetches = 0;
      final frame0 = await tester.runAsync(() => _makeImage(255, 0, 0));
      final frame1 = await tester.runAsync(() => _makeImage(0, 0, 255));
      EmoteUrlProvider.debugFetchOverride = (url) async {
        fetches++;
        return animatedWebpBytes();
      };
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
      expect(find.byType(RawImage), findsNWidgets(2));
      expect(fetches, 1);
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
      testWidgets(
        'a cached alternate shows under the band and expands to fill the box',
        (tester) async {
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
          EmoteUrlProvider.debugDecodeOverride = (bytes) async =>
              EmoteFrameData(
                frames: [
                  listEquals(bytes, altBytes) ? altFrame! : requiredFrame!,
                ],
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

          // The placeholder renders the cached alternate under a LoadingBand
          // (the main image's RawImage is present but frameless).
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
          expect(find.byType(LoadingBand), findsWidgets);

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
          expect(find.byType(LoadingBand), findsNothing);

          // A cached alternate placeholder expands to fill its box, not its
          // intrinsic size. The sheet-style preview uses a bounded 128x128
          // box with the cached 2x as the alternate while the 3x is gated.
          final gif = File('test/fixtures/7tv_kiss_2x.gif').readAsBytesSync();
          final bigAltUrl = 'https://example.com/emote_2x.gif';
          final previewUrl = 'https://example.com/emote_3x.gif';
          final bigGate = Completer<Uint8List>();
          EmoteUrlProvider.debugFetchOverride = (url) {
            if (url == bigAltUrl) return Future.value(gif);
            return bigGate.future;
          };
          EmoteUrlProvider.debugDecodeOverride = null;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 28,
                  height: 28,
                  child: EmoteImage(url: bigAltUrl, width: 28, height: 28),
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

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 128,
                  height: 128,
                  child: EmoteImage(
                    url: previewUrl,
                    alternateUrls: [bigAltUrl],
                  ),
                ),
              ),
            ),
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 200)),
          );
          await tester.pump();
          final bigRaws = tester.widgetList<RawImage>(find.byType(RawImage));
          final bigPlaceholder = bigRaws.singleWhere((r) => r.image != null);
          expect(
            tester.getSize(find.byWidget(bigPlaceholder)),
            const Size(128, 128),
          );
        },
      );

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
    });

    group('emote fps cap', () {
      test('wake alignment rounds up to the grid; zero disables it', () {
        expect(EmoteUrlProvider.alignWakeUsToGrid(70000, 33333), 99999);
        expect(EmoteUrlProvider.alignWakeUsToGrid(99999, 33333), 99999);
        expect(EmoteUrlProvider.alignWakeUsToGrid(100000, 33333), 133332);
        expect(EmoteUrlProvider.alignWakeUsToGrid(70000, 0), 70000);
        expect(EmoteUrlProvider.alignWakeUsToGrid(70000, -5), 70000);
      });

      Future<void> pumpCappedEmote(
        WidgetTester tester, {
        required bool uncapped,
      }) async {
        final frameColors = [
          [255, 0, 0],
          [0, 255, 0],
          [0, 0, 255],
          [255, 255, 0],
        ];
        final frames = [
          for (final c in frameColors)
            (await tester.runAsync(() => _makeImage(c[0], c[1], c[2])))!,
        ];
        EmoteUrlProvider.debugFetchOverride = (url) async =>
            animatedWebpBytes();
        EmoteUrlProvider.debugDecodeOverride = (bytes) async => EmoteFrameData(
          frames: frames,
          durations: const [
            Duration(milliseconds: 70),
            Duration(milliseconds: 70),
            Duration(milliseconds: 70),
            Duration(milliseconds: 70),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EmoteImage(
                url: 'https://example.com/capped.webp',
                uncapped: uncapped,
              ),
            ),
          ),
        );
        await tester.runAsync(() async {});
        await tester.pump();
      }

      testWidgets('a zero cap pauses playback until raised or bypassed', (
        tester,
      ) async {
        EmoteUrlProvider.fpsCap = 0;
        await pumpCappedEmote(tester, uncapped: false);
        expect(
          EmoteUrlProvider.currentFrame('https://example.com/capped.webp'),
          0,
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          EmoteUrlProvider.currentFrame('https://example.com/capped.webp'),
          0,
        );

        EmoteUrlProvider.applyFpsCap(30);
        // First tick re-anchors after the pause; the second advances.
        await tester.pump(const Duration(milliseconds: 10));
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          EmoteUrlProvider.currentFrame('https://example.com/capped.webp'),
          greaterThan(0),
        );

        EmoteUrlProvider.fpsCap = 0;
        await pumpCappedEmote(tester, uncapped: true);
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          EmoteUrlProvider.currentFrame('https://example.com/capped.webp'),
          greaterThan(0),
        );
      });
    });
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  group('GenericEmote JSON round-trip', () {
    test('serializes and deserializes', () {
      final original = makeTestEmote(
        id: 'test-id',
        code: 'TestEmote',
        type: EmoteType.sevenTv,
        isZeroWidth: true,
        isUnlisted: true,
        scope: EmoteScope.channel,
        ownerChannel: 'testuser',
        relativeScale: 0.625,
        baseName: 'AliasedEmote',
      );
      final json = original.toJson();
      final restored = GenericEmote.fromJson(json);
      expect(restored.id, original.id);
      expect(restored.code, original.code);
      expect(restored.type, original.type);
      expect(restored.isZeroWidth, original.isZeroWidth);
      expect(restored.isUnlisted, isTrue);
      expect(restored.scope, original.scope);
      expect(restored.ownerChannel, original.ownerChannel);
      expect(restored.url, original.url);
      expect(restored.relativeScale, original.relativeScale);
      expect(restored.baseName, 'AliasedEmote');
    });

    test('deserializes with defaults for missing fields', () {
      final json = <String, dynamic>{
        'id': 'test-id',
        'code': 'TestEmote',
        'type': 'bttv',
        'url': 'https://example.com/test.png',
      };
      final restored = GenericEmote.fromJson(json);
      expect(restored.id, 'test-id');
      expect(restored.isZeroWidth, false);
      expect(restored.scope, EmoteScope.global);
      expect(restored.isAnimated, false);
      expect(restored.ownerChannel, isNull);
      expect(restored.relativeScale, 1.0);
    });

    test('round-trips every EmoteType and EmoteScope value', () {
      for (final type in EmoteType.values) {
        final e = GenericEmote(
          id: '${type.index}',
          code: 'Test',
          type: type,
          url: '',
        );
        final json = e.toJson();
        final restored = GenericEmote.fromJson(json);
        expect(restored.type, type);
      }
      for (final scope in EmoteScope.values) {
        final e = GenericEmote(
          id: '1',
          code: 'Test',
          type: EmoteType.bttv,
          url: '',
          scope: scope,
        );
        final json = e.toJson();
        final restored = GenericEmote.fromJson(json);
        expect(restored.scope, scope);
      }
    });

    test('round-trips url1x/url3x', () {
      final original = GenericEmote(
        id: 'id-url',
        code: 'Emote',
        type: EmoteType.bttv,
        url: 'https://example.com/2x.png',
        url1x: 'https://example.com/1x.png',
        url3x: 'https://example.com/3x.png',
      );
      final restored = GenericEmote.fromJson(original.toJson());
      expect(restored.url1x, original.url1x);
      expect(restored.url3x, original.url3x);
    });

    test('recovers url3x from the legacy urlLarge key', () {
      final legacy = {
        'id': 'legacy-1',
        'code': 'Legacy',
        'type': 'sevenTv',
        'url': 'https://example.com/2x.png',
        'urlLarge': 'https://example.com/3x.png',
        'isAnimated': false,
        'scope': 'global',
        'relativeScale': 1.0,
        'aspectRatio': 1.0,
      };
      final restored = GenericEmote.fromJson(legacy);
      expect(restored.url1x, isNull);
      expect(restored.url3x, 'https://example.com/3x.png');
    });
  });

  group('7TV live updates', () {
    test('renaming a 7TV emote preserves baseName and ownerChannel', () async {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      manager.updateSevenTvEmotes(
        'ch',
        added: [
          GenericEmote(
            id: 'e1',
            code: 'OldName',
            type: EmoteType.sevenTv,
            url: 'https://example.com/e1.png',
            scope: EmoteScope.channel,
            ownerChannel: 'Creator',
            baseName: 'BaseEmote',
          ),
        ],
      );
      manager.updateSevenTvEmotes(
        'ch',
        renamed: {'e1': (newName: 'NewName', oldName: 'OldName')},
      );
      final emote = manager.byCode('ch')!.byCode['NewName'];
      expect(emote, isNotNull);
      expect(emote!.baseName, 'BaseEmote');
      expect(emote.ownerChannel, 'Creator');
    });

    GenericEmote sevenTv(String id, String code) => GenericEmote(
      id: id,
      code: code,
      type: EmoteType.sevenTv,
      url: 'https://example.com/$id.png',
      scope: EmoteScope.channel,
    );

    test(
      'incremental adds removes and renames keep suggestions sorted',
      () async {
        SharedPreferences.setMockInitialValues({});
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          removeCachedFile: (url) async {},
        );
        manager.updateSevenTvEmotes(
          'ch',
          added: [sevenTv('a', 'Alpha'), sevenTv('c', 'Charlie')],
        );
        manager.updateSevenTvEmotes('ch', added: [sevenTv('b', 'Bravo')]);

        var codes = manager
            .byCode('ch')!
            .suggestions
            .map((e) => e.code)
            .toList();
        expect(codes, ['Alpha', 'Bravo', 'Charlie']);

        manager.updateSevenTvEmotes('ch', removedIds: ['b']);
        await pumpEventQueue();

        final emotes = manager.byCode('ch')!;
        expect(emotes.byCode.keys, ['Alpha', 'Charlie']);
        expect(emotes.suggestions.map((e) => e.code).toList(), [
          'Alpha',
          'Charlie',
        ]);

        manager.updateSevenTvEmotes('ch', added: [sevenTv('b', 'Bravo')]);
        manager.updateSevenTvEmotes(
          'ch',
          renamed: {'c': (newName: 'Aaron', oldName: 'Charlie')},
        );

        codes = manager.byCode('ch')!.suggestions.map((e) => e.code).toList();
        expect(codes, ['Aaron', 'Alpha', 'Bravo']);
      },
    );

    test(
      'consumeChangedCodes tracks deltas and ignores non delta notifies',
      () async {
        SharedPreferences.setMockInitialValues({});
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          removeCachedFile: (url) async {},
        );
        manager.updateSevenTvEmotes(
          'ch',
          added: [sevenTv('a', 'Alpha'), sevenTv('b', 'Bravo')],
        );
        expect(manager.consumeChangedCodes('ch'), {'Alpha', 'Bravo'});

        manager.updateSevenTvEmotes('ch', removedIds: ['a']);
        await pumpEventQueue();
        expect(manager.consumeChangedCodes('ch'), {'Alpha'});

        manager.updateSevenTvEmotes(
          'ch',
          renamed: {'b': (newName: 'Beta', oldName: 'Bravo')},
        );
        expect(manager.consumeChangedCodes('ch'), {'Bravo', 'Beta'});
        expect(manager.consumeChangedCodes('ch'), isNull);

        // Renaming an emote that is not cached changes nothing, but the event
        // is still a live delta and not a full refetch.
        manager.updateSevenTvEmotes(
          'ch',
          renamed: {'missing': (newName: 'X', oldName: 'Y')},
        );
        final noOp = manager.consumeChangedCodes('ch');
        expect(noOp, isNotNull);
        expect(noOp, isEmpty);

        await manager.storeUserTwitchEmotes({'other': []});
        expect(manager.consumeChangedCodes('other'), isNull);
      },
    );

    test('removed emotes are evicted only when unused elsewhere', () async {
      SharedPreferences.setMockInitialValues({});
      final removed = <String>[];
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        removeCachedFile: (url) async => removed.add(url),
      );
      manager.updateSevenTvEmotes(
        'ch',
        added: [sevenTv('a', 'Alpha'), sevenTv('b', 'Bravo')],
      );

      manager.updateSevenTvEmotes('ch', removedIds: ['a']);
      await pumpEventQueue();

      expect(removed, contains('https://example.com/a.png'));
      expect(removed, isNot(contains('https://example.com/b.png')));

      removed.clear();
      manager.updateSevenTvEmotes('ch1', added: [sevenTv('a', 'Alpha')]);
      manager.updateSevenTvEmotes('ch2', added: [sevenTv('a', 'Alpha')]);
      manager.updateSevenTvEmotes('ch1', removedIds: ['a']);
      await pumpEventQueue();

      expect(removed, isEmpty);
    });

    test('a 7TV delta does not bump the span-cache version', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        removeCachedFile: (url) async {},
      );
      final before = manager.version;

      manager.updateSevenTvEmotes('ch', added: [sevenTv('a', 'Alpha')]);
      expect(manager.version, before);

      // Non-delta notifies (full refetches) still bump, so cached spans
      // recompute against the fresh data.
      await manager.storeUserTwitchEmotes({'ch': []});
      expect(manager.version, greaterThan(before));
    });

    test('a fetch re-load re-applies live 7TV deltas', () async {
      SharedPreferences.setMockInitialValues({
        'emotes3_ch': jsonEncode({
          'ts': DateTime.now().toIso8601String(),
          'tier': EmoteFetchTier.high.index,
          'emotes': [
            sevenTv('old', 'Old7tv').toJson(),
            makeTestEmote(id: 'n1', code: 'NonTwitch').toJson(),
          ],
        }),
      });
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        removeCachedFile: (url) async {},
      );
      await manager.resolveEmotes('ch', 'b1');

      // Live deltas: remove the persisted 7TV emote, add a new one.
      manager.updateSevenTvEmotes('ch', removedIds: ['old']);
      manager.updateSevenTvEmotes('ch', added: [sevenTv('live', 'LiveEmote')]);
      await pumpEventQueue();

      // Re-loading the still-fresh persisted cache must not clobber the
      // live state.
      await manager.resolveEmotes('ch', 'b1');

      final codes = manager
          .byCode('ch')!
          .suggestions
          .map((e) => e.code)
          .toList();
      expect(codes, contains('LiveEmote'));
      expect(codes, isNot(contains('Old7tv')));
      expect(codes, contains('NonTwitch'));
    });
  });

  group('7TV startup reconcile', () {
    GenericEmote sevenTv(String id, String code) => GenericEmote(
      id: id,
      code: code,
      type: EmoteType.sevenTv,
      url: 'https://example.com/$id.png',
      scope: EmoteScope.channel,
    );

    Map<String, Object> cache(List<GenericEmote> emotes) => {
      'emotes3_ch': jsonEncode({
        'ts': DateTime.now()
            .subtract(const Duration(hours: 1))
            .toIso8601String(),
        'emotes': emotes.map((e) => e.toJson()).toList(),
      }),
    };

    test('applies add/remove/rename deltas against the loaded cache', () async {
      SharedPreferences.setMockInitialValues(
        cache([
          sevenTv('a', 'Alpha'),
          sevenTv('b', 'Bravo'),
          sevenTv('c', 'Charlie'),
        ]),
      );
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async => SevenTvChannelResponse(
          emotes: [
            sevenTv('b', 'Bravo'),
            sevenTv('c', 'Charlee'),
            sevenTv('d', 'Delta'),
          ],
          emoteSetId: 'set1',
          userId: 'u1',
        ),
      );

      await manager.resolveEmotes('ch', 'b1');
      await pumpEventQueue();

      final codes = manager
          .byCode('ch')!
          .suggestions
          .map((e) => e.code)
          .toList();
      expect(codes, ['Bravo', 'Charlee', 'Delta']);
      expect(manager.getSevenTvEmoteSetId('ch'), 'set1');
      expect(manager.getSevenTvUserId('ch'), 'u1');
    });

    test('reconcile early returns keep the cache untouched', () async {
      Future<void> checkKept({
        required EmoteFetchTier tier,
        required String? broadcasterId,
        required Future<SevenTvChannelResponse> Function(
          String,
          EmoteResolution,
        )
        fetcher,
      }) async {
        SharedPreferences.setMockInitialValues(cache([sevenTv('a', 'Alpha')]));
        var fetched = false;
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          tier: tier,
          removeCachedFile: (url) async {},
          sevenTvChannelFetcher: (id, resolution) async {
            fetched = true;
            return fetcher(id, resolution);
          },
        );

        await manager.resolveEmotes('ch', broadcasterId);
        await pumpEventQueue();

        expect(fetched, isFalse);
        expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Alpha']);
      }

      await checkKept(
        tier: EmoteFetchTier.low,
        broadcasterId: 'b1',
        fetcher: (id, resolution) async =>
            SevenTvChannelResponse(emotes: [sevenTv('b', 'Bravo')]),
      );
      await checkKept(
        tier: EmoteFetchTier.medium,
        broadcasterId: null,
        fetcher: (id, resolution) async =>
            SevenTvChannelResponse(emotes: [sevenTv('b', 'Bravo')]),
      );

      SharedPreferences.setMockInitialValues(cache([sevenTv('a', 'Alpha')]));
      final failing = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async =>
            throw Exception('boom'),
      );

      await failing.resolveEmotes('ch', 'b1');
      await pumpEventQueue();

      expect(failing.byCode('ch')!.suggestions.map((e) => e.code), ['Alpha']);
    });
  });

  group('manual reload force fetch', () {
    GenericEmote sevenTv(String id, String code) => GenericEmote(
      id: id,
      code: code,
      type: EmoteType.sevenTv,
      url: 'https://example.com/$id.png',
      scope: EmoteScope.channel,
    );

    Map<String, Object> cache(List<GenericEmote> emotes) => {
      'emotes3_ch': jsonEncode({
        'ts': DateTime.now().toIso8601String(),
        'tier': EmoteFetchTier.medium.index,
        'emotes': emotes.map((e) => e.toJson()).toList(),
      }),
    };

    test('resolveEmotes force bypasses a fresh cache and refetches', () async {
      SharedPreferences.setMockInitialValues(cache([sevenTv('a', 'Alpha')]));
      var fetches = 0;
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async {
          fetches++;
          return SevenTvChannelResponse(
            emotes: [sevenTv('b', fetches == 1 ? 'Bravo' : 'Charlie')],
          );
        },
      );

      await manager.resolveEmotes('ch', 'b1');
      await pumpEventQueue();
      expect(fetches, 1);
      // The startup reconcile diffed the catalogue against the cache.
      expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Bravo']);

      manager.evictChannel('ch');
      await manager.resolveEmotes('ch', 'b1', force: true);
      await pumpEventQueue();
      expect(fetches, 2, reason: 'force must refetch the fresh channel');
      expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Charlie']);
    });

    test('preloadGlobalEmotes force refetches the 7tv catalogue', () async {
      SharedPreferences.setMockInitialValues({
        'emotes3_global': jsonEncode({
          'ts': DateTime.now().toIso8601String(),
          'tier': EmoteFetchTier.medium.index,
          'emotes': [
            makeTestEmote(
              id: 'g1',
              code: 'Stale7tv',
              type: EmoteType.sevenTv,
            ).toJson(),
          ],
        }),
      });
      var fetches = 0;
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
        removeCachedFile: (url) async {},
        sevenTvGlobalFetcher: (resolution) async {
          fetches++;
          return [
            makeTestEmote(id: 'g2', code: 'Fresh7tv', type: EmoteType.sevenTv),
          ];
        },
      );

      // Startup path on a fresh persisted cache never pulls the catalogue.
      await manager.preloadGlobalEmotes();
      expect(fetches, 0);

      // Reload path: force pulls it again.
      manager.evictGlobal();
      await manager.preloadGlobalEmotes(force: true);
      expect(fetches, 1, reason: 'force must refetch the 7tv catalogue');
      expect(manager.globalEmotesByProvider()['SevenTV']!.map((e) => e.code), [
        'Fresh7tv',
      ]);
    });
  });

  group('reload with a flaky provider', () {
    GenericEmote sevenTv(String id, String code) => GenericEmote(
      id: id,
      code: code,
      type: EmoteType.sevenTv,
      url: 'https://example.com/$id.png',
      scope: EmoteScope.channel,
    );

    Map<String, Object> channelCache(List<GenericEmote> emotes) => {
      'emotes3_ch': jsonEncode({
        'ts': DateTime.now().toIso8601String(),
        'tier': EmoteFetchTier.medium.index,
        'emotes': emotes.map((e) => e.toJson()).toList(),
      }),
    };

    Map<String, Object> globalCache(List<GenericEmote> emotes) => {
      'emotes3_global': jsonEncode({
        'ts': DateTime.now().toIso8601String(),
        'tier': EmoteFetchTier.medium.index,
        'emotes': emotes.map((e) => e.toJson()).toList(),
      }),
    };

    test(
      'failed reloads retain channel emotes and the persisted cache',
      () async {
        SharedPreferences.setMockInitialValues(
          channelCache([sevenTv('a', 'Alpha')]),
        );
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          tier: EmoteFetchTier.medium,
          removeCachedFile: (url) async {},
          sevenTvChannelFetcher: (id, resolution) async =>
              throw Exception('HTTP 429'),
        );

        await manager.resolveEmotes('ch', 'b1');
        await pumpEventQueue();
        expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Alpha']);

        manager.evictChannel('ch');
        await manager.resolveEmotes('ch', 'b1', force: true);
        await pumpEventQueue();

        expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Alpha']);

        final fresh = EmoteManager(
          fetchStagger: Duration.zero,
          tier: EmoteFetchTier.medium,
          removeCachedFile: (url) async {},
          sevenTvChannelFetcher: (id, resolution) async =>
              throw Exception('HTTP 429'),
        );
        await fresh.resolveEmotes('ch', 'b1');
        await pumpEventQueue();
        expect(fresh.byCode('ch')!.suggestions.map((e) => e.code), ['Alpha']);
      },
    );

    test(
      'force global preload with a failing 7tv fetch retains globals',
      () async {
        SharedPreferences.setMockInitialValues(
          globalCache([sevenTv('g', 'GAlpha')]),
        );
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          tier: EmoteFetchTier.medium,
          removeCachedFile: (url) async {},
          sevenTvGlobalFetcher: (resolution) async =>
              throw Exception('HTTP 429'),
        );

        await manager.preloadGlobalEmotes();
        expect(manager.byCode('ch')?.suggestions.map((e) => e.code), [
          'GAlpha',
        ]);

        manager.evictGlobal();
        await manager.preloadGlobalEmotes(force: true);
        expect(
          manager.byCode('ch')?.suggestions.map((e) => e.code),
          ['GAlpha'],
          reason:
              'a failed 7tv global fetch during reload must not wipe '
              'the global 7tv emotes',
        );
      },
    );

    test('failed fetches are reported per channel', () async {
      SharedPreferences.setMockInitialValues(
        channelCache([sevenTv('a', 'Alpha')]),
      );
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async =>
            throw Exception('HTTP 429'),
      );

      // Startup path: the failed reconcile and background twitch refresh
      // swallow their own errors and must not count as reload failures.
      await manager.resolveEmotes('ch', 'b1');
      await pumpEventQueue();
      expect(manager.takeFetchFailures(), isEmpty);

      // Reload path: the force fetch records the channel it failed for.
      manager.evictChannel('ch');
      await manager.resolveEmotes('ch', 'b1', force: true);
      await pumpEventQueue();
      expect(manager.takeFetchFailures(), ['ch']);
      expect(manager.takeFetchFailures(), isEmpty, reason: 'take clears');
    });

    test('retained stash entries survive failed and empty reloads', () async {
      SharedPreferences.setMockInitialValues({});
      var calls = 0;
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async {
          calls++;
          if (calls == 1) {
            return SevenTvChannelResponse(emotes: [sevenTv('a', 'Alpha')]);
          }
          throw Exception('HTTP 429');
        },
      );

      await manager.resolveEmotes('ch', 'b1', force: true);
      expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Alpha']);

      await manager.resolveEmotes('ch', 'b1', force: true);
      expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Alpha']);

      final bttvOnly = GenericEmote(
        id: 'bt',
        code: 'BttvThing',
        type: EmoteType.bttv,
        url: 'https://example.com/bt.png',
        scope: EmoteScope.channel,
      );
      EmoteMetaStore.I.reset();
      SharedPreferences.setMockInitialValues(channelCache([bttvOnly]));
      final healing = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async =>
            SevenTvChannelResponse(emotes: [sevenTv('a', 'Alpha')]),
      );

      await healing.resolveEmotes('ch', 'b1', force: true);
      await pumpEventQueue();
      expect(
        healing.byCode('ch')!.suggestions.map((e) => e.code),
        containsAll(['Alpha', 'BttvThing']),
      );

      final fresh = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async =>
            throw Exception('HTTP 429'),
      );
      await fresh.resolveEmotes('ch', 'b1');
      await pumpEventQueue();
      expect(
        fresh.byCode('ch')!.suggestions.map((e) => e.code),
        containsAll(['Alpha', 'BttvThing']),
      );
    });

    test('a pre-resolve delta does not override the full fetch', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async => SevenTvChannelResponse(
          emotes: [sevenTv('a', 'Alpha'), sevenTv('b', 'Bravo')],
        ),
      );

      // WS delta lands before the channel resolves (e.g. right after JOIN):
      // it renders immediately but is not a full set.
      manager.updateSevenTvEmotes('ch', added: [sevenTv('z', 'Zeta')]);
      expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Zeta']);

      // Full fetch rebuilds the set; the partial delta view must not be
      // re-applied over it via the live list.
      await manager.resolveEmotes('ch', 'b1');
      await pumpEventQueue();
      expect(manager.byCode('ch')!.suggestions.map((e) => e.code), [
        'Alpha',
        'Bravo',
      ]);
    });
  });

  group('low tier registry freeze', () {
    GenericEmote sevenTv(String id, String code) => GenericEmote(
      id: id,
      code: code,
      type: EmoteType.sevenTv,
      url: 'https://example.com/$id.png',
      scope: EmoteScope.channel,
    );

    // Old timestamp plus a foreign tier stamp: without the freeze this cache
    // would count as stale on both counts and trigger a refetch.
    Map<String, Object> frozenCache(List<GenericEmote> emotes) => {
      'emotes3_ch': jsonEncode({
        'ts': DateTime.now()
            .subtract(const Duration(days: 400))
            .toIso8601String(),
        'tier': EmoteFetchTier.high.index,
        'emotes': emotes.map((e) => e.toJson()).toList(),
      }),
    };

    EmoteManager lowManager(
      Future<SevenTvChannelResponse> Function(
        String channelId,
        EmoteResolution resolution,
      )?
      onChannelFetch,
    ) => EmoteManager(
      fetchStagger: Duration.zero,
      tier: EmoteFetchTier.low,
      removeCachedFile: (url) async {},
      sevenTvChannelFetcher: onChannelFetch,
    );

    test('a persisted cache freezes at low without refetching', () async {
      SharedPreferences.setMockInitialValues(
        frozenCache([sevenTv('a', 'Alpha')]),
      );
      var fetches = 0;
      final manager = lowManager((id, resolution) async {
        fetches++;
        return SevenTvChannelResponse(emotes: [sevenTv('b', 'Bravo')]);
      });

      await manager.resolveEmotes('ch', 'b1');
      await pumpEventQueue();

      expect(fetches, 0, reason: 'a seeded registry must never refetch');
      expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Alpha']);

      manager.evictChannel('ch');
      await manager.resolveEmotes('ch', 'b1', force: true);
      await pumpEventQueue();
      expect(fetches, 1, reason: 'force is the manual escape hatch');
      expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Bravo']);

      SharedPreferences.setMockInitialValues({
        'emotes3_global': jsonEncode({
          'ts': DateTime.now()
              .subtract(const Duration(days: 400))
              .toIso8601String(),
          'tier': EmoteFetchTier.high.index,
          'emotes': [
            makeTestEmote(
              id: 'g1',
              code: 'OldGlobal',
              type: EmoteType.sevenTv,
            ).toJson(),
          ],
        }),
      });
      var globalFetches = 0;
      final globalManager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.low,
        removeCachedFile: (url) async {},
        sevenTvGlobalFetcher: (resolution) async {
          globalFetches++;
          return [];
        },
      );

      await globalManager.preloadGlobalEmotes();
      await pumpEventQueue();

      expect(globalFetches, 0);
      expect(
        globalManager.globalEmotesByProvider()['SevenTV']!.map((e) => e.code),
        ['OldGlobal'],
      );

      SharedPreferences.setMockInitialValues({});
      var stashFetches = 0;
      final stashManager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.low,
        removeCachedFile: (url) async {},
        sevenTvGlobalFetcher: (resolution) async {
          stashFetches++;
          return [];
        },
      );

      await stashManager.ensureStashed({EmoteType.sevenTv});
      await pumpEventQueue();

      expect(stashFetches, 0);
    });

    test('a missing registry seeds exactly once at low', () async {
      SharedPreferences.setMockInitialValues({});
      var fetches = 0;
      final manager = lowManager((id, resolution) async {
        fetches++;
        return SevenTvChannelResponse(emotes: [sevenTv('a', 'Alpha')]);
      });

      await manager.resolveEmotes('ch', 'b1');
      await pumpEventQueue();
      expect(fetches, 1);
      expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Alpha']);

      // The seed was persisted; a later resolve must stay frozen.
      manager.evictChannel('ch');
      await manager.resolveEmotes('ch', 'b1');
      await pumpEventQueue();
      expect(fetches, 1, reason: 'the persisted seed must serve re-resolves');
      expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Alpha']);
    });
  });

  group('emote meta file store', () {
    late Directory dir;

    GenericEmote sevenTvOf(String id, String code) => GenericEmote(
      id: id,
      code: code,
      type: EmoteType.sevenTv,
      url: 'https://example.com/$id.png',
      scope: EmoteScope.channel,
    );

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ermchat_meta');
      EmoteMetaStore.I.overrideDirectory(dir);
      addTearDown(() => EmoteMetaStore.I.reset());
      addTearDown(() => dir.delete(recursive: true));
    });

    test('migrates legacy prefs blobs to files and deletes the keys', () async {
      SharedPreferences.setMockInitialValues({
        'emotes3_ch': '{"ts":"2026-01-01T00:00:00.000","tier":1,"emotes":[]}',
        'unrelated': 'stays',
      });
      final prefs = await SharedPreferences.getInstance();
      final store = EmoteMetaStore.I;

      await store.migrateFromPrefs(prefs);

      expect(File('${dir.path}/emotes3_ch.json').existsSync(), isTrue);
      expect(prefs.getString('emotes3_ch'), isNull);
      expect(prefs.getString('unrelated'), 'stays');
      // Idempotent: a second pass must not resurrect or fail.
      await store.migrateFromPrefs(prefs);
      expect(
        await store.read('emotes3_ch'),
        '{"ts":"2026-01-01T00:00:00.000","tier":1,"emotes":[]}',
      );
    });

    test('manager saves registries to files, never back to prefs', () async {
      SharedPreferences.setMockInitialValues({});
      var fetches = 0;
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.low,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async {
          fetches++;
          return SevenTvChannelResponse(emotes: [sevenTvOf('a', 'Alpha')]);
        },
      );

      await manager.resolveEmotes('ch', 'b1');
      await pumpEventQueue();

      expect(fetches, 1);
      expect(File('${dir.path}/emotes3_ch.json').existsSync(), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty, reason: 'prefs must stay blob-free');

      // A fresh manager hydrates from the file without a fetch. Low tier
      // keeps the background reconcile out of the picture entirely.
      var refetches = 0;
      final reloaded = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.low,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async {
          refetches++;
          return SevenTvChannelResponse(emotes: []);
        },
      );
      await reloaded.resolveEmotes('ch', 'b1');
      await pumpEventQueue();
      expect(refetches, 0);
      expect(reloaded.byCode('ch')!.suggestions.map((e) => e.code), ['Alpha']);
    });

    test('pruneStaleChannels drops dead channels and keeps global', () async {
      SharedPreferences.setMockInitialValues({});
      final store = EmoteMetaStore.I;
      await store.write('emotes3_global', '{}');
      await store.write('emotes3_kept', '{}');
      await store.write('emotes3_dead', '{}');

      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        removeCachedFile: (url) async {},
      );
      await manager.pruneStaleChannels({'kept'});

      expect(await store.keys(), containsAll(['emotes3_global']));
      expect(await store.keys(), isNot(contains('emotes3_dead')));
      expect(await store.keys(), contains('emotes3_kept'));
    });
  });

  group('provider stash restore', () {
    Map<String, Object> globalCacheJson(List<GenericEmote> emotes) => {
      'emotes3_global': jsonEncode({
        'ts': DateTime.now().toIso8601String(),
        'tier': EmoteFetchTier.medium.index,
        'emotes': emotes.map((e) => e.toJson()).toList(),
      }),
    };

    test(
      'prefs-restored caches toggle a provider offline via hydration',
      () async {
        SharedPreferences.setMockInitialValues(
          globalCacheJson([
            makeTestEmote(id: 'a', code: 'Hydra', type: EmoteType.sevenTv),
          ]),
        );
        var fetches = 0;
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          tier: EmoteFetchTier.medium,
          removeCachedFile: (url) async {},
          sevenTvGlobalFetcher: (resolution) async {
            fetches++;
            return [
              makeTestEmote(id: 'b', code: 'Fresh', type: EmoteType.sevenTv),
            ];
          },
        );

        await manager.preloadGlobalEmotes();
        expect(
          manager.globalEmotesByProvider()['SevenTV']!.map((e) => e.code),
          ['Hydra'],
        );

        await manager.setProviderEnabled(EmoteType.sevenTv, false);
        expect(manager.globalEmotesByProvider()['SevenTV'], isNull);

        await manager.setProviderEnabled(EmoteType.sevenTv, true);
        expect(
          manager.globalEmotesByProvider()['SevenTV']!.map((e) => e.code),
          ['Hydra'],
        );
        expect(fetches, 0, reason: 'restored stashes must rebuild offline');
      },
    );

    test(
      'ensureStashed refetches only providers with no retained data',
      () async {
        SharedPreferences.setMockInitialValues({
          ...globalCacheJson([
            makeTestEmote(id: 't1', code: 'KeptTwitch', type: EmoteType.twitch),
          ]),
          'emote_providers_disabled': ['sevenTv'],
        });
        var fetches = 0;
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          tier: EmoteFetchTier.medium,
          removeCachedFile: (url) async {},
          sevenTvGlobalFetcher: (resolution) async {
            fetches++;
            return [
              makeTestEmote(
                id: 'g2',
                code: 'Fresh7tv',
                type: EmoteType.sevenTv,
              ),
            ];
          },
        );

        await manager.preloadGlobalEmotes();
        // Enabling 7TV has nothing to restore from: the persisted cache was
        // stripped of it, so the rebuild keeps only the twitch emote.
        await manager.setProviderEnabled(EmoteType.sevenTv, true);
        expect(manager.globalEmotesByProvider()['SevenTV'], isNull);
        expect(manager.globalEmotesByProvider()['Twitch']!.map((e) => e.code), [
          'KeptTwitch',
        ]);

        await manager.ensureStashed({EmoteType.sevenTv});
        expect(fetches, 1);
        expect(
          manager.globalEmotesByProvider()['SevenTV']!.map((e) => e.code),
          ['Fresh7tv'],
        );
        expect(manager.globalEmotesByProvider()['Twitch']!.map((e) => e.code), [
          'KeptTwitch',
        ], reason: 'targeted refetch must not wipe other providers');

        // A second pass no-ops: the stash now covers 7TV.
        await manager.ensureStashed({EmoteType.sevenTv});
        expect(fetches, 1);
      },
    );
  });

  group('EmoteManager refresh policy', () {
    test(
      'refresh policy resolves TTLs across tiers and connectivity',
      () async {
        final failing = EmoteManager(
          probe: () async => throw Exception('probe failed'),
        );
        expect(
          await failing.effectiveTtlForTesting(),
          const Duration(hours: 12),
        );

        final unconfigured = EmoteManager();
        expect(
          await unconfigured.effectiveTtlForTesting(),
          const Duration(hours: 12),
        );

        final nothing = EmoteManager(
          tier: EmoteFetchTier.nothing,
          probe: () async => [ConnectivityResult.mobile],
        );
        expect(
          await nothing.effectiveTtlForTesting(),
          const Duration(days: 365000),
        );

        final mediumMobile = EmoteManager(
          tier: EmoteFetchTier.medium,
          probe: () async => [ConnectivityResult.mobile],
        );
        final mediumWifi = EmoteManager(
          tier: EmoteFetchTier.medium,
          probe: () async => [ConnectivityResult.wifi],
        );
        expect(
          await mediumMobile.effectiveTtlForTesting(),
          const Duration(hours: 24),
        );
        expect(
          await mediumWifi.effectiveTtlForTesting(),
          const Duration(hours: 24),
        );

        final highMobile = EmoteManager(
          tier: EmoteFetchTier.high,
          probe: () async => [ConnectivityResult.mobile],
        );
        final highWifi = EmoteManager(
          tier: EmoteFetchTier.high,
          probe: () async => [ConnectivityResult.wifi],
        );
        expect(
          await highMobile.effectiveTtlForTesting(),
          const Duration(hours: 24),
        );
        expect(
          await highWifi.effectiveTtlForTesting(),
          const Duration(hours: 12),
        );
      },
    );

    test('connectivity probe result is cached within the 60s window', () async {
      var probeCalls = 0;
      final manager = EmoteManager(
        probe: () async {
          probeCalls++;
          return [ConnectivityResult.mobile];
        },
      );

      await manager.effectiveTtlForTesting();
      await manager.effectiveTtlForTesting();

      expect(probeCalls, 1);
    });

    test('fetch queue serializes actions and survives failures', () async {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      final order = <int>[];

      await Future.wait([
        manager.enqueueFetchForTesting(() async => order.add(1)),
        manager.enqueueFetchForTesting(() async => order.add(2)),
        manager.enqueueFetchForTesting(() async => order.add(3)),
      ]);

      expect(order, [1, 2, 3]);

      await expectLater(
        manager.enqueueFetchForTesting(() async => throw Exception('boom')),
        throwsException,
      );
      await manager.enqueueFetchForTesting(() async => order.add(4));

      expect(order, [1, 2, 3, 4]);
    });

    test('fetch slots allow two in flight and queue the third', () async {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      final started = <String>[];
      final gates = [Completer<void>(), Completer<void>()];
      final f1 = manager.enqueueFetchForTesting(() async {
        started.add('a');
        await gates[0].future;
      });
      final f2 = manager.enqueueFetchForTesting(() async {
        started.add('b');
        await gates[1].future;
      });
      final f3 = manager.enqueueFetchForTesting(() async => started.add('c'));

      await Future<void>.delayed(Duration.zero);

      expect(started, containsAll(['a', 'b']));
      expect(started, isNot(contains('c')));

      gates[0].complete();
      await Future<void>.delayed(Duration.zero);

      expect(started, contains('c'));

      gates[1].complete();
      await Future.wait([f1, f2, f3]);
    });
  });

  group('subscriber emotes in channel cache', () {
    GenericEmote subEmote() => GenericEmote(
      id: 's1',
      code: 'SubEmote',
      type: EmoteType.twitch,
      url: 'https://example.com/s1.png',
      scope: EmoteScope.channel,
      tier: '3',
      emoteType: 'subscriptions',
    );

    Map<String, Object> persistedCache({required bool fresh}) {
      return {
        'emotes3_ch': jsonEncode({
          'ts': DateTime.now()
              .subtract(
                fresh ? const Duration(hours: 1) : const Duration(days: 2),
              )
              .toIso8601String(),
          'emotes': [makeTestEmote(id: 'n1', code: 'NonTwitch').toJson()],
        }),
      };
    }

    test(
      'persisted caches keep stored sub emotes whether fresh or stale',
      () async {
        for (final fresh in [true, false]) {
          SharedPreferences.setMockInitialValues(persistedCache(fresh: fresh));
          final manager = EmoteManager(fetchStagger: Duration.zero);
          await manager.storeUserTwitchEmotes({
            'ch': [subEmote()],
          });

          await manager.resolveEmotes('ch', 'b1');

          final codes = manager.byCode('ch')!.suggestions.map((e) => e.code);
          expect(codes, contains('SubEmote'));
          if (fresh) {
            expect(codes, contains('NonTwitch'));
          }
        }
      },
    );

    test(
      'storing sub emotes twice dedupes and fresh stores replace stale ones',
      () async {
        SharedPreferences.setMockInitialValues({});
        final manager = EmoteManager(fetchStagger: Duration.zero);
        final emote = subEmote();

        await manager.storeUserTwitchEmotes({
          'ch': [emote],
        });
        await manager.storeUserTwitchEmotes({
          'ch': [emote],
        });

        var subs = manager.subscriberEmotesByChannel()['ch']!;
        expect(subs.length, 1);
        expect(subs.single.code, 'SubEmote');

        final old = GenericEmote(
          id: 's1',
          code: 'OldEmote',
          type: EmoteType.twitch,
          url: 'https://example.com/s1.png',
          scope: EmoteScope.channel,
          tier: '3',
          emoteType: 'subscriptions',
        );
        final fresh = GenericEmote(
          id: 's1',
          code: 'FreshEmote',
          type: EmoteType.twitch,
          url: 'https://example.com/s1.png',
          scope: EmoteScope.channel,
          tier: '3',
          emoteType: 'subscriptions',
        );

        await manager.storeUserTwitchEmotes({
          'ch': [old],
        });
        await manager.storeUserTwitchEmotes({
          'ch': [fresh],
        });

        subs = manager.subscriberEmotesByChannel()['ch']!;
        expect(subs.length, 1);
        expect(subs.single.code, 'FreshEmote');
      },
    );

    test(
      'subs group by owner with storage fallback and alphabetical order',
      () async {
        SharedPreferences.setMockInitialValues({});
        final manager = EmoteManager(fetchStagger: Duration.zero);
        final emote = GenericEmote(
          id: 's1',
          code: 'SubEmote',
          type: EmoteType.twitch,
          url: 'https://example.com/s1.png',
          scope: EmoteScope.channel,
          tier: '3',
          emoteType: 'subscriptions',
          ownerChannel: 'alpha',
        );

        // The account-wide union fans into every open channel's store.
        await manager.storeUserTwitchEmotes({
          'a': [emote],
          'b': [emote],
        });

        var byChannel = manager.subscriberEmotesByChannel();
        expect(byChannel.keys, ['alpha']);
        expect(byChannel['alpha']!.length, 1);
        expect(byChannel['alpha']!.single.code, 'SubEmote');

        final fallbackManager = EmoteManager(fetchStagger: Duration.zero);
        await fallbackManager.storeUserTwitchEmotes({
          'ch': [subEmote()],
        });
        byChannel = fallbackManager.subscriberEmotesByChannel();
        expect(byChannel.keys, contains('ch'));

        GenericEmote subOf(String id, String code, String owner) =>
            GenericEmote(
              id: id,
              code: code,
              type: EmoteType.twitch,
              url: 'https://example.com/$id.png',
              scope: EmoteScope.channel,
              tier: '3',
              emoteType: 'subscriptions',
              ownerChannel: owner,
            );

        // The union fans both owners into every open channel's store; the
        // first-seen order inside the first storage channel is zeta before
        // alpha, which must not leak into the group order.
        final alphaManager = EmoteManager(fetchStagger: Duration.zero);
        await alphaManager.storeUserTwitchEmotes({
          'm': [
            subOf('z1', 'ZetaEmote', 'zeta'),
            subOf('a1', 'AlphaEmote', 'alpha'),
          ],
          'n': [
            subOf('a1', 'AlphaEmote', 'alpha'),
            subOf('z1', 'ZetaEmote', 'zeta'),
          ],
        });

        byChannel = alphaManager.subscriberEmotesByChannel();
        expect(byChannel.keys, containsAll(['alpha', 'zeta']));
        expect(
          byChannel.keys.toList().indexOf('alpha'),
          lessThan(byChannel.keys.toList().indexOf('zeta')),
        );
      },
    );

    test(
      'regression: distinct ownerId (unknown owner) keeps groups separate',
      () async {
        // The reported bug: when ownerChannel is unresolved, every sub emote
        // collapsed into the alphabetically-first storage channel. With ownerId
        // carried on the emote, each real owner must stay its own group.
        SharedPreferences.setMockInitialValues({});
        final manager = EmoteManager(fetchStagger: Duration.zero);
        GenericEmote sub(String id, String code, String ownerId) =>
            GenericEmote(
              id: id,
              code: code,
              type: EmoteType.twitch,
              url: 'https://example.com/$id.png',
              scope: EmoteScope.channel,
              tier: '1',
              emoteType: 'subscriptions',
              ownerId: ownerId,
            );

        // Account-wide union fanned into two open channels.
        await manager.storeUserTwitchEmotes({
          'a': [sub('x', 'X', 'ownerA'), sub('y', 'Y', 'ownerB')],
          'b': [sub('x', 'X', 'ownerA'), sub('y', 'Y', 'ownerB')],
        });

        final byChannel = manager.subscriberEmotesByChannel();
        expect(byChannel.keys, unorderedEquals(['ownerA', 'ownerB']));
        expect(byChannel['ownerA']!.map((e) => e.code), ['X']);
        expect(byChannel['ownerB']!.map((e) => e.code), ['Y']);
      },
    );

    test('ownerChannel takes precedence over ownerId for grouping', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(fetchStagger: Duration.zero);
      await manager.storeUserTwitchEmotes({
        'a': [
          GenericEmote(
            id: 'x',
            code: 'X',
            type: EmoteType.twitch,
            url: 'https://example.com/x.png',
            scope: EmoteScope.channel,
            tier: '1',
            emoteType: 'subscriptions',
            ownerId: 'ownerA',
            ownerChannel: 'chanA',
          ),
        ],
      });

      final byChannel = manager.subscriberEmotesByChannel();
      expect(byChannel.keys, ['chanA']);
    });

    test('ownerId round-trips through json', () {
      final emote = GenericEmote(
        id: 'x',
        code: 'X',
        type: EmoteType.twitch,
        url: 'https://example.com/x.png',
        ownerId: 'ownerA',
        ownerChannel: 'chanA',
      );
      final restored = GenericEmote.fromJson(emote.toJson());
      expect(restored.ownerId, 'ownerA');
      expect(restored.ownerChannel, 'chanA');
    });

    test('loadUserEmoteSets resolves owners and groups by login', () async {
      final auth = TwitchAuth()..accessToken = 'tok';
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        fetchUserEmoteSets: (ids, {accessToken, resolution}) async => {
          'ownerA': [
            GenericEmote(
              id: 'x',
              code: 'X',
              type: EmoteType.twitch,
              url: 'https://example.com/x.png',
              scope: EmoteScope.channel,
              tier: '1',
              emoteType: 'subscriptions',
              ownerId: 'ownerA',
            ),
          ],
        },
        resolveOwnerLogins: (a, ids) async => {
          for (final id in ids) id: 'login_$id',
        },
      );

      // ownerA is an open channel, so it's seeded without an API call.
      await manager.loadUserEmoteSets(['s1'], auth, {'chanA': 'ownerA'});
      final byChannel = manager.subscriberEmotesByChannel();
      expect(byChannel.keys, ['chanA']);
      expect(byChannel['chanA']!.single.code, 'X');
    });

    GenericEmote unlockedEmote() => GenericEmote(
      id: 'u1',
      code: 'PrimePride',
      type: EmoteType.twitch,
      url: 'https://example.com/u1.png',
      scope: EmoteScope.global,
      emoteType: 'prime',
    );

    GenericEmote ownedSubEmote() => GenericEmote(
      id: 'x',
      code: 'X',
      type: EmoteType.twitch,
      url: 'https://example.com/x.png',
      scope: EmoteScope.channel,
      tier: '1',
      emoteType: 'subscriptions',
      ownerId: 'ownerA',
    );

    test('loadUserEmoteSets stores owner-less unlocks globally', () async {
      final auth = TwitchAuth()..accessToken = 'tok';
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        fetchUserEmoteSets: (ids, {accessToken, resolution}) async => {
          '': [unlockedEmote()],
          'ownerA': [ownedSubEmote()],
        },
        resolveOwnerLogins: (a, ids) async => {
          for (final id in ids) id: 'login_$id',
        },
      );

      await manager.loadUserEmoteSets(['s1'], auth, {'chanA': 'ownerA'});

      // Unlock renders through the global lookup in every channel.
      expect(manager.byCode('chanA')?.byCode['PrimePride']?.id, 'u1');
      // Unlock is not misfiled as a subscriber emote.
      final subs = manager.subscriberEmotesByChannel()['chanA'] ?? const [];
      expect(subs.map((e) => e.code), contains('X'));
      expect(subs.map((e) => e.code), isNot(contains('PrimePride')));
    });

    test('unlockable-only sets are marked fetched', () async {
      var fetchCalls = 0;
      final auth = TwitchAuth()..accessToken = 'tok';
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        fetchUserEmoteSets: (ids, {accessToken, resolution}) async {
          fetchCalls++;
          return {
            '': [unlockedEmote()],
          };
        },
        resolveOwnerLogins: (a, ids) async => {},
      );

      await manager.loadUserEmoteSets(['s1'], auth, {'chanA': 'ownerA'});
      await manager.loadUserEmoteSets(['s1'], auth, {'chanA': 'ownerA'});

      expect(fetchCalls, 1);
      expect(manager.byCode('chanA')?.byCode['PrimePride']?.id, 'u1');
    });

    test('resetUserEmoteState clears unlocked global emotes', () async {
      final auth = TwitchAuth()..accessToken = 'tok';
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        fetchUserEmoteSets: (ids, {accessToken, resolution}) async => {
          '': [unlockedEmote()],
        },
        resolveOwnerLogins: (a, ids) async => {},
      );

      await manager.loadUserEmoteSets(['s1'], auth, {'chanA': 'ownerA'});
      expect(manager.byCode('chanA')?.byCode['PrimePride'], isNotNull);

      manager.resetUserEmoteState();

      expect(manager.byCode('chanA')?.byCode['PrimePride'], isNull);
    });

    test('reconnect heals unresolved owner labels without re-fetching', () async {
      final auth = TwitchAuth()..accessToken = 'tok';
      var resolveCalls = 0;
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        fetchUserEmoteSets: (ids, {accessToken, resolution}) async => {
          'ownerA': [
            GenericEmote(
              id: 'x',
              code: 'X',
              type: EmoteType.twitch,
              url: 'https://example.com/x.png',
              scope: EmoteScope.channel,
              tier: '1',
              emoteType: 'subscriptions',
              ownerId: 'ownerA',
            ),
          ],
          'ownerB': [
            GenericEmote(
              id: 'y',
              code: 'Y',
              type: EmoteType.twitch,
              url: 'https://example.com/y.png',
              scope: EmoteScope.channel,
              tier: '1',
              emoteType: 'subscriptions',
              ownerId: 'ownerB',
            ),
          ],
        },
        // First resolution fails (transient); reconnect recovers it.
        resolveOwnerLogins: (a, ids) async {
          resolveCalls++;
          if (resolveCalls == 1) return {};
          return {for (final id in ids) id: 'login_$id'};
        },
      );

      // First connect: no channels open, resolution unavailable -> nothing stored.
      await manager.loadUserEmoteSets(['s1', 's2'], auth, {});
      expect(manager.subscriberEmotesByChannel(), isEmpty);

      // Reconnect: channels now open (ownerA seeded, ownerB resolved via API).
      await manager.loadUserEmoteSets([], auth, {
        'chanA': 'ownerA',
        'chanB': 'ownerB',
      });
      final byChannel = manager.subscriberEmotesByChannel();
      expect(byChannel.keys, unorderedEquals(['chanA', 'chanB']));
      expect(byChannel['chanA']!.single.code, 'X');
      expect(byChannel['chanB']!.single.code, 'Y');
    });

    test('resetUserEmoteState clears stored sub emotes', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(fetchStagger: Duration.zero);
      await manager.storeUserTwitchEmotes({
        'ch': [subEmote()],
      });

      expect(manager.subscriberEmotesByChannel(), isNotEmpty);

      manager.resetUserEmoteState();

      expect(manager.subscriberEmotesByChannel(), isEmpty);
    });

    test('resetUserEmoteState removes subs from channel cache', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(fetchStagger: Duration.zero);
      await manager.storeUserTwitchEmotes({
        'ch': [subEmote()],
      });

      expect(
        manager.byCode('ch')!.suggestions.map((e) => e.code),
        contains('SubEmote'),
      );

      manager.resetUserEmoteState();

      final codes =
          manager.byCode('ch')?.suggestions.map((e) => e.code).toList() ?? [];
      expect(codes, isNot(contains('SubEmote')));
    });

    test(
      'fresh persisted cache does not leak old user subs after reset',
      () async {
        SharedPreferences.setMockInitialValues({
          'emotes3_ch': jsonEncode({
            'ts': DateTime.now()
                .subtract(const Duration(hours: 1))
                .toIso8601String(),
            'emotes': [
              subEmote().toJson(),
              makeTestEmote(id: 'n1', code: 'NonTwitch').toJson(),
            ],
          }),
        });
        final manager = EmoteManager(fetchStagger: Duration.zero);
        // First resolve: subs in the persisted cache are filtered out because
        // _channelTwitchEmotes is empty (subs come from USERSTATE, not disk).
        await manager.resolveEmotes('ch', 'b1');
        expect(
          manager.byCode('ch')!.suggestions.map((e) => e.code),
          contains('NonTwitch'),
        );

        // Simulate account switch.
        manager.resetUserEmoteState();
        await manager.resolveEmotes('ch', 'b1');

        final codes = manager
            .byCode('ch')!
            .suggestions
            .map((e) => e.code)
            .toList();
        expect(
          codes,
          isNot(contains('SubEmote')),
          reason: 'old user subs must not leak from persisted cache',
        );
        expect(codes, contains('NonTwitch'));
      },
    );
  });

  group('cache cap + usage registry', () {
    Future<EmoteManager> makeManager({
      required DateTime Function() clock,
      int cacheCap = defaultEmoteCacheMax,
      EmoteFetchTier tier = EmoteFetchTier.high,
      EmoteCacheManager? cache,
    }) async {
      PathProviderPlatform.instance = _FakePathProvider(
        Directory.systemTemp.path,
      );
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        now: clock,
        cacheCap: cacheCap,
        tier: tier,
        usageFlushDelay: Duration.zero,
        cacheManager: cache ?? testCacheManager(),
      );
      await manager.startCacheGc();
      manager.dispose();
      return manager;
    }

    List<GenericEmote> makeEmotes(int count) => [
      for (var i = 0; i < count; i++)
        GenericEmote(
          id: 'e$i',
          code: 'E$i',
          url: 'https://example.com/e$i.png',
          type: EmoteType.bttv,
        ),
    ];

    test('cacheCap setter forwards and clamps to the allowed range', () async {
      SharedPreferences.setMockInitialValues({});
      final cache = testCacheManager();
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        cacheManager: cache,
      );
      manager.cacheCap = 123;
      expect(manager.cacheCap, 123);
      expect(cache.maxObjects, 123);
      manager.cacheCap = 999999;
      expect(manager.cacheCap, maxEmoteCacheMax);
      manager.cacheCap = -5;
      expect(manager.cacheCap, minEmoteCacheMax);
    });

    test(
      'usage registry records views and persists across instances',
      () async {
        SharedPreferences.setMockInitialValues({});
        final clock = DateTime(2026, 1, 1, 12);
        final manager = await makeManager(clock: () => clock);
        manager.markEmoteViewed(makeEmotes(1)[0]);
        await manager.flushUsageForTesting();

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('emote_usage'),
          contains('https://example.com/e0.png'),
        );

        final cache = testCacheManager();
        await makeManager(clock: () => clock, cache: cache);
        final lastUsed = cache.lastUsedAt!('https://example.com/e0.png');
        expect(lastUsed, clock);
      },
    );

    test('markEmoteViewed flushes are debounced', () async {
      SharedPreferences.setMockInitialValues({});
      PathProviderPlatform.instance = _FakePathProvider(
        Directory.systemTemp.path,
      );
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        usageFlushDelay: const Duration(milliseconds: 50),
        now: () => DateTime(2026, 1, 1, 12),
        cacheManager: testCacheManager(),
      );
      await manager.startCacheGc();
      manager.dispose();

      final emotes = makeEmotes(3);
      manager.markEmoteViewed(emotes[0]);
      // Immediately after the first touch, nothing is persisted yet.
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('emote_usage'), isNull);

      // A burst of touches within the debounce window lands as one write.
      manager.markEmoteViewed(emotes[1]);
      manager.markEmoteViewed(emotes[2]);
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('emote_usage'), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      prefs = await SharedPreferences.getInstance();
      final persisted = prefs.getString('emote_usage');
      expect(persisted, contains('https://example.com/e0.png'));
      expect(persisted, contains('https://example.com/e1.png'));
      expect(persisted, contains('https://example.com/e2.png'));
    });

    test('enqueueSeenEmotes skips precache when the cap is zero', () async {
      SharedPreferences.setMockInitialValues({});
      final capped = EmoteManager(
        fetchStagger: Duration.zero,
        cacheCap: 0,
        usageFlushDelay: Duration.zero,
        now: () => DateTime(2026, 1, 1, 12),
        cacheManager: testCacheManager(),
      );
      capped.enqueueSeenEmotes(makeEmotes(7));
      expect(capped.precacheQueueLengthForTesting, 0);

      final uncapped = EmoteManager(
        fetchStagger: Duration.zero,
        usageFlushDelay: Duration.zero,
        now: () => DateTime(2026, 1, 1, 12),
        cacheManager: testCacheManager(),
      );
      uncapped.enqueueSeenEmotes(makeEmotes(7));
      // 7 emotes, 5 dequeued by the first step: 2 remain queued.
      expect(uncapped.precacheQueueLengthForTesting, 2);
    });

    test('one-time migration sets the flag once', () async {
      SharedPreferences.setMockInitialValues({});
      PathProviderPlatform.instance = _FakePathProvider(
        Directory.systemTemp.path,
      );
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        cacheManager: testCacheManager(),
      );
      await manager.startCacheGc();
      manager.dispose();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('emote_gc_migrated_v1'), isTrue);
      // v2 migration cleared the v1 DefaultCacheManager orphans once.
      expect(prefs.getBool('emote_gc_migrated_v2'), isTrue);

      // Second start skips migration and enforces the cap once more.
      final manager2 = EmoteManager(
        fetchStagger: Duration.zero,
        cacheManager: testCacheManager(),
      );
      await manager2.startCacheGc();
      manager2.dispose();
      expect(await SharedPreferences.getInstance(), isNotNull);
    });
  });

  group('nothing fetch tier guards', () {
    GenericEmote subEmote() => GenericEmote(
      id: 's1',
      code: 'SubEmote',
      type: EmoteType.twitch,
      url: 'https://example.com/s1.png',
      scope: EmoteScope.channel,
      tier: '3',
      emoteType: 'subscriptions',
    );

    test(
      'nothing tier loads persisted caches without fetching and groups providers',
      () async {
        final persisted = jsonEncode({
          'ts': DateTime.now()
              .subtract(const Duration(days: 1))
              .toIso8601String(),
          'tier': EmoteFetchTier.nothing.index,
          'emotes': [makeTestEmote(id: 'g1', code: 'GlobalE').toJson()],
        });
        SharedPreferences.setMockInitialValues({'emotes3_global': persisted});
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          tier: EmoteFetchTier.nothing,
        );

        await manager.preloadGlobalEmotes();

        expect(manager.byCode('any')!.byCode, contains('GlobalE'));
        expect(
          manager.globalEmotesByProvider().values.expand((e) => e),
          contains(predicate((GenericEmote e) => e.code == 'GlobalE')),
        );
        var prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('emotes3_global'), persisted);

        SharedPreferences.setMockInitialValues({
          'emotes3_ch': jsonEncode({
            'ts': DateTime.now().toIso8601String(),
            'tier': EmoteFetchTier.nothing.index,
            'emotes': [
              makeTestEmote(
                id: 'c1',
                code: 'ChanE',
                scope: EmoteScope.channel,
              ).toJson(),
            ],
          }),
        });
        final channelManager = EmoteManager(
          fetchStagger: Duration.zero,
          tier: EmoteFetchTier.nothing,
        );

        await channelManager.resolveEmotes('ch', 'b1');

        expect(channelManager.byCode('ch')!.byCode, contains('ChanE'));

        SharedPreferences.setMockInitialValues({});
        final emptyManager = EmoteManager(
          fetchStagger: Duration.zero,
          tier: EmoteFetchTier.nothing,
        );

        await emptyManager.resolveEmotes('ch', 'b1');

        expect(emptyManager.byCode('ch'), isNull);
        prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('emotes3_ch'), isNull);
      },
    );

    test(
      'globalEmotesByProvider groups by provider in display order',
      () async {
        final persisted = jsonEncode({
          'ts': DateTime.now()
              .subtract(const Duration(days: 1))
              .toIso8601String(),
          'tier': EmoteFetchTier.nothing.index,
          'emotes': [
            makeTestEmote(
              id: 'g1',
              code: 'A_Ffz',
              type: EmoteType.ffz,
            ).toJson(),
            makeTestEmote(
              id: 'g2',
              code: 'B_Bttv',
              type: EmoteType.bttv,
            ).toJson(),
            makeTestEmote(
              id: 'g3',
              code: 'C_Twitch',
              type: EmoteType.twitch,
            ).toJson(),
            makeTestEmote(
              id: 'g4',
              code: 'D_SevenTv',
              type: EmoteType.sevenTv,
            ).toJson(),
            makeTestEmote(
              id: 'g5',
              code: 'A_SevenTv',
              type: EmoteType.sevenTv,
            ).toJson(),
          ],
        });
        SharedPreferences.setMockInitialValues({'emotes3_global': persisted});
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          tier: EmoteFetchTier.nothing,
        );

        await manager.preloadGlobalEmotes();

        final byProvider = manager.globalEmotesByProvider();
        expect(byProvider.keys.toList(), [
          'SevenTV',
          'Twitch',
          'BetterTTV',
          'FrankerFaceZ',
        ]);
        // Each group is sorted by code.
        expect(byProvider['SevenTV']!.map((e) => e.code).toList(), [
          'A_SevenTv',
          'D_SevenTv',
        ]);
        expect(byProvider['Twitch']!.single.code, 'C_Twitch');
        expect(byProvider['BetterTTV']!.single.code, 'B_Bttv');
        expect(byProvider['FrankerFaceZ']!.single.code, 'A_Ffz');
      },
    );

    test('nothing tier skips stores usage tracking and precache', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.nothing,
      );

      await manager.storeUserTwitchEmotes({
        'ch': [subEmote()],
      });

      expect(manager.subscriberEmotesByChannel(), isEmpty);

      manager.updateSevenTvEmotes(
        'ch',
        added: [
          GenericEmote(
            id: 'e1',
            code: 'E1',
            type: EmoteType.sevenTv,
            url: 'https://example.com/e1.png',
            scope: EmoteScope.channel,
          ),
        ],
      );

      expect(manager.byCode('ch'), isNull);
    });

    test('enqueueSeenEmotes skips usage tracking and precache', () async {
      SharedPreferences.setMockInitialValues({});
      PathProviderPlatform.instance = _FakePathProvider(
        Directory.systemTemp.path,
      );
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.nothing,
        now: () => DateTime(2026, 1, 1, 12),
        cacheManager: testCacheManager(),
      );
      await manager.startCacheGc();
      manager.dispose();

      manager.enqueueSeenEmotes([
        GenericEmote(
          id: 'e1',
          code: 'E1',
          type: EmoteType.bttv,
          url: 'https://example.com/e1.png',
        ),
      ]);
      await pumpEventQueue();

      // The nothing tier never tracks usage or precaches.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('emote_usage'), isNull);
      expect(manager.precacheQueueLengthForTesting, 0);
    });
  });

  group('tier tag in persisted cache', () {
    Map<String, Object> channelCache({required int tier, int ageHours = 1}) => {
      'emotes3_ch': jsonEncode({
        'ts': DateTime.now()
            .subtract(Duration(hours: ageHours))
            .toIso8601String(),
        'tier': tier,
        'emotes': [
          makeTestEmote(
            id: 'c1',
            code: 'ChanE',
            scope: EmoteScope.channel,
          ).toJson(),
        ],
      }),
    };

    test(
      'mismatched tier tags refetch while matching tags stay fresh',
      () async {
        SharedPreferences.setMockInitialValues(
          channelCache(tier: EmoteFetchTier.low.index),
        );
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          tier: EmoteFetchTier.medium,
        );

        await manager.resolveEmotes('ch', 'b1');

        expect(manager.byCode('ch')!.byCode, contains('ChanE'));
        var data =
            jsonDecode((await EmoteMetaStore.I.read('emotes3_ch'))!)
                as Map<String, dynamic>;
        expect(data['tier'], EmoteFetchTier.medium.index);

        SharedPreferences.setMockInitialValues(
          channelCache(tier: EmoteFetchTier.medium.index),
        );
        final freshManager = EmoteManager(
          fetchStagger: Duration.zero,
          tier: EmoteFetchTier.medium,
        );

        await freshManager.resolveEmotes('ch', 'b1');

        expect(freshManager.byCode('ch')!.byCode, contains('ChanE'));
        data =
            jsonDecode((await EmoteMetaStore.I.read('emotes3_ch'))!)
                as Map<String, dynamic>;
        expect(data['tier'], EmoteFetchTier.medium.index);
      },
    );

    test('nothing and missing tier tags load without fetching', () async {
      SharedPreferences.setMockInitialValues(
        channelCache(tier: EmoteFetchTier.high.index),
      );
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.nothing,
      );

      await manager.resolveEmotes('ch', 'b1');

      // The stale cache (saved as tier 3) is still loaded and rendered;
      // nothing tier never fetches, so the emotes must come from disk.
      expect(manager.byCode('ch')!.byCode, contains('ChanE'));
      // No refetch: the persisted tier tag stays at 3.
      final data =
          jsonDecode((await EmoteMetaStore.I.read('emotes3_ch'))!)
              as Map<String, dynamic>;
      expect(data['tier'], EmoteFetchTier.high.index);

      SharedPreferences.setMockInitialValues({
        'emotes3_ch': jsonEncode({
          'ts': DateTime.now()
              .subtract(const Duration(minutes: 30))
              .toIso8601String(),
          'emotes': [
            makeTestEmote(
              id: 'c1',
              code: 'ChanE',
              scope: EmoteScope.channel,
            ).toJson(),
          ],
        }),
      });
      final legacyManager = EmoteManager(fetchStagger: Duration.zero);

      await legacyManager.resolveEmotes('ch', 'b1');

      expect(legacyManager.byCode('ch')!.byCode, contains('ChanE'));
      final legacyData =
          jsonDecode((await EmoteMetaStore.I.read('emotes3_ch'))!)
              as Map<String, dynamic>;
      expect(legacyData.containsKey('tier'), isFalse);
    });
  });

  group('EmoteUsageRecord scoring', () {
    // Unix hour for a fixed date.
    final hour = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch ~/ 3600000;
    final now = DateTime(2026, 1, 1, 12);

    EmoteUsageRecord record({
      required DateTime lastUsedAt,
      List<int>? buckets,
      int? base,
    }) => EmoteUsageRecord(
      lastUsedAt: lastUsedAt,
      bucketBase: base ?? hour,
      buckets: buckets ?? List.filled(24, 0),
    );

    test('recency extremes score from high to near zero', () {
      final fresh = EmoteUsageRecord.bumped(
        record(lastUsedAt: now),
        hour,
        now: now,
      );
      expect(fresh.score(now), greaterThan(0.9));

      final stale = EmoteUsageRecord.rolledForward(
        EmoteUsageRecord(
          lastUsedAt: now.subtract(const Duration(hours: 10 * 24)),
          bucketBase: hour - 10 * 24,
          buckets: List.filled(24, 1),
        ),
        hour,
      );
      expect(stale.score(now), lessThan(0.05));
      final dayOld = EmoteUsageRecord.rolledForward(
        EmoteUsageRecord(
          lastUsedAt: now.subtract(const Duration(hours: 24)),
          bucketBase: hour - 24,
          buckets: List.filled(24, 1),
        ),
        hour,
      );
      expect(dayOld.score(now), greaterThan(stale.score(now)));
    });

    test('steady and uniform use outrank burst and clustered use', () {
      // Steady: 40 uses spread evenly over the day, last use 3h ago.
      final steady = record(
        lastUsedAt: now.subtract(const Duration(hours: 3)),
        buckets: List.filled(24, 1)..[hour % 24] = 17,
      );
      // Burst: 100 uses all in one hour, 8h ago, silent since.
      final burst = record(
        lastUsedAt: now.subtract(const Duration(hours: 8)),
        buckets: List.filled(24, 0)..[(hour - 8) % 24] = 100,
      );
      final steadyScore = steady.score(now);
      final burstScore = burst.score(now);
      expect(steadyScore, greaterThan(burstScore));
      // The burst's entropy collapses its steady term, so its score stays close
      // to its recency (the lax 3-day window keeps recency high); the steady
      // record builds a real steady-term boost on top of its recency.
      final burstRecency = exp(-8 / (3 * 24));
      final steadyRecency = exp(-3 / (3 * 24));
      expect(burstScore, lessThan(burstRecency + 0.2));
      expect(steadyScore, greaterThan(steadyRecency + 0.3));

      final uniform = record(
        lastUsedAt: now.subtract(const Duration(hours: 1)),
        buckets: List.filled(24, 4),
      );
      final clustered = record(
        lastUsedAt: now.subtract(const Duration(hours: 1)),
        buckets: List.filled(24, 0)
          ..[hour % 24] = 48
          ..[(hour - 1) % 24] = 48,
      );
      expect(uniform.score(now), greaterThan(clustered.score(now)));
    });

    test('bumping rolls the window forward and ages out stale buckets', () {
      var r = record(lastUsedAt: now);
      r = EmoteUsageRecord.bumped(r, hour, now: now);
      // The roll on the hour+1 bump moves the window, so that hour's views
      // land in bucket 0.
      r = EmoteUsageRecord.bumped(
        r,
        hour + 1,
        now: now.add(const Duration(hours: 1)),
      );
      r = EmoteUsageRecord.bumped(
        r,
        hour + 1,
        now: now.add(const Duration(hours: 1)),
      );
      expect(r.buckets[0], 2);
      expect(r.bucketBase, hour + 1);
      // 25 hours later, everything has rolled out of the window.
      r = EmoteUsageRecord.rolledForward(r, hour + 25);
      expect(r.bucketBase, hour + 25);
      expect(r.buckets.every((b) => b == 0), isTrue);
    });

    test('json round-trip preserves buckets and last use', () {
      final r = record(
        lastUsedAt: now.subtract(const Duration(hours: 2)),
        buckets: List.filled(24, 0)..[hour % 24] = 5,
      );
      final parsed = EmoteUsageRecord.fromJson(r.toJson())!;
      expect(parsed.lastUsedAt, r.lastUsedAt);
      expect(parsed.bucketBase, r.bucketBase);
      expect(parsed.buckets, r.buckets);
      expect(parsed.score(now), r.score(now));
    });
  });

  group('EmoteFetchAutoMode helpers', () {
    test('effectiveEmoteFetchTier with auto off returns the manual tier', () {
      for (final tier in EmoteFetchTier.values) {
        expect(
          effectiveEmoteFetchTier(
            manual: tier,
            auto: EmoteFetchAutoMode.off,
            isMobile: false,
          ),
          tier,
        );
        expect(
          effectiveEmoteFetchTier(
            manual: tier,
            auto: EmoteFetchAutoMode.off,
            isMobile: true,
          ),
          tier,
        );
      }
    });

    test('balanced and aggressive pick tiers by connectivity', () {
      expect(
        effectiveEmoteFetchTier(
          manual: EmoteFetchTier.medium,
          auto: EmoteFetchAutoMode.balanced,
          isMobile: false,
        ),
        EmoteFetchTier.high,
      );
      expect(
        effectiveEmoteFetchTier(
          manual: EmoteFetchTier.medium,
          auto: EmoteFetchAutoMode.balanced,
          isMobile: true,
        ),
        EmoteFetchTier.low,
      );
      expect(
        effectiveEmoteFetchTier(
          manual: EmoteFetchTier.high,
          auto: EmoteFetchAutoMode.aggressive,
          isMobile: false,
        ),
        EmoteFetchTier.medium,
      );
      expect(
        effectiveEmoteFetchTier(
          manual: EmoteFetchTier.high,
          auto: EmoteFetchAutoMode.aggressive,
          isMobile: true,
        ),
        EmoteFetchTier.nothing,
      );
    });

    test('labels and subtitles cover every mode', () {
      expect(EmoteFetchAutoMode.values.length, 3);
      expect(EmoteFetchAutoMode.off.label, 'Off');
      expect(EmoteFetchAutoMode.balanced.label, 'Balanced');
      expect(EmoteFetchAutoMode.aggressive.label, 'Aggressive');
      for (final mode in EmoteFetchAutoMode.values) {
        expect(mode.subtitle, isNotEmpty);
      }
    });
  });

  group('EmoteText.build', () {
    test('plain text without emotes returns URL-parsed spans', () {
      var spans = EmoteText.build(
        text: 'hello world',
        twitchPositions: null,
        channelEmotes: null,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<TextSpan>());
      expect((spans[0] as TextSpan).text, 'hello world');

      final emotes = _makeEmotes(<String, GenericEmote>{});
      spans = EmoteText.build(
        text: 'hello world',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<TextSpan>());
      expect((spans[0] as TextSpan).text, 'hello world');
    });

    test('single known emote by text match returns WidgetSpan', () {
      final emotes = _makeEmotes({
        'Kappa': makeTestEmote(id: '1', code: 'Kappa'),
      });
      final spans = EmoteText.build(
        text: 'Kappa',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
    });

    test('text + emote + text mix returns correct span types', () {
      final emotes = _makeEmotes({
        'Kappa': makeTestEmote(id: '1', code: 'Kappa'),
      });
      final spans = EmoteText.build(
        text: 'hi Kappa there',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      // Contains at least one WidgetSpan for the emote
      expect(spans.any((s) => s is WidgetSpan), isTrue);
      expect(spans.length, greaterThanOrEqualTo(3));
    });

    test('Twitch emote position overrides text match', () {
      final emotes = _makeEmotes({
        'Kappa': makeTestEmote(id: '1', code: 'Kappa'),
        'KappaPride': makeTestEmote(
          id: '2',
          code: 'KappaPride',
          type: EmoteType.twitch,
        ),
      });
      final spans = EmoteText.build(
        text: 'KappaPride',
        twitchPositions: [
          EmotePosition(
            emoteId: '2',
            startIndex: 0,
            endIndex: 10,
            emoteCode: 'KappaPride',
          ),
        ],
        channelEmotes: emotes,
      );
      // Should match the Twitch emote (KappaPride), not a text match on Kappa
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
    });

    test('Twitch base emote + BTTV zero-width overlay', () {
      final emotes = _makeEmotes({
        'Sunglasses': makeTestEmote(
          id: 'tw-1',
          code: 'Sunglasses',
          type: EmoteType.twitch,
        ),
        'EZ': makeTestEmote(
          id: 'bttv-1',
          code: 'EZ',
          type: EmoteType.bttv,
          isZeroWidth: true,
        ),
      });
      final spans = EmoteText.build(
        text: 'Sunglasses EZ',
        twitchPositions: [
          EmotePosition(
            emoteId: 'tw-1',
            startIndex: 0,
            endIndex: 11,
            emoteCode: 'Sunglasses',
          ),
        ],
        channelEmotes: emotes,
      );
      // Sunglasses (from Twitch positions) should have EZ overlaid on it
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
    });

    test('URL detection in plain text segments', () {
      final emotes = _makeEmotes({
        'Kappa': makeTestEmote(id: '1', code: 'Kappa'),
      });
      final spans = EmoteText.build(
        text: 'Kappa check https://example.com',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      // Kappa (WidgetSpan) + ' check ' (text) + url (TextSpan with blue style)
      expect(spans.length, greaterThanOrEqualTo(3));
      expect(spans[0], isA<WidgetSpan>());
      expect(spans.last, isA<TextSpan>());
      final urlSpan = spans.last as TextSpan;
      expect(urlSpan.text, 'example.com', reason: 'scheme is humanized away');
      expect(urlSpan.style?.color, Colors.blue);
    });

    test('zero-width emote at start renders standalone', () {
      final emotes = _makeEmotes({
        'EZ': makeTestEmote(id: '1', code: 'EZ', isZeroWidth: true),
      });
      final spans = EmoteText.build(
        text: 'EZ',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      // Zero-width at start with no base should render as standalone WidgetSpan
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
    });

    test('zero-width after plain text breaks chain', () {
      final emotes = _makeEmotes({
        'Kappa': makeTestEmote(id: '1', code: 'Kappa'),
        'EZ': makeTestEmote(id: '2', code: 'EZ', isZeroWidth: true),
      });
      final spans = EmoteText.build(
        text: 'hello EZ',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      // 'hello' breaks the chain, so EZ renders as a standalone WidgetSpan.
      expect(spans.whereType<WidgetSpan>().length, 1);
      expect(spans.last, isA<WidgetSpan>());
      final text = spans.whereType<TextSpan>().map((s) => s.text).join();
      expect(text, contains('hello'));
    });

    test('zero-width overlays stack onto the preceding base emote', () {
      var emotes = _makeEmotes({
        'Kappa': makeTestEmote(id: '1', code: 'Kappa'),
        'EZ': makeTestEmote(id: '2', code: 'EZ', isZeroWidth: true),
      });
      var spans = EmoteText.build(
        text: 'Kappa EZ',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());

      emotes = _makeEmotes({
        'Kappa': makeTestEmote(id: '1', code: 'Kappa'),
        'EZ': makeTestEmote(id: '2', code: 'EZ', isZeroWidth: true),
        'HYPERS': makeTestEmote(id: '3', code: 'HYPERS', isZeroWidth: true),
      });
      spans = EmoteText.build(
        text: 'Kappa EZ HYPERS',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());

      emotes = _makeEmotes({
        'Kappa': makeTestEmote(id: '1', code: 'Kappa'),
        'EZ': makeTestEmote(id: '2', code: 'EZ', isZeroWidth: true),
        'PogChamp': makeTestEmote(id: '3', code: 'PogChamp'),
      });
      spans = EmoteText.build(
        text: 'Kappa EZ PogChamp',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      expect(spans.length, greaterThanOrEqualTo(2));
      expect(spans[0], isA<WidgetSpan>());
      expect(spans.last, isA<WidgetSpan>());
    });

    test('unknown token renders as plain text', () {
      final emotes = _makeEmotes({
        'Kappa': makeTestEmote(id: '1', code: 'Kappa'),
      });
      final spans = EmoteText.build(
        text: 'unknownToken',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<TextSpan>());
      expect((spans[0] as TextSpan).text, 'unknownToken');
    });

    test('sub emote from IRC tag renders via CDN even if not in API map', () {
      final emotes = _makeEmotes({});
      final spans = EmoteText.build(
        text: 'forsenPls',
        twitchPositions: [
          EmotePosition(
            emoteId: '12345',
            startIndex: 0,
            endIndex: 9,
            emoteCode: 'forsenPls',
          ),
        ],
        channelEmotes: emotes,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
    });

    test('scaled emotes size their boxes to the largest element', () {
      var emotes = _makeEmotes({
        'SmallEmote': makeTestEmote(
          id: '1',
          code: 'SmallEmote',
          relativeScale: 0.625,
        ),
      });
      var spans = EmoteText.build(
        text: 'SmallEmote',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
      var pad = (spans[0] as WidgetSpan).child as Padding;
      var box = pad.child as SizedBox;
      expect(box.width, 28.0 * 0.625);
      expect(box.height, 28.0 * 0.625);

      emotes = _makeEmotes({
        'SmallBase': makeTestEmote(
          id: '1',
          code: 'SmallBase',
          relativeScale: 0.5,
        ),
        'LargeOverlay': makeTestEmote(
          id: '2',
          code: 'LargeOverlay',
          isZeroWidth: true,
        ),
      });
      spans = EmoteText.build(
        text: 'SmallBase LargeOverlay',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
      pad = (spans[0] as WidgetSpan).child as Padding;
      box = pad.child as SizedBox;
      expect(box.width, 28.0);
      expect(box.height, 28.0);
    });

    group('sender proof', () {
      GenericEmote lockedSub(String code) => GenericEmote(
        id: 'sub-$code',
        code: code,
        type: EmoteType.twitch,
        url: 'https://example.com/sub-$code.png',
        scope: EmoteScope.channel,
        ownerChannel: 'somechannel',
        tier: '1000',
        emoteType: 'subscriptions',
      );

      GenericEmote follower(String code) => GenericEmote(
        id: 'fol-$code',
        code: code,
        type: EmoteType.twitch,
        url: 'https://example.com/fol-$code.png',
        scope: EmoteScope.channel,
        ownerChannel: 'somechannel',
        emoteType: 'follower',
      );

      String textOf(List<InlineSpan> spans) =>
          spans.whereType<TextSpan>().map((s) => s.text ?? '').join();

      test('locked sub codes need an IRC tag while follower codes do too', () {
        var spans = EmoteText.build(
          text: 'mySubEmote',
          twitchPositions: null,
          channelEmotes: _makeEmotes({'mySubEmote': lockedSub('mySubEmote')}),
        );
        expect(spans.any((s) => s is WidgetSpan), isFalse);
        expect(textOf(spans), contains('mySubEmote'));

        spans = EmoteText.build(
          text: 'mySubEmote',
          twitchPositions: const [
            EmotePosition(
              emoteId: 'sub-mySubEmote',
              startIndex: 0,
              endIndex: 10,
              emoteCode: 'mySubEmote',
            ),
          ],
          channelEmotes: _makeEmotes({'mySubEmote': lockedSub('mySubEmote')}),
        );
        expect(spans.any((s) => s is WidgetSpan), isTrue);

        spans = EmoteText.build(
          text: 'folEmote',
          twitchPositions: null,
          channelEmotes: _makeEmotes({'folEmote': follower('folEmote')}),
        );
        expect(spans.any((s) => s is WidgetSpan), isFalse);
        expect(textOf(spans), contains('folEmote'));

        spans = EmoteText.build(
          text: 'folEmote',
          twitchPositions: const [
            EmotePosition(
              emoteId: 'fol-folEmote',
              startIndex: 0,
              endIndex: 8,
              emoteCode: 'folEmote',
            ),
          ],
          channelEmotes: _makeEmotes({'folEmote': follower('folEmote')}),
        );
        expect(spans.any((s) => s is WidgetSpan), isTrue);
      });

      test('stranger subs stay text while unlocked emotes render', () {
        var spans = EmoteText.build(
          text: 'hi mySubEmote there',
          twitchPositions: null,
          channelEmotes: _makeEmotes({'mySubEmote': lockedSub('mySubEmote')}),
        );
        expect(spans.any((s) => s is WidgetSpan), isFalse);

        spans = EmoteText.build(
          text: 'KEKW',
          twitchPositions: null,
          channelEmotes: _makeEmotes({
            'KEKW': makeTestEmote(
              id: '7tv-KEKW',
              code: 'KEKW',
              type: EmoteType.sevenTv,
              scope: EmoteScope.channel,
            ),
          }),
        );
        expect(spans.any((s) => s is WidgetSpan), isTrue);

        spans = EmoteText.build(
          text: 'Kappa',
          twitchPositions: null,
          channelEmotes: _makeEmotes({
            'Kappa': makeTestEmote(
              id: 'global-Kappa',
              code: 'Kappa',
              type: EmoteType.twitch,
              scope: EmoteScope.global,
            ),
          }),
        );
        expect(spans.any((s) => s is WidgetSpan), isTrue);

        spans = EmoteText.build(
          text: 'PrimeBot',
          twitchPositions: null,
          channelEmotes: _makeEmotes({
            'PrimeBot': makeTestEmote(
              id: 'unlock-PrimeBot',
              code: 'PrimeBot',
              type: EmoteType.twitch,
              scope: EmoteScope.global,
            ),
          }),
        );
        expect(spans.any((s) => s is WidgetSpan), isTrue);
      });
    });
  });

  group('SevenTvEmoteProvider', () {
    test('parseOwnedSetIds keeps only personal sets', () {
      expect(
        SevenTvEmoteProvider.parseOwnedSetIds({
          'user': {
            'emote_sets': [
              {'id': 'set-1', 'name': 'Personal Emotes', 'flags': 4},
              {'id': 'set-2', 'name': 'Channel', 'flags': 0},
              {'id': 'set-3', 'name': 'Seasonal', 'flags': 0},
              {'id': 'set-4', 'name': 'No flags'},
              {'name': 'missing id', 'flags': 4},
            ],
          },
        }),
        ['set-1'],
      );
      expect(SevenTvEmoteProvider.parseOwnedSetIds({}), isEmpty);
    });

    test('isPersonalSet matches the personal flag only', () {
      expect(SevenTvEmoteProvider.isPersonalSet({'flags': 4}), isTrue);
      expect(SevenTvEmoteProvider.isPersonalSet({'flags': 0}), isFalse);
      expect(SevenTvEmoteProvider.isPersonalSet({}), isFalse);
      expect(SevenTvEmoteProvider.isPersonalSet({'flags': '4'}), isFalse);
    });

    test('parses plain alias owner and channel emotes', () {
      var emote = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-1',
        'name': 'PogChamp',
        'data': {'name': 'PogChamp', 'host': _host('1x.webp')},
      });
      expect(emote, isNotNull);
      expect(emote!.id, 'emote-1');
      expect(emote.code, 'PogChamp');
      expect(emote.baseName, isNull);
      expect(emote.type, EmoteType.sevenTv);

      emote = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-2',
        'name': 'ALIAS',
        'data': {'name': 'BaseEmote', 'host': _host('1x.webp')},
      });
      expect(emote, isNotNull);
      expect(emote!.code, 'ALIAS');
      expect(emote.baseName, 'BaseEmote');

      emote = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-3',
        'name': 'Cope',
        'data': {
          'name': 'Cope',
          'owner': {'display_name': 'CopeQueen'},
          'host': _host('1x.webp'),
        },
      });
      expect(emote, isNotNull);
      expect(emote!.ownerChannel, 'CopeQueen');

      emote = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-4',
        'name': 'xqcL',
        'data': {'name': 'xqcL', 'host': _host('1x.webp')},
      }, channel: true);
      expect(emote, isNotNull);
      expect(emote!.scope, EmoteScope.channel);
    });

    test('parses zero-width flag', () {
      final emote = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-5',
        'name': 'EZ',
        'data': {'name': 'EZ', 'flags': 1 << 8, 'host': _host('1x.webp')},
      });
      expect(emote, isNotNull);
      expect(emote!.isZeroWidth, isTrue);
    });

    test('flags unlisted emotes, keeps private-but-listed ones normal', () {
      final unlisted = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-8',
        'name': 'Secret',
        'data': {
          'name': 'Secret',
          'flags': 1 | (1 << 8),
          'listed': false,
          'host': _host('1x.webp'),
        },
      });
      expect(unlisted, isNotNull);
      expect(unlisted!.isUnlisted, isTrue);

      // The private flags bit is independent of listing: private-but-listed
      // emotes sit in channel sets and render fine.
      final privateListed = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-9',
        'name': '!fish',
        'data': {
          'name': '!fish',
          'flags': 1 | (1 << 8),
          'listed': true,
          'host': _host('1x.webp'),
        },
      });
      expect(privateListed, isNotNull);
      expect(privateListed!.isUnlisted, isFalse);
      expect(privateListed.isZeroWidth, isTrue);

      final missingListed = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-10',
        'name': 'Legacy',
        'data': {'name': 'Legacy', 'flags': 0, 'host': _host('1x.webp')},
      });
      expect(missingListed!.isUnlisted, isFalse);
    });

    test('picks 2x for chat and largest for large surfaces', () {
      final emote = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-6',
        'name': 'Size',
        'data': {
          'name': 'Size',
          'host': {
            'url': '//cdn.7tv.app/emote/size',
            'files': [
              {'name': '1x.webp', 'format': 'WEBP', 'width': 32, 'height': 32},
              {'name': '2x.webp', 'format': 'WEBP', 'width': 64, 'height': 64},
              {'name': '3x.webp', 'format': 'WEBP', 'width': 96, 'height': 96},
            ],
          },
        },
      });
      expect(emote, isNotNull);
      expect(emote!.url, 'https://cdn.7tv.app/emote/size/2x.webp');
      expect(emote.url1x, 'https://cdn.7tv.app/emote/size/1x.webp');
      expect(emote.url3x, 'https://cdn.7tv.app/emote/size/3x.webp');
      expect(emote.relativeScale, 1.0);
    });

    test('falls back to smallest file when no 2x tier exists', () {
      final emote = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-7',
        'name': 'Small',
        'data': {'name': 'Small', 'host': _host('1x.webp')},
      });
      expect(emote, isNotNull);
      expect(emote!.url, 'https://cdn.7tv.app/emote/1/1x/1x.webp');
      expect(emote.url1x, isNull);
      expect(emote.url3x, 'https://cdn.7tv.app/emote/1/1x/1x.webp');
    });

    group('resolution tiers', () {
      Map<String, dynamic> emote(List<String> names) => {
        'id': 'res-1',
        'name': 'Res',
        'data': {
          'name': 'Res',
          'host': {
            'url': '//cdn.7tv.app/emote/res',
            'files': [
              for (final n in names)
                {'name': n, 'format': 'WEBP', 'width': 32, 'height': 32},
            ],
          },
        },
      };

      const base = 'https://cdn.7tv.app/emote/res';

      test('low and medium pick the small scales without url3x', () {
        var e = SevenTvEmoteProvider.parseSingleEmote(
          emote(['1x.webp', '2x.webp', '3x.webp', '4x.webp']),
          resolution: EmoteResolution.low,
        );
        expect(e, isNotNull);
        expect(e!.url, '$base/1x.webp');
        expect(e.url1x, isNull);
        expect(e.url3x, isNull);

        e = SevenTvEmoteProvider.parseSingleEmote(
          emote(['1x.webp', '2x.webp', '3x.webp', '4x.webp']),
          resolution: EmoteResolution.medium,
        );
        expect(e, isNotNull);
        expect(e!.url, '$base/2x.webp');
        expect(e.url1x, '$base/1x.webp');
        expect(e.url3x, isNull);
      });

      test('high picks url3x and falls back to 2x without a 3x tier', () {
        var e = SevenTvEmoteProvider.parseSingleEmote(
          emote(['1x.webp', '2x.webp', '3x.webp', '4x.webp']),
        );
        expect(e, isNotNull);
        expect(e!.url, '$base/2x.webp');
        expect(e.url1x, '$base/1x.webp');
        expect(e.url3x, '$base/3x.webp');
        expect(e.url3x, isNot(contains('4x')));
        expect(e.url3x, isNot(contains('4x.webp')));

        e = SevenTvEmoteProvider.parseSingleEmote(
          emote(['1x.webp', '2x.webp', '4x.webp']),
        );
        expect(e, isNotNull);
        expect(e!.url1x, '$base/1x.webp');
        expect(e.url3x, '$base/2x.webp');
      });
    });
  });

  group('BttvEmoteProvider.parseEmotes', () {
    Map<String, dynamic> item(String code) => {
      'id': 'bttv-$code',
      'code': code,
      'imageType': 'png',
    };

    test('overlay and regular emotes parse with zero-width flags', () {
      for (final code in [
        'SoSnowy',
        'IceCold',
        'SantaHat',
        'TopHat',
        'ReinDeer',
        'CandyCane',
        'cvMask',
        'cvHazmat',
        'cvCompost',
      ]) {
        final emotes = BttvEmoteProvider.parseEmotes([item(code)]);
        expect(emotes, hasLength(1), reason: code);
        expect(emotes.single.isZeroWidth, isTrue, reason: code);
      }

      final regular = BttvEmoteProvider.parseEmotes([
        item('Kappa'),
        item('gachiBASS'),
      ]);
      expect(regular, hasLength(2));
      expect(regular.every((e) => !e.isZeroWidth), isTrue);

      final overlay = BttvEmoteProvider.parseEmotes([
        {...item('SoSnowy'), 'zeroWidth': true},
      ]);
      expect(overlay.single.isZeroWidth, isTrue);

      final forcedNormal = BttvEmoteProvider.parseEmotes([
        {'id': 'x', 'code': 'NotOnList', 'zeroWidth': true},
      ]);
      expect(forcedNormal.single.isZeroWidth, isTrue);
    });
  });

  group('FfzEmoteProvider.parseEmote', () {
    Map<String, dynamic> ffzItem({bool modifier = false}) => {
      'id': 42,
      'name': modifier ? 'HatOverlay' : 'RegularEmote',
      'urls': {'1': '//cdn.frankerfacez.com/emote/42/1'},
      if (modifier) 'modifier': true,
    };

    test('modifier and regular entries parse zero-width flags', () {
      var emote = FfzEmoteProvider.parseEmote(
        ffzItem(modifier: true),
        EmoteResolution.high,
      );
      expect(emote, isNotNull);
      expect(emote!.isZeroWidth, isTrue);

      emote = FfzEmoteProvider.parseEmote(ffzItem(), EmoteResolution.high);
      expect(emote, isNotNull);
      expect(emote!.isZeroWidth, isFalse);
    });
  });

  group('filterSuggestions', () {
    test('empty and non-matching queries return no suggestions', () {
      var result = filterSuggestions(
        word: 'xyz',
        emotes: [_e('1', 'Kappa'), _e('2', 'PogChamp')],
        users: {'user1', 'user2'},
      );
      expect(result, isEmpty);

      result = filterSuggestions(
        word: '',
        emotes: [_e('1', 'Kappa')],
        users: {'user1'},
      );
      expect(result, isEmpty);

      result = filterSuggestions(
        word: 'Pog',
        emotes: [_e('1', 'Kappa'), _e('2', 'PogChamp'), _e('3', 'LUL')],
        users: {},
      );
      expect(_codes(result), ['PogChamp']);

      result = filterSuggestions(
        word: 'alice',
        emotes: [],
        users: {'bob', 'carol'},
      );
      expect(result, isEmpty);
    });

    group('emote scoring', () {
      test('emote scoring ranks shorter exact and recent matches first', () {
        var result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'PogChamp'), _e('2', 'PogU'), _e('3', 'Pog')],
          users: {},
        );
        expect(_codes(result), ['Pog', 'PogU', 'PogChamp']);

        result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'POGX'), _e('2', 'PogX')],
          users: {},
        );
        expect(_codes(result), ['PogX', 'POGX']);

        result = filterSuggestions(
          word: 'wi',
          emotes: [_e('1', 'wikked'), _e('2', 'Wink')],
          users: {},
        );
        expect(_codes(result), ['Wink', 'wikked']);

        result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'PogChamp'), _e('2', 'PogU')],
          users: {},
          recentEmoteIds: {'1'},
        );
        expect(_codes(result), ['PogU', 'PogChamp']);

        result = filterSuggestions(
          word: 'pog',
          emotes: [_e('1', 'PogChamp')],
          users: {},
        );
        expect(_codes(result), ['PogChamp']);

        result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'PogChamp'), _e('1', 'PogChamp')],
          users: {},
        );
        expect(result.length, 1);
      });
    });

    group('users', () {
      test('user suggestions sort with penalties and type splits', () {
        var result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'PogU')],
          users: {'Pog'},
        );
        expect(_codes(result), ['Pog', 'PogU']);

        result = filterSuggestions(
          word: 'xq',
          emotes: [],
          users: {'xqcL', 'xqc'},
        );
        expect(_codes(result), ['xqc', 'xqcL']);

        final defaultResult = filterSuggestions(
          word: 'test',
          emotes: [_e('1', 'testEmote')],
          users: {'testUser'},
        );
        expect(defaultResult[0], isA<UserSuggestion>());

        final flipped = filterSuggestions(
          word: 'test',
          emotes: [_e('1', 'testEmote')],
          users: {'testUser'},
          preferEmotesFirst: true,
        );
        expect(flipped[0], isA<EmoteSuggestion>());
        expect(flipped[1], isA<UserSuggestion>());

        result = filterSuggestions(
          word: '7',
          emotes: [_e('1', 'pog7'), _e('2', '777'), _e('3', '17tv')],
          users: {'7up'},
        );
        expect(_codes(result), ['777', '7up', '17tv', 'pog7']);
      });
    });

    group('commands', () {
      test('slash queries match commands without emotes or users', () {
        var result = filterSuggestions(
          word: '/',
          emotes: [],
          users: {},
          commands: _commands,
        );
        expect(_codes(result), ['/me', '/color', '/ban']);

        result = filterSuggestions(
          word: '/b',
          emotes: [],
          users: {},
          commands: _commands,
        );
        expect(result.length, 1);
        expect(result[0], isA<CommandSuggestion>());
        expect(result[0].displayText, '/ban');

        result = filterSuggestions(
          word: '/ME',
          emotes: [],
          users: {},
          commands: _commands,
        );
        expect(result.length, 1);
        expect(result[0].displayText, '/me');

        result = filterSuggestions(
          word: '/me',
          emotes: [_e('1', 'me')],
          users: {'me', 'meUser'},
          commands: _commands,
        );
        expect(result.length, 1);
        expect(result[0], isA<CommandSuggestion>());
      });
    });
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('provider visibility toggles', () {
    Future<EmoteManager> seededManager() async {
      final persisted = jsonEncode({
        'ts': DateTime.now().toIso8601String(),
        'tier': EmoteFetchTier.nothing.index,
        'emotes': [
          makeTestEmote(id: 'b1', code: 'BttvE', type: EmoteType.bttv).toJson(),
          makeTestEmote(id: 'f1', code: 'FfzE', type: EmoteType.ffz).toJson(),
        ],
      });
      SharedPreferences.setMockInitialValues({'emotes3_global': persisted});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.nothing,
      );
      await manager.preloadGlobalEmotes();
      return manager;
    }

    test(
      'disabling and re-enabling a provider updates the merged caches',
      () async {
        final manager = await seededManager();
        expect(
          manager.byCode('ch')!.byCode.keys,
          containsAll(['BttvE', 'FfzE']),
        );
        expect(manager.isProviderEnabled(EmoteType.bttv), isTrue);

        await manager.setProviderEnabled(EmoteType.bttv, false);

        expect(manager.isProviderEnabled(EmoteType.bttv), isFalse);
        expect(manager.byCode('ch')!.byCode, isNot(contains('BttvE')));
        expect(manager.byCode('ch')!.byCode, contains('FfzE'));
        expect(
          manager.globalEmotesByProvider().keys,
          isNot(contains('BetterTTV')),
        );

        await manager.setProviderEnabled(EmoteType.bttv, true);

        expect(manager.byCode('ch')!.byCode, contains('BttvE'));
      },
    );

    test('the disabled set persists across manager instances', () async {
      final manager = await seededManager();
      await manager.setProviderEnabled(EmoteType.ffz, false);

      final next = EmoteManager(tier: EmoteFetchTier.nothing);
      expect(await next.enabledProviders(), {
        EmoteType.twitch,
        EmoteType.bttv,
        EmoteType.sevenTv,
      });
      expect(next.isProviderEnabled(EmoteType.ffz), isFalse);
    });

    test('twitch toggle hides subscriber emotes too', () async {
      SharedPreferences.setMockInitialValues({});
      // Low (not nothing): nothing skips storeUserTwitchEmotes entirely.
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.low,
      );
      await manager.storeUserTwitchEmotes({
        'ch': [
          GenericEmote(
            id: 's1',
            code: 'SubE',
            type: EmoteType.twitch,
            url: 'https://example.com/s1.png',
            tier: '1',
            emoteType: 'subscriptions',
            scope: EmoteScope.channel,
          ),
        ],
      });
      expect(manager.subscriberEmotesByChannel()['ch'], isNotEmpty);

      await manager.setProviderEnabled(EmoteType.twitch, false);

      expect(manager.subscriberEmotesByChannel(), isEmpty);
    });

    test('a legacy-disabled twitch provider is re-enabled on load', () async {
      SharedPreferences.setMockInitialValues({
        'emote_providers_disabled': ['twitch'],
      });
      final manager = EmoteManager(tier: EmoteFetchTier.nothing);

      expect(await manager.enabledProviders(), contains(EmoteType.twitch));

      // The persisted set is cleaned up too, so the migration sticks.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('emote_providers_disabled'), isEmpty);
    });

    test('unlisted 7TV emotes stay hidden until allowed and persist', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(fetchStagger: Duration.zero);
      await manager.enabledProviders();
      manager.updateSevenTvEmotes(
        'ch',
        added: [
          makeTestEmote(id: 'v1', code: 'Visible', type: EmoteType.sevenTv),
          makeTestEmote(
            id: 'u1',
            code: 'Secret',
            type: EmoteType.sevenTv,
            isUnlisted: true,
          ),
        ],
      );
      expect(manager.byCode('ch')!.byCode.keys, ['Visible']);

      await manager.setAllowUnlisted7tv(true);
      expect(
        manager.byCode('ch')!.byCode.keys,
        containsAll(['Visible', 'Secret']),
      );
      expect(manager.allowUnlisted7tv, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('emote_7tv_allow_unlisted'), isTrue);

      SharedPreferences.setMockInitialValues({
        'emote_7tv_allow_unlisted': true,
      });
      final next = EmoteManager(fetchStagger: Duration.zero);
      await next.enabledProviders();
      next.updateSevenTvEmotes(
        'ch',
        added: [
          makeTestEmote(
            id: 'u1',
            code: 'Secret',
            type: EmoteType.sevenTv,
            isUnlisted: true,
          ),
        ],
      );

      expect(next.byCode('ch')!.byCode.keys, ['Secret']);
    });
  });

  group('resolveRecentsForChannel', () {
    GenericEmote emote(String id, String code) => GenericEmote(
      id: id,
      code: code,
      type: EmoteType.sevenTv,
      url: 'https://example.com/$id.png',
    );

    test('recents resolve aliases dedupe and drop missing entries', () {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      var resolved = manager.resolveRecentsForChannel(
        [emote('x', 'Emote')],
        [emote('x', 'ThisEmote')],
      );
      expect(resolved.single.code, 'ThisEmote');

      resolved = manager.resolveRecentsForChannel(
        [emote('a', 'A'), emote('gone', 'Gone')],
        [emote('a', 'A2')],
      );
      expect(resolved.map((e) => e.code), ['A2']);

      resolved = manager.resolveRecentsForChannel(
        [emote('x', 'whatever')],
        [emote('x', 'Alpha'), emote('x', 'Beta')],
      );
      expect(resolved.single.code, 'Alpha');
    });

    test('recent order is preserved', () {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      final recents = [emote('b', 'B'), emote('a', 'A')];
      final channel = [emote('a', 'A'), emote('b', 'B')];

      final resolved = manager.resolveRecentsForChannel(recents, channel);

      expect(resolved.map((e) => e.id), ['b', 'a']);
    });
  });

  group('emote kernel verbs', () {
    GenericEmote twitchEmote(
      String id,
      String code, {
      String? tier,
      String? emoteType,
      String? ownerChannel,
    }) => GenericEmote(
      id: id,
      code: code,
      type: EmoteType.twitch,
      url: 'https://example.com/$id.png',
      scope: EmoteScope.channel,
      tier: tier,
      emoteType: emoteType,
      ownerChannel: ownerChannel,
    );

    test('kernel verbs expose sendable grouped and recent emotes', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(fetchStagger: Duration.zero);
      await manager.storeUserTwitchEmotes({
        'ch': [
          twitchEmote(
            's1',
            'SubEmote',
            tier: '1000',
            emoteType: 'subscriptions',
            ownerChannel: 'alpha',
          ),
        ],
      });

      final via = manager.sendableEmotes('ch').map((e) => e.id).toList();
      final direct = manager
          .byCode('ch')!
          .suggestions
          .map((e) => e.id)
          .toList();

      expect(via, direct);
      expect(via, contains('s1'));

      await manager.storeUserTwitchEmotes({
        'chA': [twitchEmote('x', 'Emote')],
        'chB': [twitchEmote('x', 'ThisEmote')],
      });
      await manager.markEmoteUsed(twitchEmote('x', 'Emote'));

      final resolved = await manager.recentsForChannel('chB');
      expect(resolved.single.code, 'ThisEmote');
    });
  });

  group('personal 7TV emotes', () {
    GenericEmote personal(String id, String code) => GenericEmote(
      id: id,
      code: code,
      type: EmoteType.sevenTv,
      url: 'https://example.com/$id.webp',
      scope: EmoteScope.global,
    );

    EmoteManager managerWith({
      List<String> ownedSetIds = const [],
      Map<String, List<GenericEmote>> sets = const {},
    }) => EmoteManager(
      fetchStagger: Duration.zero,
      sevenTvOwnedSetIdsFetcher: (_) async => ownedSetIds,
      sevenTvEmoteSetFetcher: (setId, _) async => sets[setId] ?? [],
    );

    SevenTvEntitlementEvent grant(
      String setId, {
      String kind = 'entitlement.create',
      List<String> twitchUserIds = const ['viewer-1'],
    }) => SevenTvEntitlementEvent(
      cosmeticId: setId,
      kind: kind,
      cosmeticKind: 'EMOTE_SET',
      twitchUserIds: twitchUserIds,
    );

    test(
      'personal sets bootstrap merge live grants and surface globally',
      () async {
        SharedPreferences.setMockInitialValues({});
        var manager = managerWith(
          ownedSetIds: ['set-1'],
          sets: {
            'set-1': [personal('p1', 'MyPersonal')],
          },
        );
        manager.viewerTwitchId = 'viewer-1';
        await manager.loadViewerPersonalSevenTvSets();

        expect(
          manager.byCode('anychannel')!.byCode.keys,
          contains('MyPersonal'),
        );
        expect(
          manager.sendableEmotes('anychannel').map((e) => e.code),
          contains('MyPersonal'),
        );
        expect(
          manager.globalEmotesByProvider()['SevenTV']?.map((e) => e.code) ?? [],
          contains('MyPersonal'),
        );

        manager = managerWith(
          sets: {
            'set-1': [personal('p1', 'LiveOne')],
          },
        );
        manager.viewerTwitchId = 'viewer-1';
        await manager.applySevenTvEntitlement(grant('set-1'));
        expect(manager.byCode('anychannel')!.byCode.keys, contains('LiveOne'));

        await manager.applySevenTvEntitlement(
          grant('set-1', kind: 'entitlement.delete'),
        );
        expect(
          manager.byCode('anychannel')?.byCode.keys ?? [],
          isNot(contains('LiveOne')),
        );
      },
    );

    test(
      'reset clears personal sets while channel sets win conflicts',
      () async {
        SharedPreferences.setMockInitialValues({});
        var manager = managerWith(
          ownedSetIds: ['set-1'],
          sets: {
            'set-1': [personal('p1', 'MyPersonal')],
          },
        );
        manager.viewerTwitchId = 'viewer-1';
        await manager.loadViewerPersonalSevenTvSets();
        expect(
          manager.byCode('anychannel')!.byCode.keys,
          contains('MyPersonal'),
        );

        manager.resetUserEmoteState();
        expect(
          manager.byCode('anychannel')?.byCode.keys ?? [],
          isNot(contains('MyPersonal')),
        );

        manager = managerWith(
          ownedSetIds: ['set-1'],
          sets: {
            'set-1': [personal('p1', 'Clash')],
          },
        );
        manager.viewerTwitchId = 'viewer-1';
        await manager.loadViewerPersonalSevenTvSets();
        await manager.storeUserTwitchEmotes({
          'ch': [
            GenericEmote(
              id: 'tw-1',
              code: 'Clash',
              type: EmoteType.twitch,
              url: 'https://example.com/tw-1.png',
              scope: EmoteScope.channel,
            ),
          ],
        });

        expect(manager.byCode('ch')!.byCode['Clash']!.id, 'tw-1');
      },
    );
  });

  group('foreign personal 7TV emotes', () {
    GenericEmote personal(String id, String code) => GenericEmote(
      id: id,
      code: code,
      type: EmoteType.sevenTv,
      url: 'https://example.com/$id.webp',
      scope: EmoteScope.global,
    );

    test('sender codes render only for that sender', () async {
      SharedPreferences.setMockInitialValues({});
      var listings = 0;
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        sevenTvOwnedSetIdsFetcher: (_) async {
          listings++;
          return ['set-1'];
        },
        sevenTvEmoteSetFetcher: (_, _) async => [personal('p1', 'TheirCode')],
      );
      await manager.ensureForeignPersonalSets(
        senderTwitchId: 'sender-1',
        channel: 'ch',
        text: 'TheirCode hello',
        positions: null,
      );
      expect(listings, 1);

      final senderMap = manager.byCodeForSender('ch', 'sender-1')!;
      expect(senderMap.byCode.keys, contains('TheirCode'));
      expect(
        manager.byCode('ch')?.byCode.keys ?? [],
        isNot(contains('TheirCode')),
      );
      expect(
        manager.byCodeForSender('ch', 'sender-2')?.byCode.keys ?? [],
        isNot(contains('TheirCode')),
      );

      final senderSpans = EmoteText.build(
        text: 'TheirCode',
        twitchPositions: null,
        channelEmotes: senderMap,
      );
      expect(senderSpans.any((s) => s is WidgetSpan), isTrue);
      final strangerSpans = EmoteText.build(
        text: 'TheirCode',
        twitchPositions: null,
        channelEmotes: manager.byCodeForSender('ch', 'sender-2'),
      );
      expect(strangerSpans.any((s) => s is WidgetSpan), isFalse);
    });

    test('senders without sets are cached negatively', () async {
      SharedPreferences.setMockInitialValues({});
      var listings = 0;
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        sevenTvOwnedSetIdsFetcher: (_) async {
          listings++;
          return [];
        },
        sevenTvEmoteSetFetcher: (_, _) async => [],
      );
      for (var i = 0; i < 2; i++) {
        await manager.ensureForeignPersonalSets(
          senderTwitchId: 'plain-user',
          channel: 'ch',
          text: 'hello world',
          positions: null,
        );
      }
      expect(listings, 1);
      expect(
        manager.byCodeForSender('ch', 'plain-user')?.byCode.keys ?? [],
        isNot(contains('hello')),
      );
    });

    test('stale entries refetch after TTL', () async {
      SharedPreferences.setMockInitialValues({});
      var clock = DateTime(2026, 1, 1, 12);
      var listings = 0;
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        now: () => clock,
        sevenTvOwnedSetIdsFetcher: (_) async {
          listings++;
          return ['set-1'];
        },
        sevenTvEmoteSetFetcher: (_, _) async => [personal('p1', 'TheirCode')],
      );
      await manager.ensureForeignPersonalSets(
        senderTwitchId: 'sender-1',
        channel: 'ch',
        text: 'TheirCode',
        positions: null,
      );
      await manager.ensureForeignPersonalSets(
        senderTwitchId: 'sender-1',
        channel: 'ch',
        text: 'TheirCode',
        positions: null,
      );
      expect(listings, 1);

      clock = clock.add(const Duration(hours: 25));
      await manager.ensureForeignPersonalSets(
        senderTwitchId: 'sender-1',
        channel: 'ch',
        text: 'TheirCode',
        positions: null,
      );
      expect(listings, 2);
    });

    test('messages without unknown words skip the fetch', () async {
      SharedPreferences.setMockInitialValues({});
      var listings = 0;
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        sevenTvOwnedSetIdsFetcher: (_) async {
          listings++;
          return [];
        },
        sevenTvEmoteSetFetcher: (_, _) async => [],
      );
      await manager.storeUserTwitchEmotes({
        'ch': [
          GenericEmote(
            id: 'tw-1',
            code: 'Known',
            type: EmoteType.twitch,
            url: 'https://example.com/tw-1.png',
            scope: EmoteScope.channel,
          ),
        ],
      });
      await manager.ensureForeignPersonalSets(
        senderTwitchId: 'sender-1',
        channel: 'ch',
        text: '   ',
        positions: null,
      );
      expect(listings, 0);
    });
  });
}
