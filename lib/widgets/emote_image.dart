import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../emotes/emote.dart';
import '../services/emote_images.dart';
import '../services/emote_url_provider.dart';
import '../util/constants.dart';

export '../services/emote_decode.dart';

/// Emote renderer with placeholder + shimmer shell. Provider routes by the
/// single [emoteUsesCustomLoop] rule: engine-routable bytes through the
/// stock provider (shared with chat, one decode per URL), animated WebP and
/// frozen stills through the custom completer. Null [emote] keeps legacy
/// custom behavior (tests, raw URLs).
class EmoteImage extends StatefulWidget {
  const EmoteImage({
    super.key,
    required this.url,
    required this.emoteImages,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.placeholder,
    this.errorWidget,
    this.alternateUrls,
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

  /// Routing metadata for [emoteUsesCustomLoop]. Null forces custom.
  final Emote? emote;

  /// Image byte owner.
  final EmoteImages emoteImages;

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

  @override
  void initState() {
    super.initState();
    _probePlaceholder();
  }

  /// Whether this cell rides the custom completer. Engine-routed cells
  /// share chat's decoded pixels and skip seeding (no-ops there).
  bool get _custom {
    final emote = widget.emote;
    if (emote == null) return true;
    return emoteUsesCustomLoop(
      emote,
      animateGifs: EmoteUrlProvider.gifsEnabled,
    );
  }

  /// Byte owner for this cell.
  EmoteImages get _images => widget.emoteImages;

  /// Provider honoring the routing rule. Alt scales share the main's route.
  ImageProvider _providerFor(String url) {
    if (_custom) return EmoteUrlProvider(url, images: _images);
    return CachedNetworkImageProvider(url, cacheManager: _images.cache);
  }

  /// Probes alternate scales for a cached placeholder while [url] loads. Picks first hit. Disk results memoized via [EmoteProbeMemo].
  Future<void> _probePlaceholder() async {
    final alternates = widget.alternateUrls;
    final images = _images;
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
        cached = await images.probe.probe(
          altUrl,
          (url) async => await images.cache.getFileFromCache(url) != null,
        );
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

  void _setPlaceholder(String altUrl, Object token) {
    // Defer setState: probe resolves async (can land mid-build).
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
