import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/twitch_message.dart';
import '../util/thread_utils.dart';

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
  final List<TextInputFormatter>? inputFormatters;

  // Search mode: hides the reply banner. Prefix/suffix slots take over.
  final bool searchMode;

  // Inside a glass pill the container draws the rim, so the field drops
  // its own outline to avoid a double border.
  final bool borderless;

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
    this.inputFormatters,
    this.searchMode = false,
    this.borderless = false,
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
      // In-flow the field sits flush under the list (top 0). In a glass
      // pill it must breathe evenly or the text reads high in the pill.
      padding: borderless
          ? const EdgeInsets.fromLTRB(8, 4, 8, 4)
          : const EdgeInsets.fromLTRB(8, 0, 8, 8),
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
                            text: ': ${formatReplyPreview(replyToMsg!.text)}',
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
            inputFormatters: inputFormatters,
            enabled: enabled,
            minLines: 1,
            maxLines: searchMode ? 1 : 6,
            decoration: InputDecoration(
              // Borderless glass mode uses a hint (always centered) instead
              // of a label (which sits high with no outline to notch into).
              labelText: borderless ? null : effectiveHint,
              hintText: borderless ? effectiveHint : null,
              border: borderless
                  ? InputBorder.none
                  : const OutlineInputBorder(),
              // Null keeps the stock Material3 outline colors. An explicit
              // OutlineInputBorder here overrides them, so toggling glass
              // off would not restore the normal border.
              enabledBorder: borderless ? InputBorder.none : null,
              focusedBorder: borderless ? InputBorder.none : null,
              contentPadding: borderless
                  ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
                  : null,
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
