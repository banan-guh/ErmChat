import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../emotes/emote.dart';
import '../emotes/emote_picker.dart';
import '../services/emote_images.dart';
import '../util/constants.dart';
import 'emote_image.dart';
import 'emote_url_provider.dart';
import 'inline_emote_view.dart';

/// Renders [emote] at the best scale available for [surface] and re-resolves
/// on tier changes, so cached message spans never bake the chosen URL.
class EmoteScaleResolver extends StatefulWidget {
  const EmoteScaleResolver({
    super.key,
    required this.emote,
    required this.surface,
    required this.images,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.textStyle,
    this.errorWidget,
    this.lean = false,
    this.animateGifs = true,
  });

  final Emote emote;
  final EmoteSurface surface;
  final EmoteImages images;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// Style for the plain-text fallback when nothing is cached at nothing tier.
  final TextStyle? textStyle;
  final Widget? errorWidget;

  /// Chat uses the lean renderer; grid/card use [EmoteImage]'s shell.
  final bool lean;
  final bool animateGifs;

  @override
  State<EmoteScaleResolver> createState() => _EmoteScaleResolverState();
}

class _EmoteScaleResolverState extends State<EmoteScaleResolver> {
  String? _url;
  String? _placeholder;
  bool _resolved = false;
  Object _token = Object();

  @override
  void initState() {
    super.initState();
    widget.images.scaleRevision.addListener(_onRevision);
    _resolve();
  }

  @override
  void didUpdateWidget(EmoteScaleResolver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.images != widget.images) {
      oldWidget.images.scaleRevision.removeListener(_onRevision);
      widget.images.scaleRevision.addListener(_onRevision);
    }
    if (!identical(oldWidget.emote, widget.emote) ||
        oldWidget.surface != widget.surface ||
        oldWidget.images != widget.images) {
      _resolve();
    }
  }

  @override
  void dispose() {
    widget.images.scaleRevision.removeListener(_onRevision);
    super.dispose();
  }

  void _onRevision() => _resolve();

  Future<void> _resolve() async {
    final token = Object();
    _token = token;
    final result = await widget.images.resolve(widget.emote, widget.surface);
    if (!mounted || !identical(_token, token)) return;
    setState(() {
      _url = result?.url;
      _placeholder = result?.placeholder;
      _resolved = true;
    });
  }

  Widget _placeholderBox() => Container(
    width: widget.width,
    height: widget.height,
    decoration: BoxDecoration(
      color: kEmotePlaceholderGray,
      borderRadius: BorderRadius.circular(kEmotePlaceholderRadius),
    ),
  );

  Widget _placeholderImage() {
    final url = _placeholder;
    if (url == null) return _placeholderBox();
    return Image(
      key: ValueKey(url),
      image: CachedNetworkImageProvider(url, cacheManager: widget.images.cache),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => _placeholderBox(),
    );
  }

  Widget _leanImage(String url) {
    if (emoteUsesCustomLoop(widget.emote, animateGifs: widget.animateGifs)) {
      return InlineEmoteView(
        url: url,
        width: widget.width ?? 0,
        height: widget.height ?? 0,
        images: widget.images,
      );
    }
    return Image(
      key: ValueKey(url),
      image: CachedNetworkImageProvider(url, cacheManager: widget.images.cache),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      loadingBuilder: (_, child, progress) =>
          progress == null ? child : _placeholderImage(),
      errorBuilder: (_, _, _) =>
          widget.errorWidget ??
          SizedBox(width: widget.width, height: widget.height),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_resolved) return _placeholderBox();
    final url = _url;
    if (url == null) {
      return Text(widget.emote.code, style: widget.textStyle);
    }
    if (widget.lean) return _leanImage(url);
    return EmoteImage(
      url: url,
      emoteImages: widget.images,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alternateUrls: [?_placeholder],
      emote: widget.emote,
      errorWidget: widget.errorWidget,
    );
  }
}
