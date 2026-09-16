import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../util/webp_anim.dart';

/// Decoded emote frames with per-frame durations. Owned by the shared completer; renderers must not dispose.
class EmoteFrameData {
  EmoteFrameData({required this.frames, required this.durations});

  final List<ui.Image> frames;
  final List<Duration> durations;

  bool get isAnimated => frames.length > 1;

  Duration get totalDuration {
    var total = Duration.zero;
    for (final d in durations) {
      total += d;
    }
    return total;
  }
}

enum EmoteFormat { gif, webp, other }

/// Sniffs image format from magic bytes. Exposed for tests.
EmoteFormat sniffEmoteFormat(Uint8List bytes) {
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 && // G
      bytes[1] == 0x49 && // I
      bytes[2] == 0x46 && // F
      bytes[3] == 0x38) {
    return EmoteFormat.gif;
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 && // R
      bytes[1] == 0x49 && // I
      bytes[2] == 0x46 && // F
      bytes[3] == 0x46 && // F
      bytes[8] == 0x57 && // W
      bytes[9] == 0x45 && // E
      bytes[10] == 0x42 && // B
      bytes[11] == 0x50) {
    // 'RIFF'....'WEBP'
    return EmoteFormat.webp;
  }
  return EmoteFormat.other;
}

Future<EmoteFrameData> _decodeBytes(Uint8List bytes) {
  switch (sniffEmoteFormat(bytes)) {
    case EmoteFormat.gif:
      // GIFs: engine codec handles them correctly. Route native to avoid isolate cost.
      return _decodeWithEngineCodec(bytes);
    case EmoteFormat.webp:
      // Engine-first: fast path for most; fallback to reinforced decoder on transparent-frame throws.
      if (webpIsAnimated(bytes)) {
        return _decodeAnimatedWebpEngineFirst(bytes);
      }
      return _decodeStatic(bytes);
    case EmoteFormat.other:
      return _decodeStatic(bytes);
  }
}

/// True when a WebP has an ANMF chunk (animated). Exposed for tests.
bool webpIsAnimated(Uint8List bytes) {
  // RIFF 'WEBP' header (12 bytes) followed by chunks.
  if (bytes.length < 12 ||
      bytes[0] != 0x52 ||
      bytes[1] != 0x49 ||
      bytes[2] != 0x46 ||
      bytes[3] != 0x46 ||
      bytes[8] != 0x57 ||
      bytes[9] != 0x45 ||
      bytes[10] != 0x42 ||
      bytes[11] != 0x50) {
    return false;
  }
  int pos = 12;
  while (pos + 8 <= bytes.length) {
    final fourcc = String.fromCharCodes(bytes.sublist(pos, pos + 4));
    final chunkSize =
        bytes[pos + 4] |
        (bytes[pos + 5] << 8) |
        (bytes[pos + 6] << 16) |
        (bytes[pos + 7] << 24);
    if (fourcc == 'ANMF') return true;
    if (chunkSize >= bytes.length) return false;
    pos += 8 + chunkSize + (chunkSize & 1);
  }
  return false;
}

/// Production decode pipeline: sniff, decode, premultiply, emit ui.Image.
Future<EmoteFrameData> decodeEmoteBytes(Uint8List bytes) => _decodeBytes(bytes);

/// Engine-first: tries fast decode, falls back to per-frame on transparent-frame throws.
Future<EmoteFrameData> _decodeAnimatedWebpEngineFirst(Uint8List bytes) async {
  try {
    return await _decodeWithEngineCodecSafe(bytes);
  } catch (_) {
    return _decodeAnimatedWebpPerFrame(bytes);
  }
}

/// Eager engine decode with loud-failure detection. Throws on transparent frames; caller falls back.
Future<EmoteFrameData> _decodeWithEngineCodecSafe(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frames = <ui.Image>[];
  final durations = <Duration>[];
  try {
    for (var i = 0; i < codec.frameCount; i++) {
      final frame = await codec.getNextFrame().timeout(
        const Duration(seconds: 3),
      );
      frames.add(frame.image);
      durations.add(frame.duration);
    }
  } on TimeoutException {
    for (final f in frames) {
      f.dispose();
    }
    codec.dispose();
    throw StateError('engine stalled on a frame');
  } catch (e) {
    for (final f in frames) {
      f.dispose();
    }
    codec.dispose();
    rethrow;
  }
  codec.dispose();
  return EmoteFrameData(frames: frames, durations: durations);
}

/// Per-frame decode + spec compositing. Slower but correct; safety net for the engine's animated compositor.
Future<EmoteFrameData> _decodeAnimatedWebpPerFrame(Uint8List bytes) async {
  final meta = parseWebpAnim(bytes);
  if (meta.frames.isEmpty) {
    throw StateError('no ANMF frames found');
  }
  final compositor = WebpEngineCompositor(meta.canvasW, meta.canvasH);
  final frames = <ui.Image>[];
  final durations = <Duration>[];
  try {
    for (var i = 0; i < meta.frames.length; i++) {
      final f = meta.frames[i];
      final standalone = buildStandaloneFrameWebp(f);
      final codec = await ui.instantiateImageCodec(standalone);
      final hi = await codec.getNextFrame();
      final prev = i > 0 ? meta.frames[i - 1] : null;
      final out = await compositor.composite(prev, f, hi.image);
      hi.image.dispose();
      codec.dispose();
      frames.add(out);
      durations.add(Duration(milliseconds: f.durationMs));
    }
  } on Object {
    // Partial decode: free frames completed so far before propagating.
    for (final f in frames) {
      f.dispose();
    }
    rethrow;
  }
  return EmoteFrameData(frames: frames, durations: durations);
}

/// Fallback decode via engine codec. Known transparency bugs for animated WebP.
Future<EmoteFrameData> _decodeWithEngineCodec(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frames = <ui.Image>[];
  final durations = <Duration>[];
  try {
    for (var i = 0; i < codec.frameCount; i++) {
      final frame = await codec.getNextFrame();
      frames.add(frame.image);
      durations.add(frame.duration);
    }
  } finally {
    // Engine codec holds native memory; must dispose here too.
    codec.dispose();
  }
  return EmoteFrameData(frames: frames, durations: durations);
}

Future<EmoteFrameData> _decodeStatic(Uint8List bytes) async {
  // Static images: engine codec is safe (no animated-codec bug).
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    return EmoteFrameData(frames: [frame.image], durations: [Duration.zero]);
  } finally {
    codec.dispose();
  }
}
