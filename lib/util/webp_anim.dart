import 'dart:typed_data';
import 'dart:ui' as ui;

/// ANMF frame metadata + bitstream (ALPH + VP8/VP8L subchunks).
class WebpFrameMeta {
  const WebpFrameMeta({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.durationMs,
    required this.noBlend,
    required this.disposeToBackground,
    required this.bitstream,
  });

  final int x, y, w, h;
  final int durationMs;
  final bool noBlend;
  final bool disposeToBackground;
  final Uint8List bitstream;
}

/// Parsed animated-WebP container: global canvas + per-frame metadata.
class WebpAnimInfo {
  const WebpAnimInfo({
    required this.isAnimated,
    required this.hasAlpha,
    required this.canvasW,
    required this.canvasH,
    required this.bgColor,
    required this.frames,
  });

  final bool isAnimated;
  final bool hasAlpha;
  final int canvasW, canvasH;
  final int bgColor;
  final List<WebpFrameMeta> frames;
}

int _u24(Uint8List b, int o) =>
    (b[o] & 0xff) | ((b[o + 1] & 0xff) << 8) | ((b[o + 2] & 0xff) << 16);

List<int> _u32(int v) =>
    [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

/// Parses WebP RIFF for animation metadata. Returns non-animated info if not WebP or no ANMF chunks.
WebpAnimInfo parseWebpAnim(Uint8List bytes) {
  if (bytes.length < 12 ||
      bytes[0] != 0x52 ||
      bytes[1] != 0x49 ||
      bytes[2] != 0x46 ||
      bytes[3] != 0x46 ||
      bytes[8] != 0x57 ||
      bytes[9] != 0x45 ||
      bytes[10] != 0x42 ||
      bytes[11] != 0x50) {
    return const WebpAnimInfo(
      isAnimated: false,
      hasAlpha: false,
      canvasW: 0,
      canvasH: 0,
      bgColor: 0,
      frames: [],
    );
  }
  var hasAlpha = false;
  var isAnimated = false;
  var canvasW = 0;
  var canvasH = 0;
  var bgColor = 0;
  final frames = <WebpFrameMeta>[];
  var pos = 12;
  while (pos + 8 <= bytes.length) {
    final fourcc = String.fromCharCodes(bytes.sublist(pos, pos + 4));
    final size = (bytes[pos + 4] & 0xff) |
        ((bytes[pos + 5] & 0xff) << 8) |
        ((bytes[pos + 6] & 0xff) << 16) |
        ((bytes[pos + 7] & 0xff) << 24);
    final bodyStart = pos + 8;
    final bodyEnd = bodyStart + size;
    if (bodyEnd > bytes.length) break;
    final body = bytes.sublist(bodyStart, bodyEnd);
    if (fourcc == 'VP8X' && size >= 10) {
      hasAlpha = (body[0] & 0x10) != 0;
      canvasW = _u24(body, 4) + 1;
      canvasH = _u24(body, 7) + 1;
    } else if (fourcc == 'ANIM' && size >= 6) {
      isAnimated = true;
      bgColor = body[0] |
          (body[1] << 8) |
          (body[2] << 16) |
          (body[3] << 24);
    } else if (fourcc == 'ANMF' && size >= 16) {
      isAnimated = true;
      final x = _u24(body, 0);
      final y = _u24(body, 3);
      final w = _u24(body, 6) + 1;
      final h = _u24(body, 9) + 1;
      final dur = _u24(body, 12);
      final flags = body[15];
      final disposeToBackground = (flags & 0x01) != 0;
      // ANMF flags: bit 1 = blending (0=alpha-blend, 1=overwrite).
      final noBlend = ((flags >> 1) & 0x01) != 0;
      final bitstream = bytes.sublist(bodyStart + 16, bodyEnd);
      frames.add(
        WebpFrameMeta(
          x: x,
          y: y,
          w: w,
          h: h,
          durationMs: dur,
          noBlend: noBlend,
          disposeToBackground: disposeToBackground,
          bitstream: bitstream,
        ),
      );
    }
    if (size >= bytes.length) break;
    pos = bodyEnd + (size & 1);
  }
  return WebpAnimInfo(
    isAnimated: isAnimated,
    hasAlpha: hasAlpha,
    canvasW: canvasW,
    canvasH: canvasH,
    bgColor: bgColor,
    frames: frames,
  );
}

/// Whether [b] contains an ALPH subchunk (frame has its own alpha).
bool _frameHasAlpha(Uint8List b) {
  var p = 0;
  while (p + 8 <= b.length) {
    final fc = String.fromCharCodes(b.sublist(p, p + 4));
    final sz = (b[p + 4] & 0xff) |
        ((b[p + 5] & 0xff) << 8) |
        ((b[p + 6] & 0xff) << 16) |
        ((b[p + 7] & 0xff) << 24);
    if (fc == 'ALPH') return true;
    // The alpha chunk always precedes the bitstream chunk when present.
    if (fc == 'VP8 ' || fc == 'VP8L') return false;
    final end = p + 8 + sz;
    if (end > b.length) break;
    p = end + (sz & 1);
  }
  return false;
}

/// Wraps a frame's ALPH+VP8/VP8L payload in a standalone single-frame WebP for independent decode.
Uint8List buildStandaloneFrameWebp(WebpFrameMeta f) {
  final fa = _frameHasAlpha(f.bitstream);
  final inner = <int>[];
  if (fa) {
    inner.addAll([0x56, 0x50, 0x38, 0x58]); // 'VP8X'
    inner.addAll(_u32(10));
    inner.add(0x10); // alpha flag
    inner.add(0);
    inner.add(0);
    inner.add(0);
    inner.addAll([
      (f.w - 1) & 0xff,
      ((f.w - 1) >> 8) & 0xff,
      ((f.w - 1) >> 16) & 0xff,
    ]);
    inner.addAll([
      (f.h - 1) & 0xff,
      ((f.h - 1) >> 8) & 0xff,
      ((f.h - 1) >> 16) & 0xff,
    ]);
  }
  inner.addAll(f.bitstream);
  final riff = <int>[0x52, 0x49, 0x46, 0x46];
  riff.addAll(_u32(4 + inner.length));
  riff.addAll([0x57, 0x45, 0x42, 0x50]);
  riff.addAll(inner);
  return Uint8List.fromList(riff);
}

/// Composites WebP frames into full-canvas ui.Images using Flutter canvas, implementing blend/dispose rules. Bypasses the engine's buggy animated compositor.
class WebpEngineCompositor {
  WebpEngineCompositor(this.canvasW, this.canvasH);

  final int canvasW;
  final int canvasH;
  ui.Image? _prev;

  /// Composites [frameBitmap] atop the previous canvas with prior disposal applied. Caller owns the returned image.
  Future<ui.Image> composite(
    WebpFrameMeta? prevMeta,
    WebpFrameMeta meta,
    ui.Image frameBitmap,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    if (_prev != null) {
      canvas.drawImage(_prev!, ui.Offset.zero, ui.Paint());
      if (prevMeta != null && prevMeta.disposeToBackground) {
        // Dispose-to-background: clear prev frame's rect to transparent.
        final p = ui.Paint()..blendMode = ui.BlendMode.clear;
        canvas.drawRect(
          ui.Rect.fromLTWH(
            prevMeta.x.toDouble(),
            prevMeta.y.toDouble(),
            prevMeta.w.toDouble(),
            prevMeta.h.toDouble(),
          ),
          p,
        );
      }
    }
    final paint = ui.Paint()
      ..blendMode = meta.noBlend ? ui.BlendMode.src : ui.BlendMode.srcOver;
    canvas.drawImage(
      frameBitmap,
      ui.Offset(meta.x.toDouble(), meta.y.toDouble()),
      paint,
    );
    final image = await recorder.endRecording().toImage(canvasW, canvasH);
    _prev?.dispose();
    _prev = image;
    return image;
  }
}
