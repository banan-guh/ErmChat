import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../color_utils.dart';
import '../models/twitch_message.dart';

class ChatMessageTile extends StatelessWidget {
  final TwitchMessage message;
  final String channel;
  final Color surface;
  final double textScale;
  final String? timestampOverride;
  final List<WidgetSpan> Function(String channel, TwitchMessage msg, {double badgeScale}) buildBadgeSpans;
  final List<InlineSpan> Function(TwitchMessage msg, String channel, Color surface, {bool colored, double textScale}) buildMessageSpans;
  final List<InlineSpan> Function(TwitchMessage msg, double textScale)? systemBodyBuilder;
  final void Function(String login, String? userId)? onTapUser;
  final VoidCallback? onLongPress;
  final Widget? replyIndicator;
  final bool showHighlight;

  const ChatMessageTile({
    super.key,
    required this.message,
    required this.channel,
    required this.surface,
    required this.textScale,
    this.timestampOverride,
    required this.buildBadgeSpans,
    required this.buildMessageSpans,
    this.systemBodyBuilder,
    this.onTapUser,
    this.onLongPress,
    this.replyIndicator,
    this.showHighlight = true,
  });

  @override
  Widget build(BuildContext context) {
    final msg = message;
    final s = textScale;
    final ts = timestampOverride ??
        '${msg.timestamp.toLocal().hour.toString().padLeft(2, '0')}:${msg.timestamp.toLocal().minute.toString().padLeft(2, '0')}';

    final List<InlineSpan> children;
    final String semanticsLabel;
    final bool deleted;
    final Color? bodyColor;
    final bool highlighted;

    if (msg.isSystem) {
      children = systemBodyBuilder != null
          ? systemBodyBuilder!(msg, s)
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
      bodyColor = msg.bodyColor;
      highlighted = false;
    } else {
      final badges = buildBadgeSpans(channel, msg, badgeScale: s);
      final usernameText = msg.isAction
          ? '${msg.formattedUsername} '
          : '${msg.formattedUsername}: ';
      final usernameStyle = TextStyle(
        fontSize: 14 * s,
        fontWeight: FontWeight.w500,
        color: parseColor(msg.color, background: surface),
        decoration: TextDecoration.none,
      );
      final TextSpan usernameSpan;
      if (onTapUser != null) {
        usernameSpan = TextSpan(
          text: usernameText,
          style: usernameStyle,
          recognizer: TapGestureRecognizer()
            ..onTap = () => onTapUser!(msg.login, msg.userId),
        );
      } else {
        usernameSpan = TextSpan(text: usernameText, style: usernameStyle);
      }

      final bodySpans = msg.isAction
          ? buildMessageSpans(msg, channel, surface,
              colored: true, textScale: s)
          : buildMessageSpans(msg, channel, surface, textScale: s);

      children = [...badges, usernameSpan, ...bodySpans];
      semanticsLabel = msg.isHighlighted
          ? 'Mention: $ts ${msg.formattedUsername}: ${msg.text}'
          : '$ts ${msg.formattedUsername}: ${msg.text}';
      deleted = msg.deleted;
      bodyColor = msg.bodyColor;
      highlighted = showHighlight && msg.isHighlighted;
    }

    final tsStyle = TextStyle(
      fontSize: 14 * s,
      color: Colors.grey,
      decoration: TextDecoration.none,
    );
    final bodyTextStyle = TextStyle(
      fontSize: 14 * s,
      color: bodyColor ?? Theme.of(context).colorScheme.onSurface,
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
                      width: 14 * s * 3,
                      child: Text(
                        ts,
                        textAlign: TextAlign.left,
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
    }

    if (highlighted) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      child = ColoredBox(
        color: isDark
            ? const Color(0xFF773031)
            : const Color(0xFFEF9A9A),
        child: child,
      );
    }

    if (replyIndicator != null) {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [replyIndicator!, child],
      );
    }

    if (onLongPress != null) {
      child = InkWell(onLongPress: onLongPress, child: child);
    }

    child = Semantics(
      label: semanticsLabel,
      excludeSemantics: true,
      child: child,
    );

    return child;
  }
}
