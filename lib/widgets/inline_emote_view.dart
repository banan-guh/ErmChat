import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../services/emote_cache_manager.dart';
import 'emote_image_provider.dart';
import 'emote_probe_memo.dart';
import 'emote_loading_band.dart';

/// Lean chat-span emote renderer. Subscribes to [EmoteUrlProvider] completer directly; animation tick = set field + markNeedsPaint.
class InlineEmoteView extends StatefulWidget {
  const InlineEmoteView({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    this.alternateUrls,
  });

  final String url;
  final double width;
  final double height;

  /// Smaller-scale URLs for cached placeholder while [url] loads.
  final List<String>? alternateUrls;

  @override
  State<InlineEmoteView> createState() => _InlineEmoteViewState();
}

class _InlineEmoteViewState extends State<InlineEmoteView> {
  ImageStream? _mainStream;
  ImageStream? _altStream;

  // Reused listeners (one pair per state; completer deduplicates removals).
  // Emote failures are expected (bad URLs, engine quirks); swallow silently.
  late final ImageStreamListener _mainListener = ImageStreamListener(
    _onMainFrame,
    onError: (_, _) {},
  );
  late final ImageStreamListener _altListener = ImageStreamListener(
    _onAltFrame,
    onError: (_, _) {},
  );

  /// Buffered frames before render object exists. Ownership transfers on first build.
  ImageInfo? _bufferedMain;
  ImageInfo? _bufferedAlt;

  /// Invalidates in-flight alternate probes across url changes.
  Object? _probeToken;

  RenderInlineEmote? get _render {
    if (!mounted) return null;
    final ro = context.findRenderObject();
    return ro is RenderInlineEmote ? ro : null;
  }

  ImageConfiguration get _configuration => createLocalImageConfiguration(
    context,
    size: Size(widget.width, widget.height),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // First dependencies ready: start resolving (MediaQuery illegal in initState).
    if (_mainStream == null) {
      _resolveMain();
      _probeAlternates();
    }
  }

  @override
  void didUpdateWidget(InlineEmoteView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url) {
      _resetFrames();
      _resolveMain();
      _probeAlternates();
    }
  }

  @override
  void dispose() {
    _probeToken = Object();
    _mainStream?.removeListener(_mainListener);
    _altStream?.removeListener(_altListener);
    _bufferedMain?.dispose();
    _bufferedAlt?.dispose();
    super.dispose();
  }

  void _resolveMain() {
    final stream = EmoteUrlProvider(widget.url).resolve(_configuration);
    _mainStream?.removeListener(_mainListener);
    _mainStream = stream..addListener(_mainListener);
  }

  void _resetFrames() {
    _probeToken = Object();
    _mainStream?.removeListener(_mainListener);
    _mainStream = null;
    _altStream?.removeListener(_altListener);
    _altStream = null;
    _bufferedMain?.dispose();
    _bufferedMain = null;
    _bufferedAlt?.dispose();
    _bufferedAlt = null;
    _render
      ?..image = null
      ..altImage = null;
  }

  void _onMainFrame(ImageInfo info, bool synchronousCall) {
    final ro = _render;
    if (ro == null) {
      _bufferedMain?.dispose();
      _bufferedMain = info;
      return;
    }
    // The real frame replaces any placeholder scale; stop listening to it.
    if (_altStream != null) _detachAlt();
    ro.image = info;
  }

  void _onAltFrame(ImageInfo info, bool synchronousCall) {
    final ro = _render;
    if (ro == null) {
      _bufferedAlt?.dispose();
      _bufferedAlt = info;
      return;
    }
    ro.altImage = info;
  }

  void _detachAlt() {
    _altStream?.removeListener(_altListener);
    _altStream = null;
    _render?.altImage = null;
  }

  /// Probes alternate scales for cached placeholder. Disk lookups shared via [EmoteProbeMemo].
  Future<void> _probeAlternates() async {
    final alternates = widget.alternateUrls;
    if (alternates == null || alternates.isEmpty) return;
    final token = Object();
    _probeToken = token;
    for (final altUrl in alternates) {
      if (!mounted || _probeToken != token) return;
      if (altUrl == widget.url) continue;
      if (PaintingBinding.instance.imageCache.containsKey(
        EmoteUrlProvider(altUrl),
      )) {
        _attachAlt(altUrl);
        // Continue the animation clock in phase on the swap to full res.
        EmoteUrlProvider.seedPlayback(widget.url, altUrl);
        return;
      }
      final bool cached;
      try {
        cached = await EmoteProbeMemo.instance.probe(altUrl, _isAltOnDisk);
      } on Object {
        continue;
      }
      if (!mounted || _probeToken != token) return;
      if (cached) {
        _attachAlt(altUrl);
        EmoteUrlProvider.seedPlayback(widget.url, altUrl);
        return;
      }
    }
  }

  static Future<bool> _isAltOnDisk(String url) async =>
      await EmoteCacheManager().getFileFromCache(url) != null;

  void _attachAlt(String altUrl) {
    _altStream?.removeListener(_altListener);
    _altStream = EmoteUrlProvider(altUrl).resolve(_configuration)
      ..addListener(_altListener);
  }

  ImageInfo? _takeBufferedMain() {
    final info = _bufferedMain;
    _bufferedMain = null;
    return info;
  }

  ImageInfo? _takeBufferedAlt() {
    final info = _bufferedAlt;
    _bufferedAlt = null;
    return info;
  }

  @override
  Widget build(BuildContext context) {
    final highlight = Theme.of(context).colorScheme.surfaceContainerHighest;
    return _LeafEmoteBox(
      width: widget.width,
      height: widget.height,
      highlight: highlight,
      initialImage: _takeBufferedMain(),
      initialAltImage: _takeBufferedAlt(),
    );
  }
}

class _LeafEmoteBox extends LeafRenderObjectWidget {
  const _LeafEmoteBox({
    required this.width,
    required this.height,
    required this.highlight,
    this.initialImage,
    this.initialAltImage,
  });

  final double width;
  final double height;
  final Color highlight;

  /// Consumed once at creation; later rebuilds never touch frame ownership.
  final ImageInfo? initialImage;
  final ImageInfo? initialAltImage;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderInlineEmote(
    width,
    height,
    highlight,
    image: initialImage,
    altImage: initialAltImage,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderInlineEmote renderObject,
  ) {
    renderObject
      ..width = width
      ..height = height
      ..highlight = highlight;
  }
}

/// Render box for one emote frame. Owns [ImageInfo]s; listens to loading clock when frameless.
class RenderInlineEmote extends RenderBox {
  RenderInlineEmote(
    this._width,
    this._height,
    this._highlight, {
    ImageInfo? image,
    ImageInfo? altImage,
  }) {
    _image = image;
    _altImage = altImage;
  }

  double _width;
  double _height;
  Color _highlight;
  ImageInfo? _image;
  ImageInfo? _altImage;
  bool _clockSubscribed = false;

  double get width => _width;
  set width(double value) {
    if (_width == value) return;
    _width = value;
    markNeedsLayout();
  }

  double get height => _height;
  set height(double value) {
    if (_height == value) return;
    _height = value;
    markNeedsLayout();
  }

  set highlight(Color value) {
    if (_highlight == value) return;
    _highlight = value;
    markNeedsPaint();
  }

  ImageInfo? get image => _image;
  set image(ImageInfo? value) {
    if (identical(_image, value)) return;
    _image?.dispose();
    _image = value;
    markNeedsPaint();
    _updateClockSubscription();
  }

  ImageInfo? get altImage => _altImage;
  set altImage(ImageInfo? value) {
    if (identical(_altImage, value)) return;
    _altImage?.dispose();
    _altImage = value;
    markNeedsPaint();
  }

  @visibleForTesting
  bool get debugShowsBand => _image == null;

  @visibleForTesting
  ImageInfo? get debugFrame => _image;

  @visibleForTesting
  ImageInfo? get debugAltFrame => _altImage;

  @override
  void performLayout() {
    size = constraints.constrain(Size(_width, _height));
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _updateClockSubscription();
  }

  @override
  void detach() {
    _unsubscribeClock();
    super.detach();
  }

  void _updateClockSubscription() {
    final shouldListen = attached && _image == null;
    if (shouldListen == _clockSubscribed) return;
    _clockSubscribed = shouldListen;
    // Render box holds a clock slot, keeping sweep running without [LoadingBand] widgets.
    if (shouldListen) {
      EmoteLoadingClock.acquire();
      EmoteLoadingClock.phase.addListener(markNeedsPaint);
    } else {
      EmoteLoadingClock.phase.removeListener(markNeedsPaint);
      EmoteLoadingClock.release();
    }
  }

  void _unsubscribeClock() {
    if (!_clockSubscribed) return;
    _clockSubscribed = false;
    EmoteLoadingClock.phase.removeListener(markNeedsPaint);
    EmoteLoadingClock.release();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final main = _image;
    final alt = _altImage;
    final info = main ?? alt;
    if (info != null) {
      // Contain-fit: emote textures rarely match layout size; inscribe would overflow.
      final img = info.image;
      paintImage(
        canvas: canvas,
        rect: offset & size,
        image: img,
        scale: info.scale,
        alignment: Alignment.center,
        fit: BoxFit.contain,
      );
      if (main != null) return;
      // Cached smaller scale showing; faint band hints at higher-res incoming.
      canvas.save();
      canvas.translate(offset.dx, offset.dy);
      paintLoadingBand(
        canvas,
        size,
        _highlight.withValues(alpha: 0.25),
        EmoteLoadingClock.phase.value,
      );
      canvas.restore();
      return;
    }
    canvas
      ..save()
      ..translate(offset.dx, offset.dy);
    paintLoadingBand(canvas, size, _highlight, EmoteLoadingClock.phase.value);
    canvas.restore();
  }

  @override
  void dispose() {
    _unsubscribeClock();
    _image?.dispose();
    _image = null;
    _altImage?.dispose();
    _altImage = null;
    super.dispose();
  }
}
