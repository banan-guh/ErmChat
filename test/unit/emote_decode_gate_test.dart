import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ermchat/services/emote_codec/native_emote_codec.dart';
import 'package:ermchat/widgets/emote_image.dart';
import 'package:ermchat/widgets/emote_image_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    EmoteUrlProvider.debugFetchOverride = null;
    EmoteUrlProvider.debugDecodeOverride = null;
    NativeEmoteCodec.debugDecodeWebpOverride = null;
    nativeDecodeTimeout = const Duration(seconds: 8);
  });

  tearDown(() {
    EmoteUrlProvider.debugFetchOverride = null;
    EmoteUrlProvider.debugDecodeOverride = null;
    NativeEmoteCodec.debugDecodeWebpOverride = null;
    nativeDecodeTimeout = const Duration(seconds: 8);
  });

  // A native decode that never completes stands in for the iOS hang: threaded
  // libwebp inside a spawned Dart isolate deadlocks and never throws.
  Future<EmoteFrameData?> hang(Uint8List bytes) =>
      Completer<EmoteFrameData?>().future;

  test(
    'a hanging native decode falls back to pure-Dart instead of hanging',
    () async {
      NativeEmoteCodec.debugDecodeWebpOverride = hang;
      nativeDecodeTimeout = const Duration(milliseconds: 200);

      final bytes = File('test/fixtures/7tv_kiss_2x.webp').readAsBytesSync();
      // Without the defensive timeout this future would never complete and the
      // gate permit it holds would be lost forever.
      final result = await decodeEmoteBytes(
        bytes,
      ).timeout(const Duration(seconds: 5));
      expect(result.frames.length, greaterThan(1));
      for (final f in result.frames) {
        f.dispose();
      }
    },
  );

  test(
    'many concurrent hanging decodes do not permanently lock the gate',
    () async {
      NativeEmoteCodec.debugDecodeWebpOverride = hang;
      nativeDecodeTimeout = const Duration(milliseconds: 200);

      final bytes = File('test/fixtures/7tv_kiss_2x.webp').readAsBytesSync();
      final futures = [for (var i = 0; i < 30; i++) decodeEmoteBytes(bytes)];
      final results = await Future.wait(
        futures.map((f) => f.timeout(const Duration(seconds: 5))),
      );
      for (final r in results) {
        expect(r.frames.length, greaterThan(1));
        for (final f in r.frames) {
          f.dispose();
        }
      }
    },
  );
}
