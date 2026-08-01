import 'package:flutter/material.dart';
import '../models/twitch_message.dart';

class MessageInput extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final VoidCallback? onSendLongPress;
  final VoidCallback? onEmoteToggle;
  final TwitchMessage? replyToMsg;
  final VoidCallback? onCancelReply;
  final VoidCallback? onTap;
  final bool enabled;
  final String? hintText;

  const MessageInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    this.onTap,
    this.onSendLongPress,
    this.onEmoteToggle,
    this.replyToMsg,
    this.onCancelReply,
    this.enabled = true,
    this.hintText,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveHint = hintText ?? 'Type a message...';
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (replyToMsg != null && enabled)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(8),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.reply, size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text:
                                'Replying to ${replyToMsg!.formattedUsername}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          TextSpan(
                            text:
                                ': ${replyToMsg!.text.length > 60 ? '${replyToMsg!.text.substring(0, 60)}…' : replyToMsg!.text}',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, size: 16),
                    tooltip: 'Cancel reply',
                    onPressed: onCancelReply,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          TextField(
            key: const Key('message_input'),
            controller: controller,
            focusNode: focusNode,
            onTap: onTap,
            enabled: enabled,
            minLines: 1,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: effectiveHint,
              border: const OutlineInputBorder(),
              prefixIcon: SizedBox(
                width: 48,
                height: 48,
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: onEmoteToggle,
                    child: const Icon(Icons.emoji_emotions_outlined),
                  ),
                ),
              ),
              suffixIcon: SizedBox(
                width: 48,
                height: 48,
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: enabled ? onSend : null,
                    onLongPress: enabled ? onSendLongPress : null,
                    child: Icon(
                      Icons.send,
                      color: enabled
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.38),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
