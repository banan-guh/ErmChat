import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../../util/log.dart';
import '../../widgets/emote_image.dart';

typedef NativeDecodeWebp =
    Int32 Function(
      Pointer<Uint8> bytes,
      IntPtr len,
      Pointer<EmoteDecodedFrames> out,
    );
typedef DartDecodeWebp =
    int Function(
      Pointer<Uint8> bytes,
      int len,
      Pointer<EmoteDecodedFrames> out,
    );

typedef NativeFreeFrames = Void Function(Pointer<EmoteDecodedFrames> frames);
typedef DartFreeFrames = void Function(Pointer<EmoteDecodedFrames> frames);

final class EmoteDecodedFrames extends Struct {
  // Field names mirror the C struct in native/emote_codec.h (snake_case is
  // required for FFI layout clarity; ignore the style lint).
  // ignore_for_file: non_constant_identifier_names

  @Uint32()
  external int canvas_w;

  @Uint32()
  external int canvas_h;

  @Uint32()
  external int frame_count;

  @Uint32()
  external int loop_count;

  external Pointer<Int32> durations_ms;

  external Pointer<Uint8> rgba;
}

/// Raw frames returned by the decode isolate; sendable across isolates.
class _RawDecodeResult {
  const _RawDecodeResult({
    required this.canvasW,
    required this.canvasH,
    required this.frames,
    required this.durations,
  });

  final int canvasW;
  final int canvasH;
  final List<Uint8List> frames;
  final List<Duration> durations;
}

/// Native libwebp animated WebP decoder (see `native/emote_codec.c`).
///
/// Loads `libemote_codec.so` (Android, bundled by CMake) or the process
/// symbols (iOS, statically linked via the podspec). Falls back to the
/// pure-Dart decoder when the library is unavailable or a decode fails.
class NativeEmoteCodec {
  /// Test hook: absolute path to a host-built shim (e.g. the verification
  /// harness's `libemote_codec.so`). When set, the library is opened from
  /// that path instead of the platform default.
  @visibleForTesting
  static String? debugLibPath;

  /// Test hook: clears the cached library handle and availability probe, so
  /// tests can switch `debugLibPath` between runs.
  @visibleForTesting
  static void reset() {
    _lib = null;
    _available = null;
    debugDecodeWebpOverride = null;
  }

  /// Test hook: when set, [decodeWebp] returns the result of this function
  /// instead of invoking the native shim. Lets tests simulate a hanging or
  /// failing native decode (the iOS freeze) without spawning an isolate.
  @visibleForTesting
  static Future<EmoteFrameData?> Function(Uint8List bytes)?
  debugDecodeWebpOverride;

  static DynamicLibrary? _lib;
  static bool? _available;

  static DynamicLibrary get _library {
    if (_lib != null) return _lib!;
    final path = _libPath();
    final lib = path == null
        ? DynamicLibrary.process()
        : DynamicLibrary.open(path);
    _lib = lib;
    return lib;
  }

  /// True when the native library is present and usable.
  static bool get isAvailable {
    if (_available != null) return _available!;
    try {
      _library.lookupFunction<NativeDecodeWebp, DartDecodeWebp>(
        'emote_decode_webp',
      );
      _library.lookupFunction<NativeFreeFrames, DartFreeFrames>(
        'emote_free_frames',
      );
      _available = true;
      logDebug(
        '[NativeEmoteCodec] loaded (${_libPath() ?? 'process symbols'})',
      );
    } catch (e) {
      _available = false;
      logDebug('[NativeEmoteCodec] unavailable: $e');
    }
    return _available!;
  }

  /// Decodes an animated WebP, or null when the library is unavailable or the
  /// decode fails (callers fall back to the pure-Dart decoder).
  static Future<EmoteFrameData?> decodeWebp(Uint8List bytes) async {
    if (!isAvailable) return null;
    if (debugDecodeWebpOverride != null) {
      return debugDecodeWebpOverride!(bytes);
    }
    // Resolve the library path here and pass the string into the spawned
    // isolate (statics and DynamicLibrary handles don't transfer). The
    // isolate returns raw frames; ui.Image creation happens back on the main
    // isolate (ui.Image can't be created inside a spawned isolate's FFI
    // boundary reliably - same split as the pure-Dart decoder).
    final path = _libPath();
    final raw = await Isolate.run(() => _decodeRaw(bytes, path));
    if (raw == null) return null;
    return _toFrameData(raw);
  }

  /// Test hook: decode on the current isolate (no `Isolate.run`), so widget
  /// tests can exercise the native path without spawning an isolate.
  @visibleForTesting
  static Future<EmoteFrameData?> decodeWebpInline(Uint8List bytes) async {
    if (!isAvailable) return null;
    final raw = await _decodeRaw(bytes, _libPath());
    if (raw == null) return null;
    return _toFrameData(raw);
  }

  /// The path [DynamicLibrary.open] should use in this process. Null means
  /// the platform default (process symbols, Android lib name).
  static String? _libPath() {
    final override = debugLibPath;
    if (override != null) return override;
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'libemote_codec.so';
    }
    return null;
  }

  static Future<EmoteFrameData?> _toFrameData(_RawDecodeResult raw) async {
    final frames = <ui.Image>[];
    for (final rgba in raw.frames) {
      frames.add(await _imageFromRgba(rgba, raw.canvasW, raw.canvasH));
    }
    return EmoteFrameData(frames: frames, durations: raw.durations);
  }

  static Future<_RawDecodeResult?> _decodeRaw(
    Uint8List bytes,
    String? libPath,
  ) async {
    final lib = libPath == null
        ? DynamicLibrary.process()
        : DynamicLibrary.open(libPath);
    final decodeWebp = lib.lookupFunction<NativeDecodeWebp, DartDecodeWebp>(
      'emote_decode_webp',
    );
    final freeFrames = lib.lookupFunction<NativeFreeFrames, DartFreeFrames>(
      'emote_free_frames',
    );

    final bytesPtr = calloc<Uint8>(bytes.length);
    bytesPtr.asTypedList(bytes.length).setAll(0, bytes);
    final out = calloc<EmoteDecodedFrames>();
    try {
      if (decodeWebp(bytesPtr, bytes.length, out) != 1) return null;
      final w = out.ref.canvas_w;
      final h = out.ref.canvas_h;
      final count = out.ref.frame_count;
      if (w == 0 || h == 0 || count == 0) return null;

      final durationMs = out.ref.durations_ms.asTypedList(count);
      final durations = [
        for (var i = 0; i < count; i++) Duration(milliseconds: durationMs[i]),
      ];

      final canvasBytes = w * h * 4;
      final rgba = out.ref.rgba.asTypedList(canvasBytes * count);
      final frames = <Uint8List>[];
      for (var i = 0; i < count; i++) {
        frames.add(rgba.sublist(i * canvasBytes, (i + 1) * canvasBytes));
      }
      return _RawDecodeResult(
        canvasW: w,
        canvasH: h,
        frames: frames,
        durations: durations,
      );
    } finally {
      freeFrames(out);
      calloc.free(bytesPtr);
      calloc.free(out);
    }
  }

  static Future<ui.Image> _imageFromRgba(
    Uint8List rgba,
    int width,
    int height,
  ) async {
    // Straight alpha from libwebp -> premultiplied for the engine.
    final premultiplied = _premultiply(rgba);
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      premultiplied,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  static Uint8List _premultiply(Uint8List rgba) {
    final out = Uint8List(rgba.length);
    for (var i = 0; i < rgba.length; i += 4) {
      final a = rgba[i + 3];
      out[i] = (rgba[i] * a) ~/ 255;
      out[i + 1] = (rgba[i + 1] * a) ~/ 255;
      out[i + 2] = (rgba[i + 2] * a) ~/ 255;
      out[i + 3] = a;
    }
    return out;
  }
}
