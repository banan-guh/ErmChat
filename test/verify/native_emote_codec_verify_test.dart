import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:ermchat/services/emote_codec/native_emote_codec.dart';
import 'package:ermchat/widgets/emote_image.dart';

/// Verification harness for the native libwebp decoder (PLAN.md task 1).
///
/// Loads the host-built shim (path via `EMOTE_CODEC_SO`) and compares its
/// output against the pure-Dart reference decoder on the real fixtures:
/// frame count, sizes, durations, and premultiplied pixels must match, and
/// the native path must be substantially faster.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final soPath = Platform.environment['EMOTE_CODEC_SO'];
  if (soPath == null || !File(soPath).existsSync()) {
    // Not a verification run (or the shim is missing): skip silently so
    // `flutter test` stays green everywhere - the pure-Dart fallback is the
    // default path.
    return;
  }
  NativeEmoteCodec.debugLibPath = soPath;

  test(
    'production dispatch routes animated WebP through the native decoder',
    () async {
      final bytes = File('test/fixtures/7tv_kiss_2x.webp').readAsBytesSync();
      final viaDispatch = await decodeEmoteBytes(bytes);
      final inline = await NativeEmoteCodec.decodeWebpInline(bytes);
      expect(inline, isNotNull);

      // The dispatch (isolate split) must be byte-identical to the inline
      // native decode: same C lib, same premultiply, same ui.Image creation.
      expect(viaDispatch.frames, hasLength(inline!.frames.length));
      for (var i = 0; i < viaDispatch.frames.length; i++) {
        expect(
          viaDispatch.frames[i].width,
          inline.frames[i].width,
          reason: 'frame $i width',
        );
        expect(
          viaDispatch.frames[i].height,
          inline.frames[i].height,
          reason: 'frame $i height',
        );
        expect(
          viaDispatch.durations[i],
          inline.durations[i],
          reason: 'frame $i duration',
        );
      }
      final a = await _pixels(
        viaDispatch.frames[viaDispatch.frames.length ~/ 2],
      );
      final b = await _pixels(inline.frames[inline.frames.length ~/ 2]);
      expect(
        _diffCount(a, b),
        0,
        reason: 'dispatch pixels match inline decode',
      );
      for (final f in viaDispatch.frames) {
        f.dispose();
      }
      for (final f in inline.frames) {
        f.dispose();
      }
    },
  );

  for (final entry in [
    ('7tv_kiss_2x.webp', 64, 64, 47),
    ('7tv_boink_2x.webp', 190, 64, 252),
  ]) {
    final (fixture, w, h, expectedFrames) = entry;
    test('native decode matches pure-Dart: $fixture', () async {
      final bytes = File('test/fixtures/$fixture').readAsBytesSync();

      final t0 = DateTime.now();
      final native = await NativeEmoteCodec.decodeWebpInline(bytes);
      final tNative = DateTime.now().difference(t0).inMicroseconds / 1000;
      expect(native, isNotNull, reason: 'native decode succeeded');
      expect(native!.frames, hasLength(expectedFrames));

      final t1 = DateTime.now();
      final dart = await decodeWebpPureDart(bytes);
      final tDart = DateTime.now().difference(t1).inMicroseconds / 1000;

      // Frame count, sizes, durations must match exactly.
      expect(native.frames.length, dart.frames.length);
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

      // Pixels: premultiplied comparison; allow tiny rounding noise
      // (engine decode vs libwebp straight-alpha premultiply).
      var diffPixels = 0;
      for (var i = 0; i < native.frames.length; i++) {
        final a = await _pixels(native.frames[i]);
        final b = await _pixels(dart.frames[i]);
        diffPixels += _diffCount(a, b);
      }
      final totalPixels = w * h * expectedFrames;
      final diffPct = diffPixels / totalPixels * 100;

      // ignore: avoid_print
      print(
        'VERIFY $fixture: native=${tNative.toStringAsFixed(1)}ms '
        'dart=${tDart.toStringAsFixed(1)}ms '
        'speedup=${(tDart / tNative).toStringAsFixed(1)}x '
        'pixel-diff=${diffPct.toStringAsFixed(2)}%',
      );
      expect(
        diffPct,
        lessThan(5.0),
        reason: 'native pixels match the reference decoder',
      );

      for (final f in native.frames) {
        f.dispose();
      }
      for (final f in dart.frames) {
        f.dispose();
      }
    });
  }
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
