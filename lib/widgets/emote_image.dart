import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

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

typedef EmoteBytesFetcher = Future<Uint8List> Function(String url);
typedef EmoteFrameDecoder = Future<EmoteFrameData> Function(Uint8List bytes);

/// Per-URL cache of decoded emote frames with an LRU byte cap (100 MB default,
/// matching Flutter's [ImageCache]). Clips are retained until the cap is
/// exceeded, then least-recently-used clips are evicted.
class EmoteClipRegistry {
  /// Test hooks; fall back to the production fetcher/decoder when null.
  @visibleForTesting
  static EmoteBytesFetcher? debugFetchOverride;

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
  /// [fetcher] overrides how bytes are fetched for this clip; memory-only
  /// render sites (the emote menu) pass one that skips [EmoteCacheManager].
  /// When null, [debugFetchOverride] (tests) then [_fetchBytes] apply.
  Future<EmoteFrameData> acquire(String url, {EmoteBytesFetcher? fetcher}) {
    final clip = _clips.putIfAbsent(url, () => _EmoteClip(url: url));
    if (clip.refs == 0) {
      clip.lastAccessed = DateTime.now();
    }
    clip.refs++;
    final pending = clip.decode;
    if (pending != null) return pending;
    final future = _load(url, clip, fetcher);
    clip.decode = future;
    return future;
  }

  /// Drops the reference count. The clip is kept in memory (not disposed)
  /// so subsequent acquires are instant. If the cache exceeds its byte cap,
  /// least-recently-used clips with zero refs are evicted.
  void release(String url) {
    final clip = _clips[url];
    if (clip == null) return;
    clip.refs--;
    clip.lastAccessed = DateTime.now();
    _evictIfNeeded();
  }

  /// Test hook; disposes and drops every cached clip.
  @visibleForTesting
  void debugClear() {
    for (final clip in _clips.values) {
      clip.refs = 0;
      final frames = clip.frames;
      if (frames != null) {
        _disposeFrames(frames);
      } else {
        clip.decode?.then(_disposeFrames, onError: (_) {});
      }
    }
    _clips.clear();
    _totalBytes = 0;
  }

  Future<EmoteFrameData> _load(
    String url,
    _EmoteClip clip,
    EmoteBytesFetcher? fetcher,
  ) async {
    try {
      final fetch = debugFetchOverride ?? fetcher ?? _fetchBytes;
      final decode = debugDecodeOverride ?? _decodeBytes;
      final bytes = await fetch(url);
      final frames = await decode(bytes);
      clip.frames = frames;
      clip.byteSize = _estimateByteSize(frames);
      clip.lastAccessed = DateTime.now();
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
    final evictable = _clips.values
        .where((c) => c.refs == 0 && c.frames != null)
        .toList()
      ..sort((a, b) => a.lastAccessed.compareTo(b.lastAccessed));

    for (final clip in evictable) {
      if (_totalBytes <= _maxBytes) break;
      _disposeFrames(clip.frames!);
      _totalBytes -= clip.byteSize;
      _clips.remove(clip.url);
    }
  }

  static int _estimateByteSize(EmoteFrameData frames) {
    // Approximate: 4 bytes per pixel (RGBA) per frame
    int total = 0;
    for (final frame in frames.frames) {
      total += frame.width * frame.height * 4;
    }
    return total;
  }

  static void _disposeFrames(EmoteFrameData frames) {
    for (final frame in frames.frames) {
      frame.dispose();
    }
  }
}

class _EmoteClip {
  _EmoteClip({required this.url}) : lastAccessed = DateTime.now();

  final String url;
  int refs = 0;
  Future<EmoteFrameData>? decode;
  EmoteFrameData? frames;
  Object? error;
  int byteSize = 0;
  DateTime lastAccessed;
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
/// straight to RAM, never writing to or evicting from [EmoteCacheManager], so
/// panel bursts can't grow or churn the disk cache.
Future<Uint8List> _fetchBytesMemoryOnly(String url) async {
  final resp = await http
      .get(Uri.parse(url), headers: const {'User-Agent': 'ermchat'})
      .timeout(const Duration(seconds: 10));
  if (resp.statusCode != 200) {
    throw StateError('emote fetch ${resp.statusCode} for $url');
  }
  return resp.bodyBytes;
}

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
      return _decodeGif(bytes);
    case EmoteFormat.webp:
      return _decodeWebp(bytes);
    case EmoteFormat.other:
      return _decodeStatic(bytes);
  }
}

Future<EmoteFrameData> _decodeGif(Uint8List bytes) async {
  final decoded = await Isolate.run(() {
    final decoder = img.GifDecoder();
    final image = decoder.decode(bytes);
    if (image == null) {
      throw StateError('GIF decode failed');
    }
    final frames = image.frames;
    final rgba = <Uint8List>[];
    final widths = <int>[];
    final heights = <int>[];
    final durations = <Duration>[];
    for (final frame in frames) {
      final converted = frame.convert(numChannels: 4);
      rgba.add(converted.toUint8List());
      widths.add(converted.width);
      heights.add(converted.height);
      final ms = frame.frameDuration;
      durations.add(
        ms > 0 ? Duration(milliseconds: ms) : const Duration(milliseconds: 80),
      );
    }
    return (rgba: rgba, widths: widths, heights: heights, durations: durations);
  });

  final out = <ui.Image>[];
  for (var i = 0; i < decoded.rgba.length; i++) {
    out.add(
      await _imageFromRgba(
        decoded.rgba[i].buffer,
        decoded.widths[i],
        decoded.heights[i],
      ),
    );
  }
  return EmoteFrameData(frames: out, durations: decoded.durations);
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
          ms > 0 ? Duration(milliseconds: ms) : const Duration(milliseconds: 80),
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
        // Normal alpha blend
        img.compositeImage(
          canvas,
          converted,
          dstX: frameInfo.x,
          dstY: frameInfo.y,
          blend: img.BlendMode.alpha,
        );
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
  _FrameMeta({
    required this.noBlend,
    required this.disposeToBackground,
  });
  final bool noBlend;
  final bool disposeToBackground;
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
    final chunkSize = bytes[pos + 4] |
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
        metas.add(_FrameMeta(noBlend: noBlend, disposeToBackground: disposeToBackground));
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

Future<ui.Image> _imageFromRgba(ByteBuffer rgba, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba.asUint8List(),
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
/// temp-file path both apply) unless [memoryOnly] is set, in which case they
/// are fetched straight over HTTP. GIFs and WebP are decoded in pure Dart
/// (correct transparency and disposal, per-frame delays from the file);
/// playback is driven by a per-widget [Ticker] at the file's real frame
/// durations. Static images go through the engine codec, which is only buggy
/// for multi-frame transparency.
class EmoteImage extends StatefulWidget {
  const EmoteImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.placeholder,
    this.errorWidget,
    this.memoryOnly = false,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;

  /// When true, bytes are fetched with [_fetchBytesMemoryOnly] (plain HTTP,
  /// no [EmoteCacheManager]) so bursty grids like the emote menu never write
  /// to or evict from the disk cache.
  final bool memoryOnly;

  @override
  State<EmoteImage> createState() => _EmoteImageState();
}

class _EmoteImageState extends State<EmoteImage>
    with SingleTickerProviderStateMixin {
  EmoteFrameData? _frames;
  bool _failed = false;
  int _frameIndex = 0;
  Ticker? _ticker;
  bool _released = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final url = widget.url;
    try {
      final fetcher = widget.memoryOnly ? _fetchBytesMemoryOnly : null;
      final frames = await EmoteClipRegistry.instance.acquire(
        url,
        fetcher: fetcher,
      );
      if (!mounted) {
        _release(url);
        return;
      }
      setState(() => _frames = frames);
      if (frames.isAnimated) {
        _ticker = createTicker(_onTick)..start();
      }
    } on Object {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  void _release(String url) {
    if (_released) return;
    _released = true;
    EmoteClipRegistry.instance.release(url);
  }

  void _onTick(Duration elapsed) {
    final frames = _frames;
    if (frames == null || !frames.isAnimated) return;
    final totalUs = frames.totalDuration.inMicroseconds;
    if (totalUs <= 0) return;
    var t = elapsed.inMicroseconds % totalUs;
    for (var i = 0; i < frames.durations.length; i++) {
      final d = frames.durations[i].inMicroseconds;
      if (t < d) {
        if (i != _frameIndex) setState(() => _frameIndex = i);
        return;
      }
      t -= d;
    }
    final last = frames.frames.length - 1;
    if (last != _frameIndex) setState(() => _frameIndex = last);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _release(widget.url);
    super.dispose();
  }

  @override
  void didUpdateWidget(EmoteImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url) {
      _release(oldWidget.url);
      _ticker?.dispose();
      _ticker = null;
      _frames = null;
      _failed = false;
      _frameIndex = 0;
      _released = false;
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final frames = _frames;
    if (_failed || frames == null) {
      return widget.errorWidget ??
          widget.placeholder ??
          SizedBox(width: widget.width, height: widget.height);
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
