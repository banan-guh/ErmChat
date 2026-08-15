import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:image/image.dart' as img;
import 'package:shimmer/shimmer.dart';

import '../services/emote_cache_manager.dart';
import '../services/emote_codec/native_emote_codec.dart';
import 'emote_image_provider.dart';

/// Decoded emote frames with their per-frame durations.
///
/// The frames are owned by the playback stream the emote image provider
/// produces (one completer per URL, cached by the stock [ImageCache]);
/// renderers must not dispose them. [EmoteImage] renders via the stock
/// [Image] widget, which holds clone handles to the frames.
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

/// Sniffs the image format from magic bytes. Exposed for tests; renderers use
/// it to pick the decode path.
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
      // The engine codec renders animated GIFs correctly (interlace,
      // transparency and disposal are all solid); the known bug is specific
      // to animated WebP. Route GIFs native to avoid the isolate-heavy
      // pure-Dart decoder.
      return _decodeWithEngineCodec(bytes);
    case EmoteFormat.webp:
      // Animated WebP is the only format that hits the engine codec's
      // compositing/transparency bug (grey artifacts, wrong disposal), so it
      // gets the native libwebp decoder (when present) with the pure-Dart
      // decoder as fallback. Static WebP is safe natively and much cheaper.
      if (webpIsAnimated(bytes)) {
        return _decodeAnimatedWebp(bytes);
      }
      return _decodeStatic(bytes);
    case EmoteFormat.other:
      return _decodeStatic(bytes);
  }
}

/// True when a WebP has an ANMF frame chunk (i.e. it is animated). Static
/// WebP decodes cheaper through the engine codec, so the emote pipeline
/// routes only animated WebP to the reinforced decoder. Exposed for tests.
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

/// Production decode pipeline: sniff format → decode (pure-Dart isolate for
/// animated WebP only, engine codec for everything else) → premultiply alpha
/// → decodeImageFromPixels → ui.Image. This is the exact path used by the
/// emote image provider's animated-WebP branch.
Future<EmoteFrameData> decodeEmoteBytes(Uint8List bytes) => _decodeBytes(bytes);

/// Animated WebP via the native libwebp shim, falling back to the pure-Dart
/// decoder when the library is missing or the decode fails.
Future<EmoteFrameData> _decodeAnimatedWebp(Uint8List bytes) async {
  try {
    final native = await NativeEmoteCodec.decodeWebp(bytes);
    if (native != null) return native;
  } catch (_) {
    // Fall through to the pure-Dart decoder.
  }
  return _decodeWebp(bytes);
}

/// Pure-Dart animated WebP decode (the [NativeEmoteCodec] fallback). Exposed
/// for tests that want to compare against the reference decoder regardless of
/// the production dispatch in [_decodeAnimatedWebp].
@visibleForTesting
Future<EmoteFrameData> decodeWebpPureDart(Uint8List bytes) =>
    _decodeWebp(bytes);

/// Fallback decode using Flutter's engine codec for all formats (including animated).
/// Uses [instantiateImageCodec] which handles frame durations but has known
/// transparency/compositing bugs for animated WebP.
Future<EmoteFrameData> _decodeWithEngineCodec(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frames = <ui.Image>[];
  final durations = <Duration>[];
  for (var i = 0; i < codec.frameCount; i++) {
    final frame = await codec.getNextFrame();
    frames.add(frame.image);
    durations.add(frame.duration);
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

    // Canvas for compositing - ALWAYS transparent for emote overlay
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

      // Apply PREVIOUS frame's disposal before compositing current frame
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
        // Normal alpha blend — use WebP's exact straight-alpha formula
        _compositeWebpBlend(canvas, converted, frameInfo.x, frameInfo.y);
      }

      // Snapshot current canvas as this frame's output (explicit copy to avoid aliasing)
      final frameBytes = Uint8List.fromList(canvas.toUint8List());
      final snapshot = img.Image.fromBytes(
        width: canvasW,
        height: canvasH,
        numChannels: 4,
        bytes: frameBytes.buffer,
      );
      rgba.add(snapshot.toUint8List());

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

/// Composites [src] over [dst] using WebP's exact straight-alpha blend formula.
///
/// WebP spec (straight alpha):
///   blend.A = src.A + dst.A * (1 - src.A/255)
///   blend.RGB = (src.RGB*src.A + dst.RGB*dst.A*(1 - src.A/255)) / blend.A
///
/// This is NOT the same as generic `srcOver` (which uses `src.A + dst.A*(1-src.A)`).
/// WebP normalizes by the resulting alpha, not the source alpha.
///
/// [src] must be 4-channel (RGBA). [dst] is modified in place.
/// [dstX], [dstY] is the top-left position of [src] within [dst].
/// Blending is clipped to [dst] bounds.
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

      // Integer math matching spec: (src*srcA + dst*dstA*invSrcA/255) / blendA
      // We compute numerator first to avoid intermediate precision loss.
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
  // Walk RIFF chunks to find ANMF frames and read their flags byte (blend bit)
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
  // Single-frame path for PNG and anything else that isn't GIF/WebP. Static
  // images never hit the animated-codec bug (disposal/compositing), so the
  // engine codec is safe here.
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

/// Emote renderer that never relies on the engine's animated-WebP codec.
///
/// Bytes are fetched through [EmoteUrlProvider] -> [fetchEmoteBytes]
/// ([EmoteCacheManager]'s settings cap and overflow path both apply) and
/// decoded inside the shared completer the stock [ImageCache] keeps per URL:
/// animated WebP uses the reinforced decoder (native libwebp, pure-Dart
/// fallback), while GIFs and static images route through the engine codec.
/// Playback is driven by the completer, so every widget showing the same
/// emote stays in sync.
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
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;

  /// Smaller-scale URLs (e.g. the emote's 1x) tried as cached placeholders
  /// while [url] is still fetching. When a smaller scale is already cached in
  /// memory or on disk it renders under a faint shimmer instead of an empty
  /// box.
  final List<String>? alternateUrls;

  @override
  State<EmoteImage> createState() => _EmoteImageState();
}

/// Shimmer placeholder shown while an emote's frames are still loading.
///
/// [Shimmer] sweeps a moving gradient over the child, which acts as an alpha
/// mask (the shimmer composites with `srcIn`, so the child's color is
/// ignored). The base color is transparent so the placeholder never hides
/// content underneath it (e.g. a zero-width overlay must not obscure the base
/// emote it sits on); only the moving highlight band paints.
class ShimmerEmotePlaceholder extends StatelessWidget {
  const ShimmerEmotePlaceholder({super.key, this.width, this.height});

  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final highlight = scheme.surfaceContainerHighest;
    return Shimmer.fromColors(
      baseColor: Colors.transparent,
      highlightColor: highlight,
      child: Container(width: width, height: height, color: Colors.white),
    );
  }
}

class _EmoteImageState extends State<EmoteImage> {
  /// A smaller cached scale shown under a faint shimmer while the required
  /// URL loads (null until the probe finds one).
  String? _placeholderUrl;
  Object? _loadToken;

  @override
  void initState() {
    super.initState();
    _probePlaceholder();
  }

  /// Probes the smaller alternate scales for a cached copy to use as the
  /// placeholder while [EmoteImage.url] is loading. Picks the first hit (the
  /// smallest scale is listed first by convention). Memory-cached copies
  /// render from the shared completer (animated in sync with the rest of the
  /// app); disk-cached copies fetch through the same provider path.
  Future<void> _probePlaceholder() async {
    final alternates = widget.alternateUrls;
    if (alternates == null || alternates.isEmpty) return;
    final token = Object();
    _loadToken = token;
    for (final altUrl in alternates) {
      if (!mounted || _loadToken != token) return;
      if (altUrl == widget.url) continue;
      if (PaintingBinding.instance.imageCache.containsKey(
        EmoteUrlProvider(altUrl),
      )) {
        debugPrint('[EmoteImage] placeholder memory-hit altUrl=$altUrl');
        _setPlaceholder(altUrl, token);
        // Continue the placeholder's animation clock on the required URL so
        // the swap happens in phase (same emote, higher scale) instead of
        // restarting from frame 0.
        EmoteUrlProvider.seedPlayback(widget.url, altUrl);
        return;
      }
      try {
        final file = await EmoteCacheManager().getFileFromCache(altUrl);
        if (!mounted || _loadToken != token) return;
        if (file != null) {
          debugPrint(
            '[EmoteImage] placeholder disk-hit altUrl=$altUrl '
            'file=${file.file.path}',
          );
          _setPlaceholder(altUrl, token);
          return;
        }
        debugPrint('[EmoteImage] placeholder miss altUrl=$altUrl');
      } on Object catch (e) {
        // Try the next alternate; any error just means no cached placeholder.
        debugPrint('[EmoteImage] placeholder error altUrl=$altUrl err=$e');
      }
    }
  }

  void _setPlaceholder(String altUrl, Object token) {
    // The probe can resolve mid-build (async disk I/O completes between
    // frames); defer the setState so it never lands inside a build phase.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loadToken != token) return;
      if (_placeholderUrl == altUrl) return;
      setState(() => _placeholderUrl = altUrl);
    });
  }

  @override
  void dispose() {
    // Invalidate any in-flight probe; the completer/cache own the rest.
    _loadToken = Object();
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
  }

  /// Wraps the loading state: the (frameless) main image on the bottom with
  /// [overlay] (a placeholder or a cached smaller scale under a faint
  /// shimmer) on top.
  ///
  /// A Stack with positioned/filled children requires bounded constraints
  /// (e.g. [EmoteImage] with `double.infinity` inside an unbounded parent
  /// would crash), so the fill behavior only applies when the incoming
  /// constraints are bounded; otherwise the children keep their own size,
  /// matching the old raw-image behavior.
  Widget _loadingStack(Widget main, Widget overlay) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded =
            constraints.hasBoundedWidth && constraints.hasBoundedHeight;
        if (bounded) {
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
      // Key by URL: when a recycled widget (e.g. an autocomplete row whose
      // list content shifted) switches to a different emote, the inner Image
      // state is recreated so gaplessPlayback can never keep painting the
      // previous emote's stale frame while the new URL loads.
      key: ValueKey(widget.url),
      image: EmoteUrlProvider(widget.url),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        // The first frame replaces the loading overlay (errorBuilder handles
        // failures before this runs). gaplessPlayback keeps the previous
        // frame showing while a URL change loads, so the overlay only
        // appears on the first load.
        if (frame != null) return child;
        final Widget overlay;
        if (altUrl != null) {
          // A smaller cached scale is showing under a faint shimmer while
          // the required resolution loads. The placeholder follows the
          // alternate's own completer (animated in sync with chat; its
          // playback seeds the required URL when it lands); the shimmer
          // sweep stays subtle so the emote reads clearly, only hinting
          // that a higher-res copy is coming.
          final scheme = Theme.of(context).colorScheme;
          final base = scheme.surface;
          final highlight = Color.lerp(
            base,
            scheme.surfaceContainerHighest,
            0.7,
          )!;
          // _loadingStack expands the alternate to fill the box (like the
          // required image) so a small cached scale scales up instead of
          // rendering at its intrinsic size.
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
              child: Shimmer.fromColors(
                baseColor: base.withValues(alpha: 0.25),
                highlightColor: highlight.withValues(alpha: 0.25),
                period: const Duration(milliseconds: 1200),
                child: const ColoredBox(color: Colors.white),
              ),
            ),
          );
        } else {
          overlay =
              widget.placeholder ??
              ShimmerEmotePlaceholder(
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
