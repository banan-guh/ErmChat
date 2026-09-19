import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/twitch_message.dart';

// DIAG STRIP: bare text field. No focus listeners, no reply banner.
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
  final bool searchMode;
  final bool borderless;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: borderless
          ? const EdgeInsets.fromLTRB(8, 4, 8, 4)
          : const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: TextField(
        key: const Key('message_input'),
        controller: controller,
        focusNode: focusNode,
        onTap: onTap,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        inputFormatters: inputFormatters,
        enabled: enabled,
        minLines: 1,
        maxLines: 6,
        decoration: InputDecoration(
          labelText: borderless ? null : (hintText ?? 'Type a message...'),
          hintText: borderless ? (hintText ?? 'Type a message...') : null,
          border: borderless ? InputBorder.none : const OutlineInputBorder(),
          enabledBorder: borderless ? InputBorder.none : null,
          focusedBorder: borderless ? InputBorder.none : null,
          prefixIcon:
              prefixOverride ??
              Icon(
                Icons.emoji_emotions_outlined,
                color: theme.colorScheme.onSurfaceVariant,
              ),
          suffixIcon:
              suffixOverride ??
              Icon(Icons.send, color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
