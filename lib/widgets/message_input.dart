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
  final VoidCallback? onTap;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;
  final String? hintText;
  final List<TextInputFormatter>? inputFormatters;

  // Search mode: single-line field; prefix/suffix slots take over.
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

// Reply target card floated above the composer. The framework BottomSheet
// owns the drag; the card slides out of its fixed slot, so the composer never
// resizes and the chat only moves when the reply opens or closes.
class ReplyHeader extends StatefulWidget {
  const ReplyHeader({super.key, required this.message, this.onDismiss});

  final TwitchMessage message;
  final VoidCallback? onDismiss;

  @override
  State<ReplyHeader> createState() => _ReplyHeaderState();
}

class _ReplyHeaderState extends State<ReplyHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..forward();

  // The framework flings the controller to 0 on a dismiss drag; clear the
  // reply once that settles so the collapse animation finishes first.
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (_closing && status == AnimationStatus.dismissed) {
      widget.onDismiss?.call();
    }
  }

  // A short sheet reaches 0 during the drag itself, so the status listener
  // never sees a fresh transition; dismiss now in that case.
  void _handleClosing() {
    if (_controller.status == AnimationStatus.dismissed) {
      widget.onDismiss?.call();
    } else {
      _closing = true;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // FractionalTranslation, not SizeTransition: the layout slot stays a fixed
    // height while dragging, so the chat viewport never resizes mid-gesture.
    // The clip cuts only the bottom edge, so the card slides away behind the
    // input bar while its shadow can still spill above and to the sides.
    return ClipRect(
      clipper: const _BottomClipper(),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) => FractionalTranslation(
          translation: Offset(0, 1 - _controller.value),
          child: child,
        ),
        child: BottomSheet(
          animationController: _controller,
          enableDrag: true,
          showDragHandle: false,
          onClosing: _handleClosing,
          backgroundColor: Colors.transparent,
          elevation: 0,
          builder: (ctx) => Container(
            margin: const EdgeInsets.fromLTRB(4, 4, 4, 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.colorScheme.outlineVariant),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 12,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 8),
                  child: SizedBox(
                    width: 32,
                    height: 4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade400,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: Row(
                    children: [
                      Icon(
                        Icons.reply,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text:
                                    'Replying to @${widget.message.formattedUsername}',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              TextSpan(
                                text:
                                    ': ${formatReplyPreview(widget.message.text)}',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Clips only the bottom edge, so the card can slide behind the input bar
// while its shadow still spills above and to the sides.
class _BottomClipper extends CustomClipper<Rect> {
  const _BottomClipper();

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(-1000, -1000, size.width + 1000, size.height);

  @override
  bool shouldReclip(_BottomClipper oldClipper) => false;
}
