import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../color_utils.dart';
import '../models/twitch_message.dart';
import '../services/seven_tv_paint_service.dart';
import '../util/timestamp_formatter.dart';
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
  })
  buildMessageSpans;
  final List<InlineSpan> Function(TwitchMessage msg, double textScale)?
  systemBodyBuilder;
  final void Function(String login, String? userId)? onTapUser;
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

  /// Off in the mentions tab so deleted rows stay readable.
  final bool fadeDeleted;

  /// 7TV name paints for usernames when non-null and toggle is on.
  final SevenTvPaintService? paintService;

  const ChatMessageTile({
    super.key,
    required this.message,
    required this.channel,
    required this.surface,
    required this.textScale,
    required this.buildBadgeSpans,
    required this.buildMessageSpans,
    this.systemBodyBuilder,
    this.onTapUser,
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
    this.paintService,
  });

  @override
  State<ChatMessageTile> createState() => _ChatMessageTileState();
}

class _ChatMessageTileState extends State<ChatMessageTile> {
  TapGestureRecognizer? _usernameRecognizer;
  DateTime? _lastTap;

  static const _doubleTapThreshold = Duration(milliseconds: 300);

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

  @override
  void initState() {
    super.initState();
    _updateRecognizer();
  }

  @override
  void didUpdateWidget(ChatMessageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateRecognizer();
  }

  void _updateRecognizer() {
    final onTapUser = widget.onTapUser;
    final login = widget.message.login;
    final userId = widget.message.userId;
    if (onTapUser != null) {
      _usernameRecognizer ??= TapGestureRecognizer();
      _usernameRecognizer!.onTap = () => onTapUser(login, userId);
    } else {
      _usernameRecognizer?.dispose();
      _usernameRecognizer = null;
    }
  }

  @override
  void dispose() {
    _usernameRecognizer?.dispose();
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

    if (msg.isSystem) {
      children = widget.systemBodyBuilder != null
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
      semanticsLabel = msg.text;
      deleted = false;
    } else {
      final badges = widget.buildBadgeSpans(widget.channel, msg, badgeScale: s);
      final usernameText = msg.isAction
          ? '${msg.formattedUsername} '
          : '${msg.formattedUsername}: ';
      final usernameStyle = TextStyle(
        fontSize: 14 * s,
        fontWeight: FontWeight.w500,
        color: parseColor(msg.color, background: widget.surface),
        decoration: TextDecoration.none,
      );
      final InlineSpan usernameSpan;
      if (widget.paintService != null && msg.userId != null) {
        usernameSpan = WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: PaintedUsernameText(
            service: widget.paintService!,
            userId: msg.userId,
            text: usernameText,
            baseStyle: usernameStyle,
            recognizer: _usernameRecognizer,
          ),
        );
      } else if (widget.onTapUser != null) {
        usernameSpan = TextSpan(
          text: usernameText,
          style: usernameStyle,
          recognizer: _usernameRecognizer,
        );
      } else {
        usernameSpan = TextSpan(text: usernameText, style: usernameStyle);
      }

      final bodySpans = msg.isAction
          ? widget.buildMessageSpans(
              msg,
              widget.channel,
              widget.surface,
              colored: true,
              textScale: s,
            )
          : widget.buildMessageSpans(
              msg,
              widget.channel,
              widget.surface,
              textScale: s,
            );

      children = [...badges, usernameSpan, ...bodySpans];
      semanticsLabel = msg.isHighlighted
          ? 'Mention: $ts ${msg.formattedUsername}: ${msg.text}'
          : '$ts ${msg.formattedUsername}: ${msg.text}';
      deleted = msg.deleted;
    }

    final tsStyle = TextStyle(
      fontSize: 14 * s,
      color: theme.colorScheme.onSurfaceVariant,
      decoration: TextDecoration.none,
    );
    final bodyTextStyle = TextStyle(
      fontSize: 14 * s,
      color: msg.isSystem
          ? theme.colorScheme.onSurfaceVariant
          : theme.colorScheme.onSurface,
      decoration: TextDecoration.none,
    );

    Widget child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: SizedBox(
                      width: ts.isEmpty ? 0 : ts.length * 8.5 * s,
                      child: Text(
                        ts,
                        textAlign: TextAlign.left,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: tsStyle,
                      ),
                    ),
                  ),
                  ...children,
                ],
                style: bodyTextStyle,
              ),
            ),
          ),
        ],
      ),
    );

    if (deleted) {
      if (widget.fadeDeleted) {
        child = Opacity(opacity: 0.35, child: child);
      }
    } else if (msg.isBackfill) {
      // Backfill: less faded than deletion so catch-up messages stay distinct.
      child = Opacity(opacity: 0.5, child: child);
    }

    // Shared-chat fade mode: dim foreign messages.
    if (widget.sharedChatMode == 'fade' &&
        msg.sourceBroadcasterId != null &&
        !msg.isSystem) {
      child = Opacity(opacity: 0.55, child: child);
    }

    if (widget.replyIndicator != null) {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [widget.replyIndicator!, child],
      );
    }

    // Compose all tints into one color on Material (keeps InkWell ripples above).
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
    if (highlight != null) {
      rowColor = highlight.rowColor(rowColor, opacity: widget.highlightOpacity);
    }
    if (widget.checkeredMessages && widget.isAlternateBackground) {
      // Alternating row: inverseSurface at ~12% alpha (dankchat style).
      rowColor = Color.alphaBlend(
        theme.colorScheme.inverseSurface.withValues(alpha: 0.12),
        rowColor,
      );
    }

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

    if (widget.onLongPress != null || widget.onDoubleTap != null) {
      child = InkWell(
        onTap: _handleTap,
        onLongPress: widget.onLongPress,
        child: child,
      );
    }

    child = Material(color: rowColor, child: child);

    child = Semantics(
      label: semanticsLabel,
      excludeSemantics: true,
      child: child,
    );

    return child;
  }
}
