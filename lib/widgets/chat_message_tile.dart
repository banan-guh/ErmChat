import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../color_utils.dart';
import '../models/twitch_message.dart';
import 'seven_tv_paint_service.dart';
import '../util/constants.dart';
import '../util/log.dart';
import '../util/timestamp_formatter.dart';
import 'emote_text.dart';
import 'image_embed_preview.dart';
import 'painted_username_text.dart';

class ChatMessageTile extends StatefulWidget {
  final TwitchMessage message;
  final String channel;
  final Color surface;
  final double textScale;
  final List<WidgetSpan> Function(
    String channel,
    TwitchMessage msg, {
    double badgeScale,
  })
  buildBadgeSpans;
  final List<InlineSpan> Function(
    TwitchMessage msg,
    String channel,
    Color surface, {
    bool colored,
    double textScale,
    void Function(String url)? onImageTap,
  })
  buildMessageSpans;

  /// Whether [buildMessageSpans] returned the shared cached list, so the tile
  /// does not own (or dispose) it.
  final bool Function(TwitchMessage msg, List<InlineSpan> spans) bodyIsCached;
  final List<InlineSpan> Function(TwitchMessage msg, double textScale)?
  systemBodyBuilder;
  final void Function(String login, String? userId)? onTapUser;

  /// Double tap on the name zone. Null keeps single taps instant.
  final VoidCallback? onDoubleTapUser;
  final VoidCallback? onLongPress;
  final VoidCallback? onDoubleTap;
  final Widget? replyIndicator;
  final bool showTimestamp;
  final String timestampFormat;
  final bool checkeredMessages;

  /// Highlight opacity from settings slider (0-1). 1.0 = fully opaque.
  final double highlightOpacity;
  final bool lineSeparator;
  final bool isAlternateBackground;
  final String sharedChatMode;

  /// Prefixes each row with its source channel (mentions inbox).
  final bool showChannel;

  /// Off in the mentions tab so deleted rows stay readable.
  final bool fadeDeleted;

  /// 7TV name paints for usernames when non-null and toggle is on.
  final SevenTvPaintService? paintService;

  /// Image embeds (off by default). Icon taps toggle previews below the text.
  final bool showImages;

  /// Preview max height at textScale 1.0. Loads only when expanded.
  final double imageHeight;

  /// Whitelist entries for image-link detection. Same input the span path
  /// uses, so icons and the preview column agree on fractured links.
  final List<String>? linkWhitelist;

  const ChatMessageTile({
    super.key,
    required this.message,
    required this.channel,
    required this.surface,
    required this.textScale,
    required this.buildBadgeSpans,
    required this.buildMessageSpans,
    required this.bodyIsCached,
    this.systemBodyBuilder,
    this.onTapUser,
    this.onDoubleTapUser,
    this.onLongPress,
    this.onDoubleTap,
    this.replyIndicator,
    this.showTimestamp = true,
    this.timestampFormat = kDefaultTimestampFormat,
    this.checkeredMessages = false,
    this.highlightOpacity = 0.6,
    this.lineSeparator = false,
    this.isAlternateBackground = false,
    this.fadeDeleted = true,
    this.sharedChatMode = 'spotlight',
    this.showChannel = false,
    this.paintService,
    this.showImages = kImageEmbedEnabledDefault,
    this.imageHeight = kImageEmbedHeightDefault,
    this.linkWhitelist,
  });

  @override
  State<ChatMessageTile> createState() => _ChatMessageTileState();
}

class _ChatMessageTileState extends State<ChatMessageTile> {
  DateTime? _lastTap;

  // The name zone is hit-tested on the row, not a span recognizer, so it can
  // reach past the glyphs: everything left of the name (timestamp, badges),
  // the name, and a margin around it.
  final _paragraphKey = GlobalKey();
  // Plain-text offset where the name (and its separator) ends; null for
  // system rows, which have no name.
  int? _nameEnd;
  // Holds a name tap for the double-tap window when double tap is wired.
  Timer? _nameTapTimer;

  static const _nameSlopX = 12.0;
  static const _nameSlopY = 6.0;

  /// Fresh link/email span lists built for this tile only. Cached span lists
  /// are shared across tiles and hold no recognizers, so only tracked lists
  /// are disposed here (on replace and on tile dispose).
  List<InlineSpan>? _ownedBodySpans;

  void _disposeSpans(List<InlineSpan>? spans) {
    if (spans == null) return;
    for (final span in spans) {
      if (span is TextSpan) {
        span.recognizer?.dispose();
        if (span.children != null) _disposeSpans(span.children!);
      }
    }
  }

  void _trackBodySpans(List<InlineSpan> spans, bool shared) {
    if (identical(spans, _ownedBodySpans)) return;
    _disposeSpans(_ownedBodySpans);
    _ownedBodySpans = shared ? null : spans;
  }

  /// Expanded image preview URLs. Tile-local: cached tiles keep their own
  /// state, fresh tiles start collapsed. Never persisted.
  final _expandedEmbeds = <String>{};

  static const _doubleTapThreshold = Duration(milliseconds: 300);

  bool _hitsName(Offset globalPosition) {
    final end = _nameEnd;
    if (end == null || end == 0) return false;
    final paragraph = _paragraphKey.currentContext?.findRenderObject();
    if (paragraph is! RenderParagraph || !paragraph.hasSize) return false;
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: end),
    );
    if (boxes.isEmpty) return false;
    var zone = boxes.first.toRect();
    for (final box in boxes.skip(1)) {
      zone = zone.expandToInclude(box.toRect());
    }
    zone = Rect.fromLTRB(
      double.negativeInfinity,
      zone.top - _nameSlopY,
      zone.right + _nameSlopX,
      zone.bottom + _nameSlopY,
    );
    return zone.contains(paragraph.globalToLocal(globalPosition));
  }

  void _handleTapUp(TapUpDetails details) {
    final onTapUser = widget.onTapUser;
    if (onTapUser != null && _hitsName(details.globalPosition)) {
      final msg = widget.message;
      void open() => onTapUser(msg.login, msg.userId);
      final onDoubleTapUser = widget.onDoubleTapUser;
      if (onDoubleTapUser == null) {
        open();
      } else if (_nameTapTimer?.isActive ?? false) {
        _nameTapTimer!.cancel();
        onDoubleTapUser();
      } else {
        _nameTapTimer = Timer(_doubleTapThreshold, open);
      }
      return;
    }
    _handleTap();
  }

  void _handleTap() {
    if (widget.onDoubleTap == null) return;
    final now = DateTime.now();
    if (_lastTap != null && now.difference(_lastTap!) < _doubleTapThreshold) {
      _lastTap = null;
      widget.onDoubleTap!();
    } else {
      _lastTap = now;
    }
  }

  /// The sender's paint notifier while paints are on. The tile rebuilds when
  /// a paint lands late, so unpainted names stay plain TextSpans.
  ValueNotifier<SevenTvPaint?>? _paintNotifier;

  @override
  void initState() {
    super.initState();
    _updatePaintNotifier();
  }

  @override
  void didUpdateWidget(ChatMessageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updatePaintNotifier();
  }

  void _updatePaintNotifier() {
    final service = widget.paintService;
    final userId = widget.message.userId;
    final next = service == null || userId == null || widget.message.isSystem
        ? null
        : service.lookupNotifier(userId);
    if (identical(next, _paintNotifier)) return;
    _paintNotifier?.removeListener(_onPaintChanged);
    _paintNotifier = next?..addListener(_onPaintChanged);
  }

  void _onPaintChanged() {
    if (mounted) setState(() {});
  }

  /// The sender's resolved paint, or null when paints are off or it has no
  /// layers. The lookup also queues a batched fetch for unknown users.
  SevenTvPaint? _currentPaint() {
    final notifier = _paintNotifier;
    if (notifier == null) return null;
    final paint =
        notifier.value ?? widget.paintService!.lookup(widget.message.userId);
    if (paint == null || paint.layers.isEmpty) return null;
    return paint;
  }

  void _toggleEmbed(String url) {
    setState(() {
      if (!_expandedEmbeds.remove(url)) _expandedEmbeds.add(url);
    });
  }

  /// One collapsed-by-default preview. Built only when expanded, so no
  /// bytes load until the user taps the icon next to the link. Direct load
  /// on purpose: arbitrary hosts cannot go through the emote disk cap, and
  /// GIFs here animate regardless of the animate_gifs freeze.
  Widget _embedPreview(String url, double s) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 8, top: 2, bottom: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ImageEmbedPreview(
          url: url,
          maxWidth: 300 * s,
          maxHeight: widget.imageHeight * s,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _paintNotifier?.removeListener(_onPaintChanged);
    _paintNotifier = null;
    _disposeSpans(_ownedBodySpans);
    _ownedBodySpans = null;
    _nameTapTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final msg = widget.message;
    final s = widget.textScale;
    final ts = widget.showTimestamp
        ? formatTimestamp(msg.timestamp, widget.timestampFormat)
        : '';

    final List<InlineSpan> children;
    final String semanticsLabel;
    final bool deleted;
    int? nameEnd;
    // Image preview URLs for the embed column below the text.
    List<String> embedUrls = const [];

    if (msg.isSystem) {
      final base = widget.systemBodyBuilder != null
          ? widget.systemBodyBuilder!(msg, s)
          // Fallback: plain text at the same size/weight as the real path.
          : <InlineSpan>[
              TextSpan(
                text: msg.text,
                style: TextStyle(
                  fontSize: 14 * s,
                  fontStyle: FontStyle.normal,
                  decoration: TextDecoration.none,
                ),
              ),
            ];
      // PubSub redemption headers carry the reward image inline, mirroring
      // DankChat's trailing ImageSpan. Broken images collapse to a gap.
      final redemptionImage = msg.redemptionImageUrl;
      if (redemptionImage != null && redemptionImage.isNotEmpty) {
        final size = 18.0 * s;
        children = [
          ...base,
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: CachedNetworkImage(
                imageUrl: redemptionImage,
                width: size,
                height: size,
                fit: BoxFit.contain,
                fadeInDuration: Duration.zero,
                placeholder: (_, _) => SizedBox(width: size, height: size),
                errorWidget: (_, failedUrl, error) {
                  logDebug('Redemption image load failed: $failedUrl - $error');
                  return SizedBox(width: size, height: size);
                },
              ),
            ),
          ),
        ];
      } else {
        children = base;
      }
      semanticsLabel = msg.text;
      deleted = false;
    } else {
      final badges = widget.buildBadgeSpans(widget.channel, msg, badgeScale: s);
      final InlineSpan? channelSpan = widget.showChannel
          ? TextSpan(
              text: '#${widget.channel} ',
              style: TextStyle(
                fontSize: 14 * s,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSurfaceVariant,
                decoration: TextDecoration.none,
              ),
            )
          : null;
      final usernameText = msg.isAction
          ? '${msg.formattedUsername} '
          : '${msg.formattedUsername}: ';
      final nameStyle = TextStyle(
        fontSize: 14 * s,
        fontWeight: FontWeight.w500,
        decoration: TextDecoration.none,
      );
      final usernameColor = parseColor(msg.color, background: widget.surface);
      final paint = _currentPaint();
      final solid = paint?.solidColor;
      final shadows = paint == null
          ? null
          : [
              for (final shadow in paint.shadows)
                Shadow(
                  color: shadow.color,
                  offset: Offset(shadow.offsetX, shadow.offsetY),
                  blurRadius: shadow.blur * 3,
                ),
            ];
      final InlineSpan usernameSpan;
      if (paint == null || solid != null) {
        // Unpainted and solid names stay in the row's own paragraph.
        usernameSpan = TextSpan(
          text: usernameText,
          style: nameStyle.copyWith(
            color: solid ?? usernameColor,
            shadows: shadows == null || shadows.isEmpty ? null : shadows,
          ),
        );
      } else {
        usernameSpan = WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: PaintedUsernameText(
            service: widget.paintService!,
            paint: paint,
            text: usernameText,
            baseStyle: nameStyle,
            fallbackColor:
                paint.fallbackColor ?? usernameColor ?? const Color(0xFF808080),
            shadows: shadows!.isEmpty ? null : shadows,
          ),
        );
      }

      if (widget.showImages) {
        embedUrls = collectImageEmbedUrls(
          msg.text,
          linkWhitelist: widget.linkWhitelist,
        );
      }
      // Only rows with an image link take the tile-bound tap, which skips
      // the shared span cache; every other row stays cached.
      final bodySpans = widget.buildMessageSpans(
        msg,
        widget.channel,
        widget.surface,
        colored: msg.isAction,
        textScale: s,
        onImageTap: embedUrls.isEmpty ? null : _toggleEmbed,
      );
      _trackBodySpans(bodySpans, widget.bodyIsCached(msg, bodySpans));
      children = [?channelSpan, ...badges, usernameSpan, ...bodySpans];
      nameEnd = [
        ?channelSpan,
        ...badges,
        usernameSpan,
      ].fold<int>(0, (n, span) => n + span.toPlainText().length);
      final channelLabel = widget.showChannel ? '#${widget.channel} ' : '';
      semanticsLabel = msg.isHighlighted
          ? 'Mention: $ts $channelLabel${msg.formattedUsername}: ${msg.text}'
          : '$ts $channelLabel${msg.formattedUsername}: ${msg.text}';
      deleted = msg.deleted;
    }

    final tsStyle = TextStyle(
      fontSize: 14 * s,
      color: theme.colorScheme.onSurfaceVariant,
      decoration: TextDecoration.none,
      // Tabular digits make a padded timestamp column an exact width.
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final bodyTextStyle = TextStyle(
      fontSize: 14 * s,
      color: msg.isSystem
          ? theme.colorScheme.onSurfaceVariant
          : theme.colorScheme.onSurface,
      decoration: TextDecoration.none,
    );

    // Timestamp as one span: padded to the format's longest output plus a
    // trailing gap, so usernames start at the same pixel and the timestamp
    // never crowds them. Avoids a nested Text and its own paragraph.
    final tsSpan = ts.isEmpty
        ? null
        : TextSpan(
            text: '${ts.padLeft(timestampMaxLength(widget.timestampFormat))} ',
            style: tsStyle,
          );

    _nameEnd = nameEnd == null
        ? null
        : nameEnd + (tsSpan?.toPlainText().length ?? 0);

    Widget child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Text.rich(
        key: _paragraphKey,
        TextSpan(children: [?tsSpan, ...children], style: bodyTextStyle),
      ),
    );

    final expanded = [
      for (final url in embedUrls)
        if (_expandedEmbeds.contains(url)) url,
    ];
    if (expanded.isNotEmpty) {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [child, for (final url in expanded) _embedPreview(url, s)],
      );
    }

    // Compose all tints into one opaque row color (ripples draw above it).
    var rowColor = widget.surface;
    final tintAnchor = highlightAnchor(widget.surface);
    if (msg.systemAccent != null) {
      // Blue/purple announcement hues read a touch louder than their measured
      // brightness even after equalization, so damp them slightly more.
      final accentHue = HSLColor.fromColor(msg.systemAccent!).hue;
      final strength = (accentHue >= 210 && accentHue <= 300)
          ? highlightStrength * 0.85
          : highlightStrength;
      final tint = matchTintContrast(
        msg.systemAccent!,
        rowColor,
        tintAnchor,
        strength: strength,
      );
      rowColor = Color.alphaBlend(
        tint.withValues(alpha: widget.highlightOpacity),
        rowColor,
      );
    }
    if (msg.isFirstMessage) {
      final tint = matchTintContrast(Colors.green, rowColor, tintAnchor);
      rowColor = Color.alphaBlend(
        tint.withValues(alpha: widget.highlightOpacity),
        rowColor,
      );
    }
    final highlight = msg.highlight;
    if (highlight != null && highlight.tinted) {
      rowColor = highlightRowColor(
        highlight,
        rowColor,
        opacity: widget.highlightOpacity,
      );
    }
    if (widget.checkeredMessages && widget.isAlternateBackground) {
      // Alternating row: inverseSurface at ~12% alpha (dankchat style).
      rowColor = Color.alphaBlend(
        theme.colorScheme.inverseSurface.withValues(alpha: 0.12),
        rowColor,
      );
    }

    var fade = 1.0;
    if (deleted) {
      if (widget.fadeDeleted) fade = 0.35;
    } else if (msg.isBackfill) {
      // Backfill: less faded than deletion so catch-up messages stay distinct.
      fade = 0.5;
    }
    // Shared-chat fade mode: dim foreign messages.
    if (widget.sharedChatMode == 'fade' &&
        msg.sourceBroadcasterId != null &&
        !msg.isSystem) {
      fade *= 0.55;
    }
    if (widget.replyIndicator != null) {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [widget.replyIndicator!, child],
      );
    }
    // Fades the reply header with its row, so the tap ripple underneath shows
    // at one strength across both.
    if (fade < 1) child = fadeOver(child, rowColor, fade);

    if (widget.lineSeparator) {
      child = Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: theme.colorScheme.outlineVariant,
              width: 1,
            ),
          ),
        ),
        child: child,
      );
    }

    if (widget.onLongPress != null ||
        widget.onDoubleTap != null ||
        widget.onTapUser != null) {
      child = InkWell(
        onTapUp: _handleTapUp,
        onTap: () {},
        onLongPress: widget.onLongPress,
        child: child,
      );
    }

    // Transparency skips the canvas Material's implicit animations; the
    // ColoredBox paints the row and ripples still draw above it.
    child = ColoredBox(
      color: rowColor,
      child: Material(type: MaterialType.transparency, child: child),
    );

    // Semantics are only built when a screen reader is active: the per-row
    // node is pure cost otherwise, and the label is still there when needed.
    if (SemanticsBinding.instance.semanticsEnabled) {
      child = Semantics(
        label: semanticsLabel,
        excludeSemantics: true,
        child: child,
      );
    }

    return child;
  }
}

/// Fades [child] toward the opaque [background] beneath it. Over an opaque
/// backdrop this matches `Opacity(opacity: opacity)` pixel for pixel, but
/// draws one rect instead of an offscreen layer per frame (text blocks the
/// engine's opacity peephole).
Widget fadeOver(Widget child, Color background, double opacity) {
  return DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: BoxDecoration(color: background.withValues(alpha: 1 - opacity)),
    child: child,
  );
}
