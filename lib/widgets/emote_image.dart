import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:image/image.dart' as img;
import 'package:shimmer/shimmer.dart';

import '../services/emote_cache_manager.dart';

/// Decoded emote frames with their per-frame durations.
///
/// The frames are owned by the [EmoteClipRegistry] clip that produced them;
/// renderers must not dispose them. [EmoteImage] releases the clip (which
/// disposes the frames) when the last widget using it unmounts.
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

/// Per-URL cache of decoded emote frames with an LRU byte cap (100 MB default,
/// matching Flutter's [ImageCache]). Clips are retained until the cap is
/// exceeded, then least-recently-used clips are evicted.
class EmoteClipRegistry {
  /// Test hooks; fall back to the production fetcher/decoder when null.
  @visibleForTesting
  static Future<Uint8List> Function(String url)? debugFetchOverride;

  @visibleForTesting
  static EmoteFrameDecoder? debugDecodeOverride;

  /// Maximum bytes for all cached decoded frames (default 100 MB, like
  /// Flutter's [ImageCache]).
  static const int _defaultMaxBytes = 100 << 20;

  static final EmoteClipRegistry instance = EmoteClipRegistry();

  final Map<String, _EmoteClip> _clips = {};
  int _totalBytes = 0;
  final int _maxBytes = _defaultMaxBytes;

  /// Registers a reference to [url] and returns the decoded frames. Throws
  /// (with the original error) when the fetch or decode fails; the next
  /// [acquire] of the same URL after a failure retries.
  ///
  /// [debugFetchOverride] (tests) then [_fetchBytes] apply.
  Future<EmoteFrameData> acquire(String url) {
    final clip = _clips.putIfAbsent(url, () => _EmoteClip(url: url));
    if (clip.refs == 0) {
      clip.lastAccessed = DateTime.now();
    }
    clip.refs++;
    final pending = clip.decode;
    if (pending != null) return pending;
    final future = _load(url, clip);
    clip.decode = future;
    return future;
  }

  /// Registers a reference to [url] and returns its frames synchronously when
  /// the clip is already decoded and cached. Returns null when the clip is
  /// missing, still loading, or previously failed; callers fall back to
  /// [acquire] and show a placeholder while it loads.
  ///
  /// Like [acquire], the returned frames imply a reference that must be
  /// balanced with [release].
  EmoteFrameData? tryAcquireCached(String url) {
    final clip = _clips[url];
    final frames = clip?.frames;
    if (clip == null || frames == null) return null;
    if (clip.refs == 0) {
      clip.lastAccessed = DateTime.now();
    }
    clip.refs++;
    return frames;
  }

  /// Drops the reference count. The clip is kept in memory (not disposed)
  /// so subsequent acquires are instant. If the cache exceeds its byte cap,
  /// least-recently-used clips with zero refs are evicted.
  void release(String url) {
    final clip = _clips[url];
    if (clip == null) return;
    clip.refs--;
    clip.lastAccessed = DateTime.now();
    if (clip.refs <= 0 && !clip.hasActiveListeners) {
      clip.stopPlayback();
    }
    _evictIfNeeded();
  }

  /// Subscribes [listener] to the shared playback clock for [url], starting
  /// the shared ticker once frames are available. Must be called after
  /// [acquire] so the clip exists and the ref is held.
  void subscribe(String url, VoidCallback listener) {
    final clip = _clips[url];
    if (clip == null) return;
    clip.addListener(listener);
    clip.startPlaybackIfNeeded();
  }

  /// Removes [listener] from the shared playback clock; stops the ticker when
  /// no listeners remain.
  void unsubscribe(String url, VoidCallback listener) {
    final clip = _clips[url];
    if (clip == null) return;
    clip.removeListener(listener);
    if (!clip.hasActiveListeners && clip.refs <= 0) {
      clip.stopPlayback();
    }
  }

  /// Current shared frame index for [url] (0 when not cached).
  int currentFrame(String url) => _clips[url]?.frameIndex ?? 0;

  /// Test hook; disposes and drops every cached clip. Clips with active refs
  /// or listeners are left alone so widgets mid-paint never reference a
  /// disposed image.
  @visibleForTesting
  void debugClear() {
    final idle = _clips.values
        .where((c) => c.refs <= 0 && !c.hasActiveListeners)
        .toList();
    for (final clip in idle) {
      clip.refs = 0;
      clip.stopPlayback();
      final frames = clip.frames;
      if (frames != null) {
        _disposeFrames(frames);
      } else {
        clip.decode?.then(_disposeFrames, onError: (_) {});
      }
      _clips.remove(clip.url);
    }
    _totalBytes = _clips.values.fold(0, (sum, c) => sum + c.byteSize);
  }

  Future<EmoteFrameData> _load(String url, _EmoteClip clip) async {
    try {
      final fetch = debugFetchOverride ?? _fetchBytes;
      final decode = debugDecodeOverride ?? _decodeBytes;
      final bytes = await fetch(url);
      final frames = await decode(bytes);
      clip.frames = frames;
      clip.byteSize = _estimateByteSize(frames);
      clip.lastAccessed = DateTime.now();
      clip.startPlaybackIfNeeded();
      _totalBytes += clip.byteSize;
      _evictIfNeeded();
      return frames;
    } on Object catch (e) {
      clip.error = e;
      clip.decode = null;
      rethrow;
    }
  }

  void _evictIfNeeded() {
    if (_totalBytes <= _maxBytes) return;

    // Collect evictable clips (refs == 0), oldest first
    final evictable =
        _clips.values.where((c) => c.refs == 0 && c.frames != null).toList()
          ..sort((a, b) => a.lastAccessed.compareTo(b.lastAccessed));

    for (final clip in evictable) {
      if (_totalBytes <= _maxBytes) break;
      clip.stopPlayback();
      _disposeFrames(clip.frames!);
      _totalBytes -= clip.byteSize;
      _clips.remove(clip.url);
    }
  }

  static int _estimateByteSize(EmoteFrameData frames) {
    // All frames are full-canvas RGBA (canvasW x canvasH x 4 bytes)
    if (frames.frames.isEmpty) return 0;
    final frame = frames.frames.first;
    return frame.width * frame.height * 4 * frames.frames.length;
  }

  static void _disposeFrames(EmoteFrameData frames) {
    for (final frame in frames.frames) {
      frame.dispose();
    }
  }
}

/// One decoded emote clip plus the single shared playback clock for its URL.
/// Every [EmoteImage] rendering the same URL subscribes to the same clip, so
/// they all render the same frame at the same time (mirroring how Flutter's
/// ImageCache shares one ImageStreamCompleter per provider key).
class _EmoteClip extends ChangeNotifier {
  _EmoteClip({required this.url}) : lastAccessed = DateTime.now();

  final String url;
  int refs = 0;
  Future<EmoteFrameData>? decode;
  EmoteFrameData? frames;
  Object? error;
  int byteSize = 0;
  DateTime lastAccessed;

  Ticker? _ticker;
  int _frameIndex = 0;

  /// Current frame index of the shared playback clock.
  int get frameIndex => _frameIndex;

  /// Whether any [EmoteImage] is currently rendering this clip.
  bool get hasActiveListeners => hasListeners;

  /// Starts the shared ticker when the clip is animated and has listeners.
  void startPlaybackIfNeeded() {
    final frames = this.frames;
    if (_ticker != null || !hasListeners || frames == null || !frames.isAnimated) {
      return;
    }
    _ticker = Ticker(_onTick, debugLabel: 'emote-$url')..start();
  }

  /// Stops the shared ticker when the last listener detaches.
  void stopPlayback() {
    _ticker?.dispose();
    _ticker = null;
  }

  void _onTick(Duration elapsed) {
    final frames = this.frames;
    if (frames == null || !frames.isAnimated) return;
    final totalUs = frames.totalDuration.inMicroseconds;
    if (totalUs <= 0) return;
    var t = elapsed.inMicroseconds % totalUs;
    for (var i = 0; i < frames.durations.length; i++) {
      final d = frames.durations[i].inMicroseconds;
      if (t < d) {
        if (i != _frameIndex) {
          _frameIndex = i;
          notifyListeners();
        }
        return;
      }
      t -= d;
    }
    final last = frames.frames.length - 1;
    if (last != _frameIndex) {
      _frameIndex = last;
      notifyListeners();
    }
  }
}

Future<Uint8List> _fetchBytes(String url) async {
  // Stream (not getSingleFile) so a full cache still serves the overflow
  // temp file instead of throwing.
  await for (final response in EmoteCacheManager().getFileStream(url)) {
    if (response is FileInfo) {
      return response.file.readAsBytes();
    }
  }
  throw StateError('no emote bytes for $url');
}

/// Memory-only fetch used by bursty render sites (the emote menu): downloads
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
      // gets the reinforced pure-Dart decoder. Static WebP is safe natively
      // and much cheaper.
      if (webpIsAnimated(bytes)) {
        return _decodeWebp(bytes);
      }
      return _decodeStatic(bytes);
    case EmoteFormat.other:
      return _decodeStatic(bytes);
  }
}

/// True when a WebP has an ANMF frame chunk (i.e. it is animated). Static
/// WebP decodes cheaper through the engine codec, so [EmoteClipRegistry]
/// routes only animated WebP to the pure-Dart decoder. Exposed for tests.
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
/// → decodeImageFromPixels → ui.Image. This is the exact path used by
/// [EmoteClipRegistry.acquire].
Future<EmoteFrameData> decodeEmoteBytes(Uint8List bytes) => _decodeBytes(bytes);

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

/// Emote renderer that never relies on the engine's animated-image codec.
///
/// Bytes flow through [EmoteCacheManager] (the settings cap and overflow
/// temp-file path both apply). Only animated WebP uses the reinforced
/// pure-Dart decoder (the engine codec mishandles its compositing/transparency);
/// GIFs and static images route through the engine codec. Playback is driven
/// by a single shared [Ticker] per URL owned by the [EmoteClipRegistry], so
/// every widget showing the same emote stays in sync.
class EmoteImage extends StatefulWidget {
  const EmoteImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.placeholder,
    this.errorWidget,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;

  @override
  State<EmoteImage> createState() => _EmoteImageState();
}

/// Shimmer placeholder shown while an emote's frames are still loading.
///
/// [Shimmer] sweeps a moving gradient over an opaque child, so the child is a
/// solid [Container] matching the emote box. Colors come from the theme.
class ShimmerEmotePlaceholder extends StatelessWidget {
  const ShimmerEmotePlaceholder({super.key, this.width, this.height});

  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.surface;
    final highlight = Color.lerp(base, scheme.surfaceContainerHighest, 0.7)!;
    return Shimmer.fromColors(
      baseColor: base,
      highlightColor: highlight,
      child: Container(
        width: width,
        height: height,
        color: base,
      ),
    );
  }
}

class _EmoteImageState extends State<EmoteImage> {
  EmoteFrameData? _frames;
  bool _failed = false;
  int _frameIndex = 0;
  bool _subscribed = false;
  Object? _loadToken;

  @override
  void initState() {
    super.initState();
    // Fast path: the clip may already be decoded in the registry (e.g. a
    // just-sent emote that other tiles are already showing). Rendering it
    // synchronously avoids a one-frame placeholder flash on every new tile.
    final cached =
        EmoteClipRegistry.instance.tryAcquireCached(widget.url);
    if (cached != null) {
      _frames = cached;
      _frameIndex = EmoteClipRegistry.instance.currentFrame(widget.url);
      EmoteClipRegistry.instance.subscribe(widget.url, _onClipChanged);
      _subscribed = true;
      return;
    }
    _load();
  }

  Future<void> _load() async {
    final url = widget.url;
    final token = Object();
    _loadToken = token;
    try {
      final frames = await EmoteClipRegistry.instance.acquire(url);
      if (!mounted || _loadToken != token) return;
      // Join the shared playback clock for this URL so all widgets showing
      // the same emote render the same frame (and a new tile syncs to the
      // frame the existing ones are already on).
      EmoteClipRegistry.instance.subscribe(url, _onClipChanged);
      _subscribed = true;
      setState(() {
        _frames = frames;
        _frameIndex = EmoteClipRegistry.instance.currentFrame(url);
      });
    } on Object {
      if (!mounted || _loadToken != token) return;
      setState(() => _failed = true);
    }
  }

  void _onClipChanged() {
    if (!mounted) return;
    setState(() {
      _frameIndex = EmoteClipRegistry.instance.currentFrame(widget.url);
    });
  }

  @override
  void dispose() {
    if (_subscribed) {
      EmoteClipRegistry.instance.unsubscribe(widget.url, _onClipChanged);
    }
    EmoteClipRegistry.instance.release(widget.url);
    super.dispose();
  }

  @override
  void didUpdateWidget(EmoteImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url) {
      if (_subscribed) {
        EmoteClipRegistry.instance.unsubscribe(oldWidget.url, _onClipChanged);
      }
      EmoteClipRegistry.instance.release(oldWidget.url);
      _subscribed = false;
      _frames = null;
      _failed = false;
      _frameIndex = 0;
      // Invalidate any in-flight load for the old URL.
      _loadToken = Object();
      final cached =
          EmoteClipRegistry.instance.tryAcquireCached(widget.url);
      if (cached != null) {
        _frames = cached;
        _frameIndex = EmoteClipRegistry.instance.currentFrame(widget.url);
        EmoteClipRegistry.instance.subscribe(widget.url, _onClipChanged);
        _subscribed = true;
        return;
      }
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return widget.errorWidget ?? const Icon(Icons.broken_image, size: 20);
    }
    final frames = _frames;
    if (frames == null) {
      return widget.placeholder ??
          ShimmerEmotePlaceholder(
            width: widget.width,
            height: widget.height,
          );
    }
    final image = frames.frames[_frameIndex];
    return RawImage(
      image: image,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
    );
  }
}
