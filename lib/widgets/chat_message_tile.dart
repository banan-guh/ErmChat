import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../color_utils.dart';
import '../models/twitch_message.dart';
import '../util/timestamp_formatter.dart';

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
  final Widget? replyIndicator;
  final bool showTimestamp;
  final String timestampFormat;

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
    this.replyIndicator,
    this.showTimestamp = true,
    this.timestampFormat = kDefaultTimestampFormat,
  });

  @override
  State<ChatMessageTile> createState() => _ChatMessageTileState();
}

class _ChatMessageTileState extends State<ChatMessageTile> {
  TapGestureRecognizer? _usernameRecognizer;

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
    final bool highlighted;

    if (msg.isSystem) {
      children = widget.systemBodyBuilder != null
          ? widget.systemBodyBuilder!(msg, s)
          : <InlineSpan>[
              TextSpan(
                text: msg.text,
                style: TextStyle(
                  fontSize: 13 * s,
                  fontStyle: FontStyle.italic,
                  decoration: TextDecoration.none,
                ),
              ),
            ];
      semanticsLabel = msg.text;
      deleted = false;
      highlighted = false;
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
      final TextSpan usernameSpan;
      if (widget.onTapUser != null) {
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
      highlighted = msg.isHighlighted;
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
      child = Opacity(opacity: 0.35, child: child);
    } else if (msg.isBackfill) {
      // Reconnect history backfill: greyed out but less faded than a
      // hard deletion so catch-up messages stay distinguishable.
      child = Opacity(opacity: 0.5, child: child);
    }

    if (msg.systemAccent != null) {
      child = ColoredBox(
        color: Color.alphaBlend(
          msg.systemAccent!.withValues(alpha: 0.4),
          theme.colorScheme.surface,
        ),
        child: child,
      );
    }

    if (msg.isFirstMessage || true) {
      child = ColoredBox(
        color: Color.alphaBlend(
          Colors.green.withValues(alpha: 0.2),
          theme.colorScheme.surface,
        ),
        child: child,
      );
    }

    if (highlighted) {
      final isDark = theme.brightness == Brightness.dark;
      child = ColoredBox(
        color: isDark ? const Color(0xFF773031) : const Color(0xFFEF9A9A),
        child: child,
      );
    }

    if (widget.replyIndicator != null) {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [widget.replyIndicator!, child],
      );
    }

    if (widget.onLongPress != null) {
      child = InkWell(onLongPress: widget.onLongPress, child: child);
    }

    child = Semantics(
      label: semanticsLabel,
      excludeSemantics: true,
      child: child,
    );

    return child;
  }
}
