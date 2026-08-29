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
import 'package:ermchat/widgets/emote_text.dart';
import 'package:ermchat/models/twitch_command.dart';
import 'package:ermchat/services/suggestion.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ermchat/services/media_uploader.dart';

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

Future<File> _tempFile() async {
  final dir = await Directory.systemTemp.createTemp('ermchat_test');
  final file = File('${dir.path}/image.png');
  await file.writeAsBytes([0x89, 0x50, 0x4E, 0x47]);
  return file;
}

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

  test('evicts down to maxObjects by least-recently-touched', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([
      _obj('https://example.com/a.png', t, id: 1),
      _obj('https://example.com/b.png', t.add(const Duration(hours: 1)), id: 2),
      _obj('https://example.com/c.png', t.add(const Duration(hours: 2)), id: 3),
      _obj('https://example.com/d.png', t.add(const Duration(hours: 3)), id: 4),
      _obj('https://example.com/e.png', t.add(const Duration(hours: 4)), id: 5),
    ]);
    manager.maxObjects = 3;

    await manager.enforceNow();

    expect(repo.keys, [
      'https://example.com/c.png',
      'https://example.com/d.png',
      'https://example.com/e.png',
    ]);
  });

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

  test('a zero cap evicts everything', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([
      _obj('https://example.com/a.png', t, id: 1),
      _obj('https://example.com/b.png', t.add(const Duration(hours: 1)), id: 2),
    ]);
    manager.maxObjects = 0;

    await manager.enforceNow();

    expect(repo.keys, isEmpty);
  });

  test('evicts nothing when under maxObjects', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([
      _obj('https://example.com/a.png', t, id: 1),
      _obj('https://example.com/b.png', t.add(const Duration(hours: 1)), id: 2),
    ]);
    manager.maxObjects = 5;

    await manager.enforceNow();

    expect(repo.keys, [
      'https://example.com/a.png',
      'https://example.com/b.png',
    ]);
  });

  test('a full cache evicts the lowest-priority file to make room', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([
      _obj('https://example.com/a.png', t, id: 1),
      _obj('https://example.com/b.png', t.add(const Duration(hours: 1)), id: 2),
      _obj('https://example.com/c.png', t.add(const Duration(hours: 2)), id: 3),
    ]);
    manager.maxObjects = 3;

    expect(await manager.isFull(), isTrue);

    // The write evicts the lowest-priority file (a, oldest by far) before
    // attempting the download. The mocked 400 download then fails, so the
    // repo keeps the two higher-priority files and gains nothing.
    await expectLater(
      manager.getFileStream('https://example.com/new.png'),
      emitsError(anything),
    );

    expect(repo.keys, [
      'https://example.com/b.png',
      'https://example.com/c.png',
    ]);
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
      testWidgets(
        'renders a cached alternate under a faint loading band while the '
        'required URL is delayed, then swaps',
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
        },
      );

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

      testWidgets('falls back to a bare loading band when no alternate is '
          'cached', (tester) async {
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
        expect(find.byType(LoadingBand), findsOneWidget);

        gate.complete(animatedWebpBytes());
        await tester.pump();
        await tester.pump();
        expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
        expect(find.byType(LoadingBand), findsNothing);
      });
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

      testWidgets('a cap of zero pauses playback on the current frame', (
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
      });

      testWidgets('raising the cap from zero resumes playback live', (
        tester,
      ) async {
        EmoteUrlProvider.fpsCap = 0;
        await pumpCappedEmote(tester, uncapped: false);
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
      });

      testWidgets('an uncapped widget animates even at a cap of zero', (
        tester,
      ) async {
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

    test('handles all EmoteType values', () {
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
    });

    test('handles all EmoteScope values', () {
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

    test('incremental adds keep the suggestions code-sorted', () {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      manager.updateSevenTvEmotes(
        'ch',
        added: [sevenTv('a', 'Alpha'), sevenTv('c', 'Charlie')],
      );
      manager.updateSevenTvEmotes('ch', added: [sevenTv('b', 'Bravo')]);

      final codes = manager
          .byCode('ch')!
          .suggestions
          .map((e) => e.code)
          .toList();
      expect(codes, ['Alpha', 'Bravo', 'Charlie']);
    });

    test('incremental removes drop the entry and keep sorting', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        removeCachedFile: (url) async {},
      );
      manager.updateSevenTvEmotes(
        'ch',
        added: [
          sevenTv('a', 'Alpha'),
          sevenTv('b', 'Bravo'),
          sevenTv('c', 'Charlie'),
        ],
      );
      manager.updateSevenTvEmotes('ch', removedIds: ['b']);
      await pumpEventQueue();

      final emotes = manager.byCode('ch')!;
      expect(emotes.byCode.keys, ['Alpha', 'Charlie']);
      expect(emotes.suggestions.map((e) => e.code).toList(), [
        'Alpha',
        'Charlie',
      ]);
    });

    test('rename re-sorts the renamed emote into place', () {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      manager.updateSevenTvEmotes(
        'ch',
        added: [
          sevenTv('a', 'Alpha'),
          sevenTv('b', 'Bravo'),
          sevenTv('c', 'Charlie'),
        ],
      );
      manager.updateSevenTvEmotes(
        'ch',
        renamed: {'c': (newName: 'Aaron', oldName: 'Charlie')},
      );

      final codes = manager
          .byCode('ch')!
          .suggestions
          .map((e) => e.code)
          .toList();
      expect(codes, ['Aaron', 'Alpha', 'Bravo']);
    });

    test('consumeChangedCodes returns the touched codes per delta', () async {
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
    });

    test('consumeChangedCodes is null after a non-7TV notify', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(fetchStagger: Duration.zero);
      await manager.storeUserTwitchEmotes({
        'ch': [
          GenericEmote(
            id: 's1',
            code: 'SubEmote',
            type: EmoteType.twitch,
            url: 'https://example.com/s1.png',
            scope: EmoteScope.channel,
            tier: '3',
            emoteType: 'subscriptions',
          ),
        ],
      });

      expect(manager.consumeChangedCodes('ch'), isNull);
    });

    test('removed emote is evicted from disk when unused elsewhere', () async {
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
    });

    test(
      'removed emote stays on disk when another channel still uses it',
      () async {
        SharedPreferences.setMockInitialValues({});
        final removed = <String>[];
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          removeCachedFile: (url) async => removed.add(url),
        );
        manager.updateSevenTvEmotes('ch1', added: [sevenTv('a', 'Alpha')]);
        manager.updateSevenTvEmotes('ch2', added: [sevenTv('a', 'Alpha')]);

        manager.updateSevenTvEmotes('ch1', removedIds: ['a']);
        await pumpEventQueue();

        expect(removed, isEmpty);
      },
    );

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

    test('a no-op delta still counts as a delta, not a refetch', () {
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        removeCachedFile: (url) async {},
      );
      manager.updateSevenTvEmotes('ch', added: [sevenTv('a', 'Alpha')]);

      // Renaming an emote that isn't cached changes nothing, but the event
      // is still a live delta: callers must not treat it as a full refetch.
      manager.updateSevenTvEmotes(
        'ch',
        renamed: {'missing': (newName: 'X', oldName: 'Y')},
      );

      final codes = manager.consumeChangedCodes('ch');
      expect(codes, isNotNull);
      expect(codes, isEmpty);
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

    test('skips the reconcile in the low tier', () async {
      SharedPreferences.setMockInitialValues(cache([sevenTv('a', 'Alpha')]));
      var fetched = false;
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.low,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async {
          fetched = true;
          return SevenTvChannelResponse(emotes: [sevenTv('b', 'Bravo')]);
        },
      );

      await manager.resolveEmotes('ch', 'b1');
      await pumpEventQueue();

      expect(fetched, isFalse);
      expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Alpha']);
    });

    test('skips the reconcile without a broadcaster id', () async {
      SharedPreferences.setMockInitialValues(cache([sevenTv('a', 'Alpha')]));
      var fetched = false;
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async {
          fetched = true;
          return SevenTvChannelResponse(emotes: [sevenTv('b', 'Bravo')]);
        },
      );

      await manager.resolveEmotes('ch', null);
      await pumpEventQueue();

      expect(fetched, isFalse);
    });

    test('a failed reconcile leaves the cache untouched', () async {
      SharedPreferences.setMockInitialValues(cache([sevenTv('a', 'Alpha')]));
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async =>
            throw Exception('boom'),
      );

      await manager.resolveEmotes('ch', 'b1');
      await pumpEventQueue();

      expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Alpha']);
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

    test('force reload still fetches a frozen registry', () async {
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
      expect(fetches, 0);

      // Mirror the manual reload flow: evict, then force.
      manager.evictChannel('ch');
      await manager.resolveEmotes('ch', 'b1', force: true);
      await pumpEventQueue();
      expect(fetches, 1, reason: 'force is the manual escape hatch');
      expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Bravo']);
    });

    test('a persisted global registry freezes at low', () async {
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
      var fetches = 0;
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.low,
        removeCachedFile: (url) async {},
        sevenTvGlobalFetcher: (resolution) async {
          fetches++;
          return [];
        },
      );

      await manager.preloadGlobalEmotes();
      await pumpEventQueue();

      expect(fetches, 0);
      expect(manager.globalEmotesByProvider()['SevenTV']!.map((e) => e.code), [
        'OldGlobal',
      ]);
    });

    test('provider stash rebuild stays frozen at low', () async {
      SharedPreferences.setMockInitialValues({});
      var fetches = 0;
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.low,
        removeCachedFile: (url) async {},
        sevenTvGlobalFetcher: (resolution) async {
          fetches++;
          return [];
        },
      );

      await manager.ensureStashed({EmoteType.sevenTv});
      await pumpEventQueue();

      expect(fetches, 0);
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
        expect(
          manager.globalEmotesByProvider()['Twitch']!.map((e) => e.code),
          ['KeptTwitch'],
          reason: 'targeted refetch must not wipe other providers',
        );

        // A second pass no-ops: the stash now covers 7TV.
        await manager.ensureStashed({EmoteType.sevenTv});
        expect(fetches, 1);
      },
    );
  });

  group('EmoteManager refresh policy', () {
    test('probe failure falls back to the 12h wifi TTL', () async {
      final manager = EmoteManager(
        probe: () async => throw Exception('probe failed'),
      );
      expect(await manager.effectiveTtlForTesting(), const Duration(hours: 12));
    });

    test('no probe configured falls back to the 12h wifi TTL', () async {
      final manager = EmoteManager();
      expect(await manager.effectiveTtlForTesting(), const Duration(hours: 12));
    });

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

    test('nothing tier caches forever (infinite TTL)', () async {
      final manager = EmoteManager(
        tier: EmoteFetchTier.nothing,
        probe: () async => [ConnectivityResult.mobile],
      );
      expect(
        await manager.effectiveTtlForTesting(),
        const Duration(days: 365000),
      );
    });

    test(
      'medium tier uses a flat 24h TTL regardless of connectivity',
      () async {
        final mobile = EmoteManager(
          tier: EmoteFetchTier.medium,
          probe: () async => [ConnectivityResult.mobile],
        );
        final wifi = EmoteManager(
          tier: EmoteFetchTier.medium,
          probe: () async => [ConnectivityResult.wifi],
        );
        expect(
          await mobile.effectiveTtlForTesting(),
          const Duration(hours: 24),
        );
        expect(await wifi.effectiveTtlForTesting(), const Duration(hours: 24));
      },
    );

    test('high tier keeps the wifi/cellular TTL split', () async {
      final mobile = EmoteManager(
        tier: EmoteFetchTier.high,
        probe: () async => [ConnectivityResult.mobile],
      );
      final wifi = EmoteManager(
        tier: EmoteFetchTier.high,
        probe: () async => [ConnectivityResult.wifi],
      );
      expect(await mobile.effectiveTtlForTesting(), const Duration(hours: 24));
      expect(await wifi.effectiveTtlForTesting(), const Duration(hours: 12));
    });

    test('fetch queue serializes actions in order', () async {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      final order = <int>[];

      await Future.wait([
        manager.enqueueFetchForTesting(() async => order.add(1)),
        manager.enqueueFetchForTesting(() async => order.add(2)),
        manager.enqueueFetchForTesting(() async => order.add(3)),
      ]);

      expect(order, [1, 2, 3]);
    });

    test('fetch queue survives a failing action', () async {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      final order = <int>[];

      await expectLater(
        manager.enqueueFetchForTesting(() async => throw Exception('boom')),
        throwsException,
      );
      await manager.enqueueFetchForTesting(() async => order.add(1));

      expect(order, [1]);
    });

    test('allows up to two in-flight fetches to overlap', () async {
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

      await Future<void>.delayed(Duration.zero);

      expect(started, containsAll(['a', 'b']));

      gates[0].complete();
      gates[1].complete();
      await Future.wait([f1, f2]);
    });

    test('third fetch waits for a free slot before starting', () async {
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

    test('applying a fresh persisted cache keeps stored sub emotes', () async {
      SharedPreferences.setMockInitialValues(persistedCache(fresh: true));
      final manager = EmoteManager(fetchStagger: Duration.zero);
      await manager.storeUserTwitchEmotes({
        'ch': [subEmote()],
      });

      await manager.resolveEmotes('ch', 'b1');

      final codes = manager.byCode('ch')!.suggestions.map((e) => e.code);
      expect(codes, contains('SubEmote'));
      expect(codes, contains('NonTwitch'));
    });

    test('stale revalidate does not clobber stored sub emotes', () async {
      SharedPreferences.setMockInitialValues(persistedCache(fresh: false));
      final manager = EmoteManager(fetchStagger: Duration.zero);
      await manager.storeUserTwitchEmotes({
        'ch': [subEmote()],
      });

      await manager.resolveEmotes('ch', 'b1');

      final codes = manager.byCode('ch')!.suggestions.map((e) => e.code);
      expect(codes, contains('SubEmote'));
    });

    test('storing the same sub emotes twice does not duplicate them', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(fetchStagger: Duration.zero);
      final emote = subEmote();

      await manager.storeUserTwitchEmotes({
        'ch': [emote],
      });
      await manager.storeUserTwitchEmotes({
        'ch': [emote],
      });

      final subs = manager.subscriberEmotesByChannel()['ch']!;
      expect(subs.length, 1);
      expect(subs.single.code, 'SubEmote');
    });

    test('groups subs by ownerChannel instead of storage channel', () async {
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

      final byChannel = manager.subscriberEmotesByChannel();
      expect(byChannel.keys, ['alpha']);
      expect(byChannel['alpha']!.length, 1);
      expect(byChannel['alpha']!.single.code, 'SubEmote');
    });

    test(
      'falls back to the storage channel when the owner is unknown',
      () async {
        SharedPreferences.setMockInitialValues({});
        final manager = EmoteManager(fetchStagger: Duration.zero);
        await manager.storeUserTwitchEmotes({
          'ch': [subEmote()],
        });

        final byChannel = manager.subscriberEmotesByChannel();
        expect(byChannel.keys, ['ch']);
        expect(byChannel['ch']!.single.code, 'SubEmote');
      },
    );

    test('a fresh store replaces stale sub emotes for the channel', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(fetchStagger: Duration.zero);
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

      final subs = manager.subscriberEmotesByChannel()['ch']!;
      expect(subs.length, 1);
      expect(subs.single.code, 'FreshEmote');
    });

    test('groups subs alphabetically by owner channel', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(fetchStagger: Duration.zero);
      GenericEmote subOf(String id, String code, String owner) => GenericEmote(
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
      await manager.storeUserTwitchEmotes({
        'm': [
          subOf('z1', 'ZetaEmote', 'zeta'),
          subOf('a1', 'AlphaEmote', 'alpha'),
        ],
        'n': [
          subOf('a1', 'AlphaEmote', 'alpha'),
          subOf('z1', 'ZetaEmote', 'zeta'),
        ],
      });

      final byChannel = manager.subscriberEmotesByChannel();
      expect(byChannel.keys, ['alpha', 'zeta']);
    });

    test(
      'regression: distinct ownerId (unknown owner) keeps groups separate',
      () async {
        // The reported bug: when ownerChannel is unresolved, every sub emote
        // collapsed into the alphabetically-first storage channel. With ownerId
        // carried on the emote, each real owner must stay its own group.
        SharedPreferences.setMockInitialValues({});
        final manager = EmoteManager(fetchStagger: Duration.zero);
        GenericEmote sub(String id, String code, String ownerId) => GenericEmote(
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
        resolveOwnerLogins: (a, ids) async =>
            {for (final id in ids) id: 'login_$id'},
      );

      // ownerA is an open channel, so it's seeded without an API call.
      await manager.loadUserEmoteSets(['s1'], auth, {'chanA': 'ownerA'});
      final byChannel = manager.subscriberEmotesByChannel();
      expect(byChannel.keys, ['chanA']);
      expect(byChannel['chanA']!.single.code, 'X');
    });

    test('reconnect heals unresolved owner labels without re-fetching',
        () async {
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
      await manager.loadUserEmoteSets(
        [],
        auth,
        {'chanA': 'ownerA', 'chanB': 'ownerB'},
      );
      final byChannel = manager.subscriberEmotesByChannel();
      expect(byChannel.keys, unorderedEquals(['chanA', 'chanB']));
      expect(byChannel['chanA']!.single.code, 'X');
      expect(byChannel['chanB']!.single.code, 'Y');
    });
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

    test('cacheCap setter forwards the cap to the cache manager', () async {
      SharedPreferences.setMockInitialValues({});
      final cache = testCacheManager();
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        cacheManager: cache,
      );
      manager.cacheCap = 123;
      expect(manager.cacheCap, 123);
      expect(cache.maxObjects, 123);
    });

    test('cacheCap setter clamps to the allowed range', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        cacheManager: testCacheManager(),
      );
      manager.cacheCap = 999999;
      expect(manager.cacheCap, maxEmoteCacheMax);
      manager.cacheCap = -5;
      expect(manager.cacheCap, minEmoteCacheMax);
    });

    test('markEmoteViewed records usage in the registry', () async {
      SharedPreferences.setMockInitialValues({});
      final clock = DateTime(2026, 1, 1, 12);
      final manager = await makeManager(clock: () => clock);
      manager.markEmoteViewed(makeEmotes(1)[0]);
      await pumpEventQueue();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('emote_usage'),
        contains('https://example.com/e0.png'),
      );
    });

    test('usage registry persists across manager instances', () async {
      SharedPreferences.setMockInitialValues({});
      final clock = DateTime(2026, 1, 1, 12);
      final manager = await makeManager(clock: () => clock);
      manager.markEmoteViewed(makeEmotes(1)[0]);
      await pumpEventQueue();

      // A fresh instance loads the same registry and surfaces it through the
      // cache manager's priority source.
      final cache = testCacheManager();
      await makeManager(clock: () => clock, cache: cache);
      final lastUsed = cache.lastUsedAt!('https://example.com/e0.png');
      expect(lastUsed, clock);
    });

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
      'preloadGlobalEmotes loads the persisted cache without fetching',
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

        // Hoarded cache renders; nothing was fetched, so prefs are untouched.
        expect(manager.byCode('any')!.byCode, contains('GlobalE'));
        expect(
          manager.globalEmotesByProvider().values.expand((e) => e),
          contains(predicate((GenericEmote e) => e.code == 'GlobalE')),
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('emotes3_global'), persisted);
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

    test(
      'resolveEmotes loads the persisted channel cache without fetching',
      () async {
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
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          tier: EmoteFetchTier.nothing,
        );

        await manager.resolveEmotes('ch', 'b1');

        expect(manager.byCode('ch')!.byCode, contains('ChanE'));
      },
    );

    test('resolveEmotes with no persisted cache fetches nothing', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.nothing,
      );

      await manager.resolveEmotes('ch', 'b1');

      // No fetch, no cache, no throw.
      expect(manager.byCode('ch'), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('emotes3_ch'), isNull);
    });

    test('storeUserTwitchEmotes no-ops in the nothing tier', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.nothing,
      );

      await manager.storeUserTwitchEmotes({
        'ch': [subEmote()],
      });

      expect(manager.subscriberEmotesByChannel(), isEmpty);
    });

    test('updateSevenTvEmotes no-ops in the nothing tier', () {
      final manager = EmoteManager(tier: EmoteFetchTier.nothing);

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

    test('mismatched tier tag forces a refetch (1x -> 2x overwrite)', () async {
      SharedPreferences.setMockInitialValues(
        channelCache(tier: EmoteFetchTier.low.index),
      );
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
      );

      await manager.resolveEmotes('ch', 'b1');

      // The stale 1x cache still renders while revalidating...
      expect(manager.byCode('ch')!.byCode, contains('ChanE'));
      // ...and the refetch rewrote the persisted cache with the new tier tag.
      final data =
          jsonDecode((await EmoteMetaStore.I.read('emotes3_ch'))!)
              as Map<String, dynamic>;
      expect(data['tier'], EmoteFetchTier.medium.index);
    });

    test('matching tier tag stays fresh without rewriting', () async {
      SharedPreferences.setMockInitialValues(
        channelCache(tier: EmoteFetchTier.medium.index),
      );
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
      );

      await manager.resolveEmotes('ch', 'b1');

      expect(manager.byCode('ch')!.byCode, contains('ChanE'));
      final data =
          jsonDecode((await EmoteMetaStore.I.read('emotes3_ch'))!)
              as Map<String, dynamic>;
      // No refetch happened: the persisted tier tag is untouched.
      expect(data['tier'], EmoteFetchTier.medium.index);
    });

    test(
      'nothing tier loads a stale (mismatched-tier) cache without fetching',
      () async {
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
      },
    );

    test(
      'missing tier tag (pre-feature cache) is treated as matching',
      () async {
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
        final manager = EmoteManager(fetchStagger: Duration.zero);

        await manager.resolveEmotes('ch', 'b1');

        expect(manager.byCode('ch')!.byCode, contains('ChanE'));
        final data =
            jsonDecode((await EmoteMetaStore.I.read('emotes3_ch'))!)
                as Map<String, dynamic>;
        expect(data.containsKey('tier'), isFalse);
      },
    );
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

    test('a just-used emote scores high even with a single view', () {
      final r = EmoteUsageRecord.bumped(
        record(lastUsedAt: now),
        hour,
        now: now,
      );
      expect(r.score(now), greaterThan(0.9));
    });

    test('steady daily use outranks a one-hour spam burst', () {
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
    });

    test('an emote idle well past the window scores near zero', () {
      // Views happened 10 days ago; the lax 3-day recency window has fully
      // elapsed, so the recency term has decayed to near nothing (and the
      // 24h bucket window has rolled past every recorded view).
      final r = EmoteUsageRecord.rolledForward(
        EmoteUsageRecord(
          lastUsedAt: now.subtract(const Duration(hours: 10 * 24)),
          bucketBase: hour - 10 * 24,
          buckets: List.filled(24, 1),
        ),
        hour,
      );
      expect(r.score(now), lessThan(0.05));
      // A freshly-idle (1 day) emote still scores well above it.
      final fresh = EmoteUsageRecord.rolledForward(
        EmoteUsageRecord(
          lastUsedAt: now.subtract(const Duration(hours: 24)),
          bucketBase: hour - 24,
          buckets: List.filled(24, 1),
        ),
        hour,
      );
      expect(fresh.score(now), greaterThan(r.score(now)));
    });

    test('uniform distribution scores higher than a clustered one', () {
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
            isMetered: false,
          ),
          tier,
        );
        expect(
          effectiveEmoteFetchTier(
            manual: tier,
            auto: EmoteFetchAutoMode.off,
            isMetered: true,
          ),
          tier,
        );
      }
    });

    test('balanced picks high on wifi, low on cellular', () {
      bool isMetered = false;
      expect(
        effectiveEmoteFetchTier(
          manual: EmoteFetchTier.medium,
          auto: EmoteFetchAutoMode.balanced,
          isMetered: isMetered,
        ),
        EmoteFetchTier.high,
      );
      isMetered = true;
      expect(
        effectiveEmoteFetchTier(
          manual: EmoteFetchTier.medium,
          auto: EmoteFetchAutoMode.balanced,
          isMetered: isMetered,
        ),
        EmoteFetchTier.low,
      );
    });

    test('aggressive picks medium on wifi, nothing on cellular', () {
      bool isMetered = false;
      expect(
        effectiveEmoteFetchTier(
          manual: EmoteFetchTier.high,
          auto: EmoteFetchAutoMode.aggressive,
          isMetered: isMetered,
        ),
        EmoteFetchTier.medium,
      );
      isMetered = true;
      expect(
        effectiveEmoteFetchTier(
          manual: EmoteFetchTier.high,
          auto: EmoteFetchAutoMode.aggressive,
          isMetered: isMetered,
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
    test('plain text with no emotes returns URL-parsed spans', () {
      final spans = EmoteText.build(
        text: 'hello world',
        twitchPositions: null,
        channelEmotes: null,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<TextSpan>());
      expect((spans[0] as TextSpan).text, 'hello world');
    });

    test('plain text with no emote matches returns URL-parsed spans', () {
      final emotes = _makeEmotes(<String, GenericEmote>{});
      final spans = EmoteText.build(
        text: 'hello world',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      // Text runs are linkified as one unit (a fractured link can span the
      // whitespace), so the whole message is a single TextSpan here.
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
      expect(urlSpan.text, 'https://example.com');
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

    test('base emote followed by zero-width overlay stacks', () {
      final emotes = _makeEmotes({
        'Kappa': makeTestEmote(id: '1', code: 'Kappa'),
        'EZ': makeTestEmote(id: '2', code: 'EZ', isZeroWidth: true),
      });
      final spans = EmoteText.build(
        text: 'Kappa EZ',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      // Kappa + EZ overlay → single WidgetSpan
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
    });

    test('base emote followed by two zero-width overlays', () {
      final emotes = _makeEmotes({
        'Kappa': makeTestEmote(id: '1', code: 'Kappa'),
        'EZ': makeTestEmote(id: '2', code: 'EZ', isZeroWidth: true),
        'HYPERS': makeTestEmote(id: '3', code: 'HYPERS', isZeroWidth: true),
      });
      final spans = EmoteText.build(
        text: 'Kappa EZ HYPERS',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      // Kappa + EZ + HYPERS → single WidgetSpan with 2 overlays
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
    });

    test('zero-width between two base emotes attaches to first', () {
      final emotes = _makeEmotes({
        'Kappa': makeTestEmote(id: '1', code: 'Kappa'),
        'EZ': makeTestEmote(id: '2', code: 'EZ', isZeroWidth: true),
        'PogChamp': makeTestEmote(id: '3', code: 'PogChamp'),
      });
      final spans = EmoteText.build(
        text: 'Kappa EZ PogChamp',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      // Kappa + EZ (overlay) = WidgetSpan, ' ', PogChamp = WidgetSpan
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

    test('small-scale emote renders at scaled size', () {
      final emotes = _makeEmotes({
        'SmallEmote': makeTestEmote(
          id: '1',
          code: 'SmallEmote',
          relativeScale: 0.625,
        ),
      });
      final spans = EmoteText.build(
        text: 'SmallEmote',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
      final box = (spans[0] as WidgetSpan).child as SizedBox;
      expect(box.width, 28.0 * 0.625);
      expect(box.height, 28.0 * 0.625);
    });

    test('zero-width overlay expands box to fit largest element', () {
      final emotes = _makeEmotes({
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
      final spans = EmoteText.build(
        text: 'SmallBase LargeOverlay',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
      final box = (spans[0] as WidgetSpan).child as SizedBox;
      expect(box.width, 28.0);
      expect(box.height, 28.0);
    });
  });

  group('SevenTvEmoteProvider', () {
    test('parses a plain emote without baseName', () {
      final emote = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-1',
        'name': 'PogChamp',
        'data': {'name': 'PogChamp', 'host': _host('1x.webp')},
      });
      expect(emote, isNotNull);
      expect(emote!.id, 'emote-1');
      expect(emote.code, 'PogChamp');
      expect(emote.baseName, isNull);
      expect(emote.type, EmoteType.sevenTv);
    });

    test('records baseName for alias emotes (name != data.name)', () {
      final emote = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-2',
        'name': 'ALIAS',
        'data': {'name': 'BaseEmote', 'host': _host('1x.webp')},
      });
      expect(emote, isNotNull);
      expect(emote!.code, 'ALIAS');
      expect(emote.baseName, 'BaseEmote');
    });

    test('parses owner display_name into ownerChannel', () {
      final emote = SevenTvEmoteProvider.parseSingleEmote({
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
    });

    test('marks channel emotes with channel scope', () {
      final emote = SevenTvEmoteProvider.parseSingleEmote({
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

      test('low picks the smallest file and drops url1x/url3x', () {
        final e = SevenTvEmoteProvider.parseSingleEmote(
          emote(['1x.webp', '2x.webp', '3x.webp', '4x.webp']),
          resolution: EmoteResolution.low,
        );
        expect(e, isNotNull);
        expect(e!.url, '$base/1x.webp');
        expect(e.url1x, isNull);
        expect(e.url3x, isNull);
      });

      test('medium picks the 2x file with 1x alternate and drops url3x', () {
        final e = SevenTvEmoteProvider.parseSingleEmote(
          emote(['1x.webp', '2x.webp', '3x.webp', '4x.webp']),
          resolution: EmoteResolution.medium,
        );
        expect(e, isNotNull);
        expect(e!.url, '$base/2x.webp');
        expect(e.url1x, '$base/1x.webp');
        expect(e.url3x, isNull);
      });

      test(
        'high picks 2x, 1x alternate and url3x even when a 4x file exists',
        () {
          final e = SevenTvEmoteProvider.parseSingleEmote(
            emote(['1x.webp', '2x.webp', '3x.webp', '4x.webp']),
          );
          expect(e, isNotNull);
          expect(e!.url, '$base/2x.webp');
          expect(e.url1x, '$base/1x.webp');
          expect(e.url3x, '$base/3x.webp');
          expect(e.url3x, isNot(contains('4x')));
          expect(e.url3x, isNot(contains('4x.webp')));
        },
      );

      test('high falls back to the 2x file when no 3x tier exists', () {
        final e = SevenTvEmoteProvider.parseSingleEmote(
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

    test('known overlay codes are zero-width', () {
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
    });

    test('regular emotes stay non-overlay', () {
      final emotes = BttvEmoteProvider.parseEmotes([
        item('Kappa'),
        item('gachiBASS'),
      ]);
      expect(emotes, hasLength(2));
      expect(emotes.every((e) => !e.isZeroWidth), isTrue);
    });

    test('an explicit API zeroWidth field still wins when false', () {
      // Field is currently never sent by BTTV, but if it appears it must
      // compose with the hardcoded list.
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

    test('modifier entries are zero-width', () {
      final emote = FfzEmoteProvider.parseEmote(
        ffzItem(modifier: true),
        EmoteResolution.high,
      );
      expect(emote, isNotNull);
      expect(emote!.isZeroWidth, isTrue);
    });

    test('regular entries are not zero-width', () {
      final emote = FfzEmoteProvider.parseEmote(
        ffzItem(),
        EmoteResolution.high,
      );
      expect(emote, isNotNull);
      expect(emote!.isZeroWidth, isFalse);
    });
  });

  group('filterSuggestions', () {
    test('returns empty when no emote or user matches', () {
      final result = filterSuggestions(
        word: 'xyz',
        emotes: [_e('1', 'Kappa'), _e('2', 'PogChamp')],
        users: {'user1', 'user2'},
      );
      expect(result, isEmpty);
    });

    test('returns empty for empty word', () {
      final result = filterSuggestions(
        word: '',
        emotes: [_e('1', 'Kappa')],
        users: {'user1'},
      );
      expect(result, isEmpty);
    });

    group('emote scoring', () {
      test('shorter matches rank before longer ones', () {
        final result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'PogChamp'), _e('2', 'PogU'), _e('3', 'Pog')],
          users: {},
        );
        expect(_codes(result), ['Pog', 'PogU', 'PogChamp']);
      });

      test('exact case beats case mismatch at the same length', () {
        final result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'POGX'), _e('2', 'PogX')],
          users: {},
        );
        // PogX: 1 case diff + 1*100 = 101, POGX: 2 case diffs + 1*100 = 102.
        expect(_codes(result), ['PogX', 'POGX']);
      });

      test('shorter match beats case-mismatched longer match', () {
        final result = filterSuggestions(
          word: 'wi',
          emotes: [_e('1', 'wikked'), _e('2', 'Wink')],
          users: {},
        );
        // Wink: 1 case diff + 2*100 = 201, wikked: -10 + 4*100 = 390.
        expect(_codes(result), ['Wink', 'wikked']);
      });

      test('recently used emote gets a boost', () {
        final result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'PogChamp'), _e('2', 'PogU')],
          users: {},
          recentEmoteIds: {'1'},
        );
        // PogChamp: -10 + 5*100 - 50 = 440, PogU: -10 + 1*100 = 90.
        expect(_codes(result), ['PogU', 'PogChamp']);
      });

      test('non-matching emotes are excluded', () {
        final result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'Kappa'), _e('2', 'PogChamp'), _e('3', 'LUL')],
          users: {},
        );
        expect(_codes(result), ['PogChamp']);
      });

      test('matches mid-code case-insensitively', () {
        final result = filterSuggestions(
          word: 'pog',
          emotes: [_e('1', 'PogChamp')],
          users: {},
        );
        expect(_codes(result), ['PogChamp']);
      });

      test('deduplicates by emote id', () {
        final result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'PogChamp'), _e('1', 'PogChamp')],
          users: {},
        );
        expect(result.length, 1);
      });
    });

    group('users', () {
      test('users carry a penalty so emotes win near-ties', () {
        final result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'PogU')],
          users: {'Pog'},
        );
        // Emote PogU: -10 + 100 = 90. User Pog: -10 + 25 = 15.
        expect(_codes(result), ['Pog', 'PogU']);
      });

      test('users match anywhere (contains) and sort by score', () {
        final result = filterSuggestions(
          word: 'xq',
          emotes: [],
          users: {'xqcL', 'xqc'},
        );
        // xqc: -10 + 100 + 25 = 115, xqcL: -10 + 200 + 25 = 215.
        expect(_codes(result), ['xqc', 'xqcL']);
      });

      test('preferEmotesFirst keeps the type split: all emotes first', () {
        final defaultResult = filterSuggestions(
          word: 'test',
          emotes: [_e('1', 'testEmote')],
          users: {'testUser'},
        );
        // testUser: -10 + 400 + 25 = 415, testEmote: -10 + 500 = 490.
        expect(defaultResult[0], isA<UserSuggestion>());

        final flipped = filterSuggestions(
          word: 'test',
          emotes: [_e('1', 'testEmote')],
          users: {'testUser'},
          preferEmotesFirst: true,
        );
        expect(flipped[0], isA<EmoteSuggestion>());
        expect(flipped[1], isA<UserSuggestion>());
      });

      test('numeric queries surface the short exact emote first', () {
        final result = filterSuggestions(
          word: '7',
          emotes: [_e('1', 'pog7'), _e('2', '777'), _e('3', '17tv')],
          users: {'7up'},
        );
        // 777: -10 + 200 = 190, 7up: -10 + 200 + 25 = 215,
        // 17tv/pog7: -10 + 300 = 290 (alphabetical tie-break).
        expect(_codes(result), ['777', '7up', '17tv', 'pog7']);
      });

      test('non-matching users are excluded', () {
        final result = filterSuggestions(
          word: 'alice',
          emotes: [],
          users: {'bob', 'carol'},
        );
        expect(result, isEmpty);
      });
    });

    group('commands', () {
      test('bare slash returns every available command', () {
        final result = filterSuggestions(
          word: '/',
          emotes: [],
          users: {},
          commands: _commands,
        );
        expect(_codes(result), ['/me', '/color', '/ban']);
      });

      test('slash word matches command prefixes', () {
        final result = filterSuggestions(
          word: '/b',
          emotes: [],
          users: {},
          commands: _commands,
        );
        expect(result.length, 1);
        expect(result[0], isA<CommandSuggestion>());
        expect(result[0].displayText, '/ban');
      });

      test('slash word matches case-insensitive', () {
        final result = filterSuggestions(
          word: '/ME',
          emotes: [],
          users: {},
          commands: _commands,
        );
        expect(result.length, 1);
        expect(result[0].displayText, '/me');
      });

      test('slash word never matches users or emotes', () {
        final result = filterSuggestions(
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

  group('UploaderConfig', () {
    test('parses semicolon-separated headers', () {
      const config = UploaderConfig(
        uploadUrl: 'https://example.com/upload',
        formField: 'file',
        headers: 'X-A: 1; X-B:two; garbage; X-C: three ',
      );
      expect(config.parsedHeaders, [
        (name: 'X-A', value: '1'),
        (name: 'X-B', value: 'two'),
        (name: 'X-C', value: 'three'),
      ]);
    });

    test('round-trips through json', () {
      const config = UploaderConfig(
        uploadUrl: 'https://example.com/upload',
        formField: 'file',
        headers: 'X-A: 1',
        imageLinkPattern: '{link}',
        deletionLinkPattern: '{delete}',
      );
      expect(
        UploaderConfig.fromJson(config.toJson()).uploadUrl,
        config.uploadUrl,
      );
      expect(
        UploaderConfig.fromJson(config.toJson()).deletionLinkPattern,
        '{delete}',
      );
    });

    test('missing fields fall back to defaults', () {
      final config = UploaderConfig.fromJson(const {});
      expect(config.uploadUrl, UploaderConfig.defaultConfig.uploadUrl);
      expect(config.formField, UploaderConfig.defaultConfig.formField);
    });
  });

  group('MediaUploader.uploadMedia', () {
    test('parses {link} pattern from kappa.lol response', () async {
      final uploader = MediaUploader(
        client: MockClient((request) async {
          expect(request.url.toString(), 'https://kappa.lol/api/upload');
          expect(request.headers['User-Agent'], 'ermchat');
          return http.Response(
            '{"id":"abc","link":"https://kappa.lol/abc","delete":"https://kappa.lol/delete?key"}',
            200,
          );
        }),
      );
      final file = await _tempFile();

      final result = await uploader.uploadMedia(file);

      expect(result.imageLink, 'https://kappa.lol/abc');
      expect(result.deleteLink, 'https://kappa.lol/delete?key');
    });

    test('substitutes nested pattern tokens', () async {
      final uploader = MediaUploader(
        client: MockClient(
          (_) async => http.Response('{"id":"abc","ext":".png"}', 200),
        ),
      );
      await uploader.saveConfig(
        const UploaderConfig(
          uploadUrl: 'https://example.com/upload',
          formField: 'file',
          imageLinkPattern: 'https://example.com/{id}{ext}',
          deletionLinkPattern: '{delete}',
        ),
      );
      final file = await _tempFile();

      final result = await uploader.uploadMedia(file);

      expect(result.imageLink, 'https://example.com/abc.png');
      expect(result.deleteLink, isNull);
    });

    test('uses raw body when no image link pattern is set', () async {
      final uploader = MediaUploader(
        client: MockClient(
          (_) async => http.Response('https://kappa.lol/raw', 200),
        ),
      );
      await uploader.saveConfig(
        const UploaderConfig(
          uploadUrl: 'https://example.com/upload',
          formField: 'file',
          imageLinkPattern: null,
        ),
      );
      final file = await _tempFile();

      final result = await uploader.uploadMedia(file);

      expect(result.imageLink, 'https://kappa.lol/raw');
      expect(result.deleteLink, isNull);
    });

    test('throws on non-2xx responses', () async {
      final uploader = MediaUploader(
        client: MockClient((_) async => http.Response('oops', 500)),
      );
      final file = await _tempFile();

      expect(uploader.uploadMedia(file), throwsA(isA<HttpException>()));
    });
  });

  group('MediaUploader config persistence', () {
    test('loads default config when nothing is stored', () async {
      final uploader = MediaUploader(
        client: MockClient((_) async => http.Response('', 200)),
      );
      final config = await uploader.loadConfig();
      expect(config.uploadUrl, 'https://kappa.lol/api/upload');
    });

    test('save then load round-trips', () async {
      final uploader = MediaUploader(
        client: MockClient((_) async => http.Response('', 200)),
      );
      const config = UploaderConfig(
        uploadUrl: 'https://example.com/upload',
        formField: 'file',
        headers: 'X-A: 1',
        imageLinkPattern: '{link}',
        deletionLinkPattern: '{delete}',
      );
      await uploader.saveConfig(config);

      final loaded = await uploader.loadConfig();
      expect(loaded.uploadUrl, 'https://example.com/upload');
      expect(loaded.headers, 'X-A: 1');
    });

    test('reset restores kappa.lol defaults', () async {
      final uploader = MediaUploader(
        client: MockClient((_) async => http.Response('', 200)),
      );
      await uploader.saveConfig(
        const UploaderConfig(uploadUrl: 'https://example.com', formField: 'x'),
      );
      await uploader.resetConfig();

      final loaded = await uploader.loadConfig();
      expect(loaded.uploadUrl, 'https://kappa.lol/api/upload');
      expect(loaded.formField, 'file');
    });
  });

  group('MediaUploader recent uploads', () {
    test('addRecent inserts at the front and caps the list', () async {
      final uploader = MediaUploader(
        client: MockClient((_) async => http.Response('', 200)),
      );
      for (var i = 0; i < 60; i++) {
        await uploader.addRecent(
          UploadResult(imageLink: 'https://kappa.lol/$i', deleteLink: null),
        );
      }

      final uploads = await uploader.recentUploads();
      expect(uploads.length, 50);
      expect(uploads.first.imageLink, 'https://kappa.lol/59');
      expect(uploads.last.imageLink, 'https://kappa.lol/10');
    });

    test('removeRecent deletes the entry at the index', () async {
      final uploader = MediaUploader(
        client: MockClient((_) async => http.Response('', 200)),
      );
      await uploader.addRecent(const UploadResult(imageLink: 'a'));
      await uploader.addRecent(const UploadResult(imageLink: 'b'));

      await uploader.removeRecent(0);

      final uploads = await uploader.recentUploads();
      expect(uploads.length, 1);
      expect(uploads.first.imageLink, 'a');
    });

    test('clearRecents empties the list', () async {
      final uploader = MediaUploader(
        client: MockClient((_) async => http.Response('', 200)),
      );
      await uploader.addRecent(const UploadResult(imageLink: 'a'));

      await uploader.clearRecents();

      expect(await uploader.recentUploads(), isEmpty);
    });
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

    test('disabling a provider drops it from the merged caches', () async {
      final manager = await seededManager();
      expect(manager.byCode('ch')!.byCode.keys, containsAll(['BttvE', 'FfzE']));
      expect(manager.isProviderEnabled(EmoteType.bttv), isTrue);

      await manager.setProviderEnabled(EmoteType.bttv, false);

      expect(manager.isProviderEnabled(EmoteType.bttv), isFalse);
      expect(manager.byCode('ch')!.byCode, isNot(contains('BttvE')));
      expect(manager.byCode('ch')!.byCode, contains('FfzE'));
      expect(
        manager.globalEmotesByProvider().keys,
        isNot(contains('BetterTTV')),
      );
    });

    test('re-enabling restores the provider from the retained stash', () async {
      final manager = await seededManager();
      await manager.setProviderEnabled(EmoteType.bttv, false);
      expect(manager.byCode('ch')!.byCode, isNot(contains('BttvE')));

      await manager.setProviderEnabled(EmoteType.bttv, true);

      // No network in the nothing tier: restoration proves the stash path.
      expect(manager.byCode('ch')!.byCode, contains('BttvE'));
    });

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

    test('unlisted 7TV emotes stay hidden until allowed', () async {
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
    });

    test(
      'the allow-unlisted setting persists across manager instances',
      () async {
        SharedPreferences.setMockInitialValues({
          'emote_7tv_allow_unlisted': true,
        });
        final manager = EmoteManager(fetchStagger: Duration.zero);
        await manager.enabledProviders();
        manager.updateSevenTvEmotes(
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

        expect(manager.byCode('ch')!.byCode.keys, ['Secret']);
      },
    );
  });

  group('resolveRecentsForChannel', () {
    GenericEmote emote(String id, String code) => GenericEmote(
      id: id,
      code: code,
      type: EmoteType.sevenTv,
      url: 'https://example.com/$id.png',
    );

    test('shared id picks up the current channel alias', () {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      final recents = [emote('x', 'Emote')];
      final channelB = [emote('x', 'ThisEmote')];

      final resolved = manager.resolveRecentsForChannel(recents, channelB);

      expect(resolved.single.code, 'ThisEmote');
    });

    test('recents absent from the channel are dropped', () {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      final recents = [emote('a', 'A'), emote('gone', 'Gone')];
      final channel = [emote('a', 'A2')];

      final resolved = manager.resolveRecentsForChannel(recents, channel);

      expect(resolved.map((e) => e.code), ['A2']);
    });

    test('duplicate ids in suggestions keep the first occurrence', () {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      final recents = [emote('x', 'whatever')];
      final channel = [emote('x', 'Alpha'), emote('x', 'Beta')];

      final resolved = manager.resolveRecentsForChannel(recents, channel);

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
}
