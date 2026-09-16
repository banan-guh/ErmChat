import 'package:flutter/material.dart';

import '../services/emote_images.dart';
import 'emote_url_provider.dart';
import '../util/constants.dart';

/// Lean chat-span emote renderer. Subscribes to [EmoteUrlProvider] completer directly; animation tick = set field + markNeedsPaint.
class InlineEmoteView extends StatefulWidget {
  const InlineEmoteView({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    required this.images,
  });

  final String url;
  final double width;
  final double height;

  /// Image byte owner.
  final EmoteImages images;

  @override
  State<InlineEmoteView> createState() => _InlineEmoteViewState();
}

class _InlineEmoteViewState extends State<InlineEmoteView> {
  ImageStream? _mainStream;

  /// Held while the span is paused. Removing the last listener disposes the
  /// shared completer, so without a handle a refocus would re-decode.
  ImageStreamCompleterHandle? _keepAlive;

  /// Whether [_mainListener] is attached. The stream keeps duplicate listeners,
  /// so add/remove must be balanced.
  bool _subscribed = false;

  /// Last TickerMode state. Chat pages in the background disable it so
  /// off-screen emotes freeze instead of animating.
  bool _tickerEnabled = true;

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
    final enabled = TickerMode.valuesOf(context).enabled;
    _tickerEnabled = enabled;
    if (enabled == _subscribed) {
      if (enabled && _mainStream == null) _resolveMain();
      return;
    }
    if (enabled) {
      _resume();
    } else {
      _pause();
    }
  }

  @override
  void didUpdateWidget(InlineEmoteView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url) {
      final resume = _tickerEnabled;
      _resetFrames();
      if (resume) _resolveMain();
    }
  }

  @override
  void dispose() {
    _release();
    _bufferedMain?.dispose();
    super.dispose();
  }

  /// Drops the listener but keeps the completer and its frames alive.
  void _pause() {
    final stream = _mainStream;
    if (stream == null) return;
    _keepAlive ??= stream.completer?.keepAlive();
    stream.removeListener(_mainListener);
    _subscribed = false;
  }

  /// Re-attaches to the paused stream, or resolves anew if it was released.
  void _resume() {
    final stream = _mainStream;
    final handle = _keepAlive;
    if (stream == null || handle == null) {
      _resolveMain();
      return;
    }
    _keepAlive = null;
    stream.addListener(_mainListener);
    _subscribed = true;
    handle.dispose();
  }

  void _resolveMain() {
    // Chat spans are the only surface that feeds the decoded-frame cache.
    _release();
    EmoteUrlProvider.markChatUse(widget.url);
    final stream = EmoteUrlProvider(
      widget.url,
      images: widget.images,
    ).resolve(_configuration);
    _mainStream = stream..addListener(_mainListener);
    _subscribed = true;
  }

  /// Drops the subscription and any keep-alive handle.
  void _release() {
    if (_subscribed) {
      _subscribed = false;
      _mainStream?.removeListener(_mainListener);
    }
    _keepAlive?.dispose();
    _keepAlive = null;
  }

  void _resetFrames() {
    _release();
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
    return _LeafEmoteBox(
      width: widget.width,
      height: widget.height,
      initialImage: _takeBufferedMain(),
    );
  }
}

class _LeafEmoteBox extends LeafRenderObjectWidget {
  const _LeafEmoteBox({
    required this.width,
    required this.height,
    this.initialImage,
  });

  final double width;
  final double height;

  /// Consumed once at creation; later rebuilds never touch frame ownership.
  final ImageInfo? initialImage;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderInlineEmote(width, height, image: initialImage);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderInlineEmote renderObject,
  ) {
    renderObject
      ..width = width
      ..height = height;
  }
}

/// Render box for one emote frame. Owns its [ImageInfo]. Paints the shared
/// static placeholder gray while frameless: no clock, no per-tick repaints.
class RenderInlineEmote extends RenderBox {
  RenderInlineEmote(this._width, this._height, {ImageInfo? image}) {
    _image = image;
  }

  double _width;
  double _height;
  ImageInfo? _image;

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
    // Static placeholder gray shared app-wide: no clock, no per-tick work.
    final paint = Paint()..color = kEmotePlaceholderGray;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        offset & size,
        const Radius.circular(kEmotePlaceholderRadius),
      ),
      paint,
    );
  }

  @override
  void dispose() {
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}
