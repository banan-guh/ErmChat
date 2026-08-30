import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:image/image.dart' as img;

import '../services/emote_cache_manager.dart';
import '../util/webp_anim.dart';
import 'emote_image_provider.dart';
import 'emote_loading_band.dart';
import 'emote_probe_memo.dart';

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

typedef EmoteFrameDecoder = Future<EmoteFrameData> Function(Uint8List bytes);

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

/// Pure-Dart animated WebP decode. Exposed for tests.
@visibleForTesting
Future<EmoteFrameData> decodeWebpPureDart(Uint8List bytes) =>
    _decodeWebp(bytes);

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

Future<EmoteFrameData> _decodeWebp(Uint8List bytes) async {
  final decoded = await Isolate.run(() {
    final decoder = img.WebPDecoder(bytes);
    final info = decoder.startDecode(bytes);
    if (info == null) {
      throw StateError('WebP decode failed');
    }
    // Non-animated WebP: single frame, no compositing needed
    if (!info.hasAnimation) {
      final frameImg = decoder.decodeFrame(0);
      if (frameImg == null) {
        throw StateError('WebP single frame decode failed');
      }
      final converted = frameImg.convert(numChannels: 4);
      return _WebpAnimResult(
        rgba: [converted.toUint8List()],
        durations: [Duration.zero],
        canvasW: converted.width,
        canvasH: converted.height,
      );
    }
    // Animated WebP
    final canvasW = info.width;
    final canvasH = info.height;
    final numFrames = info.numFrames;

    // Parse ANMF flags (blend) from raw bytes
    final framesMeta = _parseAnmfFrames(bytes, canvasW, canvasH);

    final rgba = <Uint8List>[];
    final durations = <Duration>[];

    // Compositing canvas, always transparent.
    final canvas = img.Image(width: canvasW, height: canvasH, numChannels: 4);
    canvas.clear(img.ColorRgba8(0, 0, 0, 0));

    for (var i = 0; i < numFrames; i++) {
      final frameInfo = info.frames[i];
      final frameImg = decoder.decodeFrame(i);
      if (frameImg == null) {
        // Empty frame - snapshot current canvas
        final snapshot = img.Image.fromBytes(
          width: canvasW,
          height: canvasH,
          numChannels: 4,
          bytes: canvas.toUint8List().buffer,
        );
        rgba.add(snapshot.toUint8List());
        final ms = frameInfo.duration;
        durations.add(
          ms > 0
              ? Duration(milliseconds: ms)
              : const Duration(milliseconds: 80),
        );
        continue;
      }

      // Convert frame to RGBA
      final converted = frameImg.convert(numChannels: 4);

      // Get frame metadata
      final noBlend = (i < framesMeta.length) ? framesMeta[i].noBlend : false;

      // Apply previous frame's disposal before compositing current.
      if (i > 0 && i - 1 < framesMeta.length) {
        final prevMeta = framesMeta[i - 1];
        if (prevMeta.disposeToBackground) {
          final prevInfo = info.frames[i - 1];
          final clearImg = img.Image(
            width: prevInfo.width,
            height: prevInfo.height,
            numChannels: 4,
          );
          clearImg.clear(img.ColorRgba8(0, 0, 0, 0));
          img.compositeImage(
            canvas,
            clearImg,
            dstX: prevInfo.x,
            dstY: prevInfo.y,
            blend: img.BlendMode.direct,
          );
        }
      }

      // Blend current frame
      if (noBlend) {
        // NO_BLEND: overwrite pixels directly (including alpha)
        img.compositeImage(
          canvas,
          converted,
          dstX: frameInfo.x,
          dstY: frameInfo.y,
          blend: img.BlendMode.direct,
        );
      } else {
        // Alpha blend per WebP spec.
        _compositeWebpBlend(canvas, converted, frameInfo.x, frameInfo.y);
      }

      // Snapshot current canvas as this frame's output.
      rgba.add(canvas.toUint8List());

      final ms = frameInfo.duration;
      durations.add(
        ms > 0 ? Duration(milliseconds: ms) : const Duration(milliseconds: 80),
      );
    }

    return _WebpAnimResult(
      rgba: rgba,
      durations: durations,
      canvasW: canvasW,
      canvasH: canvasH,
    );
  });

  // Create ui.Images from composited RGBA frames
  final out = <ui.Image>[];
  for (var i = 0; i < decoded.rgba.length; i++) {
    out.add(
      await _imageFromRgba(
        decoded.rgba[i].buffer,
        decoded.canvasW,
        decoded.canvasH,
      ),
    );
  }
  return EmoteFrameData(frames: out, durations: decoded.durations);
}

class _WebpAnimResult {
  _WebpAnimResult({
    required this.rgba,
    required this.durations,
    required this.canvasW,
    required this.canvasH,
  });
  final List<Uint8List> rgba;
  final List<Duration> durations;
  final int canvasW;
  final int canvasH;
}

class _FrameMeta {
  _FrameMeta({required this.noBlend, required this.disposeToBackground});
  final bool noBlend;
  final bool disposeToBackground;
}

/// WebP straight-alpha blend over [dst] at ([dstX],[dstY]). [src] must be RGBA, [dst] modified in place.
void _compositeWebpBlend(img.Image dst, img.Image src, int dstX, int dstY) {
  final srcW = src.width;
  final srcH = src.height;
  final dstW = dst.width;
  final dstH = dst.height;

  final srcBytes = src.toUint8List();
  final dstBytes = dst.toUint8List();

  for (var y = 0; y < srcH; y++) {
    final dy = dstY + y;
    if (dy < 0 || dy >= dstH) continue;
    for (var x = 0; x < srcW; x++) {
      final dx = dstX + x;
      if (dx < 0 || dx >= dstW) continue;

      final srcIdx = (y * srcW + x) * 4;
      final dstIdx = (dy * dstW + dx) * 4;

      final srcA = srcBytes[srcIdx + 3];
      if (srcA == 0) continue; // Fully transparent source: no change

      final dstR = dstBytes[dstIdx];
      final dstG = dstBytes[dstIdx + 1];
      final dstB = dstBytes[dstIdx + 2];
      final dstA = dstBytes[dstIdx + 3];

      // WebP blend formula (straight alpha, per spec)
      // blend.A = src.A + dst.A * (1 - src.A/255)
      // blend.RGB = (src.RGB*src.A + dst.RGB*dst.A*(1 - src.A/255)) / blend.A
      final invSrcA = 255 - srcA;
      final blendA = srcA + (dstA * invSrcA) ~/ 255;
      if (blendA == 0) {
        dstBytes[dstIdx] = 0;
        dstBytes[dstIdx + 1] = 0;
        dstBytes[dstIdx + 2] = 0;
        dstBytes[dstIdx + 3] = 0;
        continue;
      }

      final srcR = srcBytes[srcIdx];
      final srcG = srcBytes[srcIdx + 1];
      final srcB = srcBytes[srcIdx + 2];

      // Numerator first to avoid precision loss.
      final r = (srcR * srcA + (dstR * dstA * invSrcA) ~/ 255) ~/ blendA;
      final g = (srcG * srcA + (dstG * dstA * invSrcA) ~/ 255) ~/ blendA;
      final b = (srcB * srcA + (dstB * dstA * invSrcA) ~/ 255) ~/ blendA;

      dstBytes[dstIdx] = r.clamp(0, 255);
      dstBytes[dstIdx + 1] = g.clamp(0, 255);
      dstBytes[dstIdx + 2] = b.clamp(0, 255);
      dstBytes[dstIdx + 3] = blendA;
    }
  }
}

List<_FrameMeta> _parseAnmfFrames(Uint8List bytes, int canvasW, int canvasH) {
  // Walk RIFF chunks for ANMF frame flags.
  if (bytes.length < 12 ||
      bytes[0] != 0x52 ||
      bytes[1] != 0x49 ||
      bytes[2] != 0x46 ||
      bytes[3] != 0x46) {
    return [];
  }
  if (bytes[8] != 0x57 ||
      bytes[9] != 0x45 ||
      bytes[10] != 0x42 ||
      bytes[11] != 0x50) {
    return [];
  }

  final metas = <_FrameMeta>[];
  int pos = 12;
  while (pos + 8 <= bytes.length) {
    final fourcc = String.fromCharCodes(bytes.sublist(pos, pos + 4));
    final chunkSize =
        bytes[pos + 4] |
        (bytes[pos + 5] << 8) |
        (bytes[pos + 6] << 16) |
        (bytes[pos + 7] << 24);
    final chunkDataStart = pos + 8;
    final chunkDataEnd = chunkDataStart + chunkSize;
    if (chunkDataEnd > bytes.length) break;

    if (fourcc == 'ANMF') {
      // ANMF payload: x(3) y(3) w(3) h(3) dur(3) flags(1) + frame data
      if (chunkDataStart + 16 <= chunkDataEnd) {
        final data = bytes.sublist(chunkDataStart, chunkDataEnd);
        int p = 0;
        // Skip x,y,w,h,dur (15 bytes)
        p += 15;
        final flags = data[p];
        final noBlend = (flags & 0x02) != 0;
        final disposeToBackground = (flags & 0x01) != 0;
        metas.add(
          _FrameMeta(
            noBlend: noBlend,
            disposeToBackground: disposeToBackground,
          ),
        );
      }
    }

    pos = chunkDataEnd + (chunkSize & 1); // pad byte
  }
  return metas;
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

Uint8List _premultiply(Uint8List rgba) {
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

Future<ui.Image> _imageFromRgba(ByteBuffer rgba, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    _premultiply(rgba.asUint8List()),
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// Emote renderer using [EmoteUrlProvider]'s shared completer. Animated WebP via reinforced decoder; GIFs/static via engine codec.
class EmoteImage extends StatefulWidget {
  const EmoteImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.placeholder,
    this.errorWidget,
    this.alternateUrls,
    this.uncapped = false,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;

  /// Smaller-scale URLs tried as placeholders while [url] loads.
  final List<String>? alternateUrls;

  /// Plays at native rate regardless of FPS cap. Used by emote panel.
  final bool uncapped;

  @override
  State<EmoteImage> createState() => _EmoteImageState();
}

/// Transparent loading placeholder with a shared-clock sweep band.
class EmoteLoadingPlaceholder extends StatelessWidget {
  const EmoteLoadingPlaceholder({super.key, this.width, this.height});

  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return LoadingBand(width: width, height: height);
  }
}

class _EmoteImageState extends State<EmoteImage> {
  /// Cached smaller-scale placeholder URL (null until probed).
  String? _placeholderUrl;
  Object? _loadToken;

  /// Uncapped URLs synced with [EmoteImage.uncapped].
  final Set<String> _uncappedUrls = {};

  @override
  void initState() {
    super.initState();
    _syncUncappedRegistrations();
    _probePlaceholder();
  }

  /// Syncs uncapped registrations with the desired set.
  void _syncUncappedRegistrations() {
    final desired = <String>{
      if (widget.uncapped) widget.url,
      if (widget.uncapped && _placeholderUrl != null) _placeholderUrl!,
    };
    for (final url in _uncappedUrls.difference(desired)) {
      EmoteUrlProvider.removeUncapped(url);
    }
    for (final url in desired.difference(_uncappedUrls)) {
      EmoteUrlProvider.addUncapped(url);
    }
    _uncappedUrls
      ..clear()
      ..addAll(desired);
  }

  /// Probes alternate scales for a cached placeholder while [url] loads. Picks first hit. Disk results memoized via [EmoteProbeMemo].
  Future<void> _probePlaceholder() async {
    final alternates = widget.alternateUrls;
    if (alternates == null || alternates.isEmpty) return;
    final token = Object();
    _loadToken = token;
    for (final altUrl in alternates) {
      if (!mounted || _loadToken != token) return;
      if (altUrl == widget.url) continue;
      // Memory hits resolve sync (first frame); disk via memoized probe.
      if (PaintingBinding.instance.imageCache.containsKey(
        EmoteUrlProvider(altUrl),
      )) {
        _setPlaceholder(altUrl, token);
        // Seed playback so the swap continues in phase.
        EmoteUrlProvider.seedPlayback(widget.url, altUrl);
        return;
      }
      final bool cached;
      try {
        cached = await EmoteProbeMemo.instance.probe(altUrl, _isAltOnDisk);
      } on Object {
        // Try the next alternate; any error just means no cached placeholder.
        continue;
      }
      if (!mounted || _loadToken != token) return;
      if (cached) {
        _setPlaceholder(altUrl, token);
        EmoteUrlProvider.seedPlayback(widget.url, altUrl);
        return;
      }
    }
  }

  /// Whether [url] is still in the disk cache.
  static Future<bool> _isAltOnDisk(String url) async =>
      await EmoteCacheManager().getFileFromCache(url) != null;

  void _setPlaceholder(String altUrl, Object token) {
    // Defer setState: probe resolves async (can land mid-build).
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loadToken != token) return;
      if (_placeholderUrl == altUrl) return;
      setState(() => _placeholderUrl = altUrl);
      _syncUncappedRegistrations();
    });
  }

  @override
  void dispose() {
    // Invalidate any in-flight probe; the completer/cache own the rest.
    _loadToken = Object();
    for (final url in _uncappedUrls) {
      EmoteUrlProvider.removeUncapped(url);
    }
    _uncappedUrls.clear();
    super.dispose();
  }

  @override
  void didUpdateWidget(EmoteImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url) {
      _loadToken = Object();
      _placeholderUrl = null;
      _probePlaceholder();
    }
    if (widget.uncapped != oldWidget.uncapped || widget.url != oldWidget.url) {
      _syncUncappedRegistrations();
    }
  }

  /// Stacks main image (bottom) with overlay (top). Finite size clamps the stack; otherwise fills on bounded-tight constraints.
  Widget _loadingStack(Widget main, Widget overlay) {
    final width = widget.width;
    final height = widget.height;
    final finite =
        (width != null && width.isFinite) ||
        (height != null && height.isFinite);
    if (finite) {
      return SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: width != null && height != null
              ? StackFit.expand
              : StackFit.loose,
          alignment: Alignment.center,
          children: [main, overlay],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded =
            constraints.hasBoundedWidth && constraints.hasBoundedHeight;
        final fill = bounded && (widget.width != null || constraints.isTight);
        if (fill) {
          return Stack(
            fit: StackFit.expand,
            alignment: Alignment.center,
            children: [main, overlay],
          );
        }
        return Stack(alignment: Alignment.center, children: [main, overlay]);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final altUrl = _placeholderUrl;
    return Image(
      // Key by URL: recycled widgets must not show stale frames during load.
      key: ValueKey(widget.url),
      image: EmoteUrlProvider(widget.url),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        // First frame replaces overlay; gaplessPlayback keeps previous frame on URL change.
        if (frame != null) return child;
        final Widget overlay;
        if (altUrl != null) {
          // Cached smaller scale under a faint band; seeds required URL on swap. Fills box via _loadingStack.
          overlay = _loadingStack(
            Image(
              key: ValueKey('ph-$altUrl'),
              image: EmoteUrlProvider(altUrl),
              fit: widget.fit,
              gaplessPlayback: true,
            ),
            SizedBox(
              width: widget.width,
              height: widget.height,
              child: LoadingBand(opacity: 0.25),
            ),
          );
        } else {
          overlay =
              widget.placeholder ??
              EmoteLoadingPlaceholder(
                width: widget.width,
                height: widget.height,
              );
        }
        return _loadingStack(child, overlay);
      },
      errorBuilder: (context, error, stack) =>
          widget.errorWidget ?? const Icon(Icons.broken_image, size: 20),
    );
  }
}
