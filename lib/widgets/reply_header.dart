import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/twitch_message.dart';
import '../util/thread_utils.dart';
import 'design_tokens.dart';

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
    duration: Motion.normal,
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
    // input bar.
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
            // The island's tone and no rim, so it reads as the same chrome.
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(Radii.medium),
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
                        borderRadius: BorderRadius.circular(Radii.small),
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
                                text: context.l10n.replyingTo(
                                  widget.message.formattedUsername,
                                ),
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
