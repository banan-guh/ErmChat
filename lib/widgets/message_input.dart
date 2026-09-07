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
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;
  final String? hintText;

  // Search mode: hides the reply banner. Prefix/suffix slots take over.
  final bool searchMode;

  // slot replacements for search mode (close + filter buttons).
  final Widget? prefixOverride;
  final Widget? suffixOverride;

  const MessageInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    this.onTap,
    this.onChanged,
    this.onSubmitted,
    this.onSendLongPress,
    this.onEmoteToggle,
    this.replyToMsg,
    this.onCancelReply,
    this.enabled = true,
    this.hintText,
    this.searchMode = false,
    this.prefixOverride,
    this.suffixOverride,
  });

  Color _inputAccent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return focusNode.hasFocus ? scheme.primary : scheme.onSurfaceVariant;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveHint = hintText ?? 'Type a message...';
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (replyToMsg != null && enabled && !searchMode)
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
                                ': ${replyToMsg!.text.trimLeft().length > 60 ? '${replyToMsg!.text.trimLeft().substring(0, 60)}...' : replyToMsg!.text.trimLeft()}',
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
            onChanged: onChanged,
            onSubmitted: onSubmitted,
            enabled: enabled,
            minLines: 1,
            maxLines: searchMode ? 1 : 6,
            decoration: InputDecoration(
              labelText: effectiveHint,
              border: const OutlineInputBorder(),
              prefixIcon:
                  prefixOverride ??
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: onEmoteToggle,
                        child: ListenableBuilder(
                          listenable: focusNode,
                          builder: (_, _) => Icon(
                            Icons.emoji_emotions_outlined,
                            color: _inputAccent(context),
                          ),
                        ),
                      ),
                    ),
                  ),
              suffixIcon:
                  suffixOverride ??
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: enabled ? onSend : null,
                        onLongPress: enabled ? onSendLongPress : null,
                        child: ListenableBuilder(
                          listenable: focusNode,
                          builder: (_, _) {
                            final theme = Theme.of(context);
                            return Icon(
                              Icons.send,
                              color: !enabled
                                  ? theme.colorScheme.onSurface.withValues(
                                      alpha: 0.38,
                                    )
                                  : _inputAccent(context),
                            );
                          },
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
