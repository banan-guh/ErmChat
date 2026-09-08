import 'package:flutter/material.dart';

import 'emote_image_provider.dart';
import 'emote_loading_band.dart';

/// Lean chat-span emote renderer. Subscribes to [EmoteUrlProvider] completer directly; animation tick = set field + markNeedsPaint.
class InlineEmoteView extends StatefulWidget {
  const InlineEmoteView({
    super.key,
    required this.url,
    required this.width,
    required this.height,
  });

  final String url;
  final double width;
  final double height;

  @override
  State<InlineEmoteView> createState() => _InlineEmoteViewState();
}

class _InlineEmoteViewState extends State<InlineEmoteView> {
  ImageStream? _mainStream;

  // Emote failures are expected (bad URLs, engine quirks); swallow silently.
  late final ImageStreamListener _mainListener = ImageStreamListener(
    _onMainFrame,
    onError: (_, _) {},
  );

  /// Buffered frame before render object exists. Ownership transfers on first build.
  ImageInfo? _bufferedMain;

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
    }
  }

  @override
  void didUpdateWidget(InlineEmoteView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url) {
      _resetFrames();
      _resolveMain();
    }
  }

  @override
  void dispose() {
    _mainStream?.removeListener(_mainListener);
    _bufferedMain?.dispose();
    super.dispose();
  }

  void _resolveMain() {
    final stream = EmoteUrlProvider(widget.url).resolve(_configuration);
    _mainStream?.removeListener(_mainListener);
    _mainStream = stream..addListener(_mainListener);
  }

  void _resetFrames() {
    _mainStream?.removeListener(_mainListener);
    _mainStream = null;
    _bufferedMain?.dispose();
    _bufferedMain = null;
    _render?.image = null;
  }

  void _onMainFrame(ImageInfo info, bool synchronousCall) {
    final ro = _render;
    if (ro == null) {
      _bufferedMain?.dispose();
      _bufferedMain = info;
      return;
    }
    ro.image = info;
  }

  ImageInfo? _takeBufferedMain() {
    final info = _bufferedMain;
    _bufferedMain = null;
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
    );
  }
}

class _LeafEmoteBox extends LeafRenderObjectWidget {
  const _LeafEmoteBox({
    required this.width,
    required this.height,
    required this.highlight,
    this.initialImage,
  });

  final double width;
  final double height;
  final Color highlight;

  /// Consumed once at creation; later rebuilds never touch frame ownership.
  final ImageInfo? initialImage;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderInlineEmote(width, height, highlight, image: initialImage);

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

/// Render box for one emote frame. Owns its [ImageInfo]. Paints a static
/// loading band while frameless: no clock, no per-tick repaints.
class RenderInlineEmote extends RenderBox {
  RenderInlineEmote(
    this._width,
    this._height,
    this._highlight, {
    ImageInfo? image,
  }) {
    _image = image;
  }

  double _width;
  double _height;
  Color _highlight;
  ImageInfo? _image;

  /// Image paints since last reset. Test telemetry only.
  static int debugPaintCount = 0;

  /// Resets paint telemetry. Exposed for tests.
  @visibleForTesting
  static void debugResetPaintCounter() {
    debugPaintCount = 0;
  }

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
  }

  @visibleForTesting
  bool get debugShowsBand => _image == null;

  @visibleForTesting
  ImageInfo? get debugFrame => _image;

  @override
  void performLayout() {
    size = constraints.constrain(Size(_width, _height));
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final info = _image;
    if (info != null) {
      debugPaintCount++;
      // Contain-fit: emote textures rarely match layout size; inscribe would overflow.
      paintImage(
        canvas: canvas,
        rect: offset & size,
        image: info.image,
        scale: info.scale,
        alignment: Alignment.center,
        fit: BoxFit.contain,
      );
      return;
    }
    // Static band at fixed phase: reads as loading with no ticker.
    canvas
      ..save()
      ..translate(offset.dx, offset.dy);
    paintLoadingBand(canvas, size, _highlight, 0.0);
    canvas.restore();
  }

  @override
  void dispose() {
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}
