import 'dart:async';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_avif/flutter_avif.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
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

/// Refcounted per-URL cache of decoded emote frames.
///
/// All [EmoteImage] instances for the same URL share one decode. The clip is
/// freed (and its [ui.Image]s disposed) when the last widget releases it, so
/// memory is bounded by what is on screen, and the disk cache (via
/// [EmoteCacheManager]) keeps the bytes warm for re-decodes.
class EmoteClipRegistry {
  /// Test hooks; fall back to the production fetcher/decoder when null.
  @visibleForTesting
  static EmoteBytesFetcher? debugFetchOverride;

  @visibleForTesting
  static EmoteFrameDecoder? debugDecodeOverride;

  static final EmoteClipRegistry instance = EmoteClipRegistry();

  final Map<String, _EmoteClip> _clips = {};

  /// Registers a reference to [url] and returns the decoded frames. Throws
  /// (with the original error) when the fetch or decode fails; the next
  /// [acquire] of the same URL after a failure retries.
  Future<EmoteFrameData> acquire(String url) {
    final clip = _clips.putIfAbsent(url, () => _EmoteClip());
    clip.refs++;
    final pending = clip.decode;
    if (pending != null) return pending;
    final future = _load(url, clip);
    clip.decode = future;
    return future;
  }

  /// Drops the reference; when the last one goes away the frames are disposed
  /// and the clip is removed so the next acquire decodes fresh.
  void release(String url) {
    final clip = _clips[url];
    if (clip == null) return;
    clip.refs--;
    if (clip.refs > 0) return;
    _clips.remove(url);
    final frames = clip.frames;
    if (frames != null) {
      _disposeFrames(frames);
    } else {
      clip.decode?.then(_disposeFrames, onError: (_) {});
    }
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
  }

  Future<EmoteFrameData> _load(String url, _EmoteClip clip) async {
    try {
      final fetch = debugFetchOverride ?? _fetchBytes;
      final decode = debugDecodeOverride ?? _decodeBytes;
      final bytes = await fetch(url);
      final frames = await decode(bytes);
      clip.frames = frames;
      return frames;
    } on Object catch (e) {
      clip.error = e;
      rethrow;
    }
  }

  static void _disposeFrames(EmoteFrameData frames) {
    for (final frame in frames.frames) {
      frame.dispose();
    }
  }
}

class _EmoteClip {
  int refs = 0;
  Future<EmoteFrameData>? decode;
  EmoteFrameData? frames;
  Object? error;
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

enum EmoteFormat { gif, avif, other }

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
      bytes[4] == 0x66 && // f
      bytes[5] == 0x74 && // t
      bytes[6] == 0x79 && // y
      bytes[7] == 0x70 && // p
      bytes[8] == 0x61 && // a
      bytes[9] == 0x76 && // v
      bytes[10] == 0x69 && // i
      (bytes[11] == 0x66 || bytes[11] == 0x73)) {
    // brand 'avif' or 'avis'
    return EmoteFormat.avif;
  }
  return EmoteFormat.other;
}

Future<EmoteFrameData> _decodeBytes(Uint8List bytes) {
  switch (sniffEmoteFormat(bytes)) {
    case EmoteFormat.gif:
      return _decodeGif(bytes);
    case EmoteFormat.avif:
      return _decodeAvif(bytes);
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
        decoded.rgba[i],
        decoded.widths[i],
        decoded.heights[i],
      ),
    );
  }
  return EmoteFrameData(frames: out, durations: decoded.durations);
}

Future<EmoteFrameData> _decodeAvif(Uint8List bytes) async {
  final infos = await decodeAvif(bytes);
  if (infos.isEmpty) {
    throw StateError('AVIF decode failed');
  }
  return EmoteFrameData(
    frames: [for (final f in infos) f.image],
    durations: [
      for (final f in infos)
        f.duration > Duration.zero
            ? f.duration
            : const Duration(milliseconds: 80),
    ],
  );
}

Future<EmoteFrameData> _decodeStatic(Uint8List bytes) async {
  // Single-frame path for PNG/static WebP (and anything else). Animated WebP
  // is not served by any provider after the 7TV AVIF switch, so the first
  // frame is enough if one ever slips through.
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    return EmoteFrameData(frames: [frame.image], durations: [Duration.zero]);
  } finally {
    codec.dispose();
  }
}

Future<ui.Image> _imageFromRgba(Uint8List rgba, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
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
/// temp-file path both apply). GIFs are decoded in pure Dart (correct
/// transparency and disposal, per-frame delays from the file) and AVIF via
/// libavif; playback is driven by a per-widget [Ticker] at the file's real
/// frame durations. Static images go through the engine codec, which is only
/// buggy for multi-frame transparency.
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
      final frames = await EmoteClipRegistry.instance.acquire(url);
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
