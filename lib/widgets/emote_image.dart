import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../models/generic_emote.dart';
import '../services/emote_cache_manager.dart';
import '../util/constants.dart';
import '../util/webp_anim.dart';
import 'emote_image_provider.dart';
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

/// Emote renderer with placeholder + shimmer shell. Provider routes by the
/// single [emoteUsesCustomLoop] rule: engine-routable bytes through the
/// stock provider (shared with chat, one decode per URL), animated WebP and
/// frozen stills through the custom completer. Null [emote] keeps legacy
/// custom behavior (tests, raw URLs).
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
    this.emote,
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
  /// No-op for stock-routed emotes (engine always plays native).
  final bool uncapped;

  /// Routing metadata for [emoteUsesCustomLoop]. Null forces custom.
  final GenericEmote? emote;

  @override
  State<EmoteImage> createState() => _EmoteImageState();
}

/// Static loading placeholder: gray box, no clock, no per-tick repaints.
/// Only consumer is [EmoteImage]'s shell (menu/sheet/panel); chat paints
/// the same gray directly. Name kept for the existing widget tests.
class LoadingBand extends StatelessWidget {
  const LoadingBand({super.key, this.width, this.height, this.opacity = 1.0});

  final double? width;
  final double? height;

  /// Fill opacity. Below 1 = subtle hint over existing content.
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final alpha = (0x33 * opacity).round().clamp(0, 255);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Color.fromARGB(alpha, 0x80, 0x80, 0x80),
        borderRadius: BorderRadius.circular(kEmotePlaceholderRadius),
      ),
    );
  }
}

/// Static loading placeholder box. Kept as a named widget for tests.
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

  /// Whether this cell rides the custom completer. Engine-routed cells
  /// share chat's decoded pixels and skip uncapped/seeding (no-ops there).
  bool get _custom {
    final emote = widget.emote;
    if (emote == null) return true;
    return emoteUsesCustomLoop(
      emote,
      animateGifs: EmoteUrlProvider.gifsEnabled,
    );
  }

  /// Provider honoring the routing rule. Alt scales share the main's route.
  ImageProvider _providerFor(String url) => _custom
      ? EmoteUrlProvider(url)
      : CachedNetworkImageProvider(url, cacheManager: EmoteCacheManager());

  /// Syncs uncapped registrations with the desired set.
  void _syncUncappedRegistrations() {
    if (!_custom) {
      for (final url in _uncappedUrls) {
        EmoteUrlProvider.removeUncapped(url);
      }
      _uncappedUrls.clear();
      return;
    }
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
      // Keys follow the routing rule so stock cells hit chat's entries.
      if (PaintingBinding.instance.imageCache.containsKey(
        _providerFor(altUrl),
      )) {
        _setPlaceholder(altUrl, token);
        // Seed playback so the swap continues in phase (custom only).
        if (_custom) EmoteUrlProvider.seedPlayback(widget.url, altUrl);
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
        if (_custom) EmoteUrlProvider.seedPlayback(widget.url, altUrl);
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
    if (widget.uncapped != oldWidget.uncapped ||
        widget.url != oldWidget.url ||
        widget.emote?.isAnimated != oldWidget.emote?.isAnimated ||
        widget.emote?.type != oldWidget.emote?.type) {
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
      image: _providerFor(widget.url),
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
              image: _providerFor(altUrl),
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
