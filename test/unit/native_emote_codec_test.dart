import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:ermchat/services/emote_codec/native_emote_codec.dart';
import 'package:ermchat/widgets/emote_image.dart';

/// Gated unit tests for the native libwebp decoder.
///
/// Requires the host-built shim: run `tool/build_native_linux.sh`, then
/// `EMOTE_CODEC_SO=build/native/libemote_codec.so flutter test
/// test/unit/native_emote_codec_test.dart`. Without the env var the tests
/// skip silently (the pure-Dart fallback is the default everywhere else).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final soPath = Platform.environment['EMOTE_CODEC_SO'];
  if (soPath == null || !File(soPath).existsSync()) {
    return;
  }

  group('NativeEmoteCodec (gated)', () {
    setUp(() {
      NativeEmoteCodec.debugLibPath = soPath;
      NativeEmoteCodec.reset();
    });
    tearDown(NativeEmoteCodec.reset);

    test('isAvailable is true when the shim loads', () {
      expect(NativeEmoteCodec.isAvailable, isTrue);
    });

    test('isAvailable is false when the library is missing', () {
      NativeEmoteCodec.debugLibPath = '/nonexistent/libemote_codec.so';
      NativeEmoteCodec.reset();
      expect(NativeEmoteCodec.isAvailable, isFalse);
    });

    test(
      'decode matches the pure-Dart reference on the kiss fixture',
      () async {
        final bytes = File('test/fixtures/7tv_kiss_2x.webp').readAsBytesSync();
        final native = await NativeEmoteCodec.decodeWebpInline(bytes);
        expect(native, isNotNull);
        final dart = await decodeWebpPureDart(bytes);

        expect(native!.frames.length, dart.frames.length);
        expect(native.frames.length, 47);
        for (var i = 0; i < native.frames.length; i++) {
          expect(
            native.frames[i].width,
            dart.frames[i].width,
            reason: 'frame $i width',
          );
          expect(
            native.frames[i].height,
            dart.frames[i].height,
            reason: 'frame $i height',
          );
          expect(
            native.durations[i],
            dart.durations[i],
            reason: 'frame $i duration',
          );
        }

        // Spot-check the first frame's pixels.
        final a = await _pixels(native.frames[0]);
        final b = await _pixels(dart.frames[0]);
        expect(_diffCount(a, b), lessThan(100));

        for (final f in native.frames) {
          f.dispose();
        }
        for (final f in dart.frames) {
          f.dispose();
        }
      },
    );

    test('garbage input returns null, not an exception', () async {
      final garbage = Uint8List.fromList(List.generate(64, (i) => i * 7));
      final result = await NativeEmoteCodec.decodeWebpInline(garbage);
      expect(result, isNull);
    });

    test('repeated decodes do not corrupt state (free-path sanity)', () async {
      final bytes = File('test/fixtures/7tv_kiss_2x.webp').readAsBytesSync();
      for (var i = 0; i < 3; i++) {
        final native = await NativeEmoteCodec.decodeWebpInline(bytes);
        expect(native, isNotNull);
        expect(native!.frames.length, 47);
        for (final f in native.frames) {
          f.dispose();
        }
      }
    });
  });
}

Future<Uint8List> _pixels(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

int _diffCount(Uint8List a, Uint8List b) {
  var n = 0;
  final len = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < len; i += 4) {
    if (a[i] != b[i] ||
        a[i + 1] != b[i + 1] ||
        a[i + 2] != b[i + 2] ||
        a[i + 3] != b[i + 3]) {
      n++;
    }
  }
  return n;
}
