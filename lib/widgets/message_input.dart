import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/twitch_message.dart';
import '../util/constants.dart';
import '../util/layout_density.dart';
import '../util/thread_utils.dart';
import '../l10n/l10n.dart';
import 'media_upload_controller.dart';

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

  // Images a keyboard inserts (clipboard, stickers, GIFs).
  final ValueChanged<KeyboardInsertedContent>? onContentInserted;

  // Search mode: single-line field; prefix/suffix slots take over.
  final bool searchMode;

  // Inside a glass pill the container draws the rim, so the field drops
  // its own outline to avoid a double border.
  final bool borderless;

  // slot replacements for search mode (close + filter buttons).
  final Widget? prefixOverride;
  final Widget? suffixOverride;

  // The emote button lives in the island's button row instead, so the field
  // drops its own.
  final bool emoteInRow;

  // Send lives in the island's row or side column instead, so the field
  // drops its own.
  final bool sendOutside;

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
    this.onContentInserted,
    this.searchMode = false,
    this.borderless = false,
    this.prefixOverride,
    this.suffixOverride,
    this.emoteInRow = false,
    this.sendOutside = false,
  });

  Color _inputAccent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return focusNode.hasFocus ? scheme.primary : scheme.onSurfaceVariant;
  }

  /// Narrowest bar that still shows the emote button.
  static const double minWidthForEmoteMenu = 240;

  @override
  Widget build(BuildContext context) {
    final effectiveHint = hintText ?? context.l10n.typeMessageHint;
    // An outline notches its label; the borderless chat field floats one
    // like a filled field. Search and block terms keep a plain hint.
    final floatLabel = !borderless || !searchMode;
    // Compact trims the field height and padding. The emote and send
    // buttons keep the full 48pt circle: their slot is only as tall as the
    // field, and the circle spills into the padding around it.
    final compact = resolveLayoutOverride(context, (o) => o.tightComposer);
    const iconBox = 48.0;
    final slotH = compact ? 40.0 : iconBox;
    final iconConstraints = BoxConstraints(minWidth: iconBox, minHeight: slotH);
    final gap = compact ? 2.0 : 4.0;
    // A docked landscape bar beside a wide stream can be too narrow for the
    // emote menu to fit a single row, so the button goes instead.
    return LayoutBuilder(
      builder: (context, constraints) {
        final emoteFits = constraints.maxWidth >= minWidthForEmoteMenu;
        return Padding(
          // In-flow the field sits flush under the list (top 0). In a glass
          // pill it must breathe evenly or the text reads high in the pill.
          padding: borderless
              ? EdgeInsets.fromLTRB(8, gap, 8, gap)
              : EdgeInsets.fromLTRB(8, 0, 8, gap * 2),
          child: Stack(
            children: [
              TextField(
                key: const Key('message_input'),
                controller: controller,
                focusNode: focusNode,
                onTap: onTap,
                onChanged: onChanged,
                // Return sends instead of inserting a newline; the field still
                // wraps up to maxLines. The no-op keeps the keyboard up.
                keyboardType: TextInputType.text,
                textInputAction: searchMode
                    ? TextInputAction.search
                    : TextInputAction.send,
                onEditingComplete: () {},
                onSubmitted: onSubmitted ?? (enabled ? (_) => onSend() : null),
                inputFormatters: inputFormatters,
                contentInsertionConfiguration: onContentInserted == null
                    ? null
                    : ContentInsertionConfiguration(
                        allowedMimeTypes:
                            MediaUploadController.insertableMimeTypes,
                        onContentInserted: onContentInserted!,
                      ),
                enabled: enabled,
                minLines: 1,
                maxLines: searchMode ? 1 : 6,
                decoration: InputDecoration(
                  // Theme density would shift the text off the icon boxes'
                  // centerline. Compact drops the 48pt field minimum via isDense
                  // instead, so padding and the 40pt icons set the height.
                  visualDensity: VisualDensity.standard,
                  isDense: compact,
                  prefixIconConstraints: iconConstraints,
                  suffixIconConstraints: iconConstraints,
                  // The chat field's label floats into the island's corner as
                  // you type. Typed text then sits under it, below the in-field
                  // icons' centerline, as in a Material filled field.
                  labelText: floatLabel ? effectiveHint : null,
                  hintText: floatLabel ? null : effectiveHint,
                  hintMaxLines: 1,
                  border: borderless
                      ? InputBorder.none
                      : const OutlineInputBorder(),
                  // Null keeps the stock Material3 outline colors. An explicit
                  // OutlineInputBorder here overrides them, so toggling glass
                  // off would not restore the normal border.
                  enabledBorder: borderless ? InputBorder.none : null,
                  focusedBorder: borderless ? InputBorder.none : null,
                  // A floated label needs room above the text, so that field
                  // trims its vertical padding to make it.
                  contentPadding: borderless
                      ? EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: floatLabel
                              ? (compact ? 4 : 8)
                              : (compact ? 8 : 12),
                        )
                      : null,
                  prefixIcon:
                      prefixOverride ??
                      (!emoteFits || emoteInRow
                          ? null
                          : _IconSlot(
                              height: slotH,
                              child: Material(
                                type: MaterialType.transparency,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(
                                    iconBox / 2,
                                  ),
                                  onTap: onEmoteToggle,
                                  child: ListenableBuilder(
                                    listenable: focusNode,
                                    // Explicit size: a dense field shrinks its icons
                                    // to 18pt, and compact is dense.
                                    builder: (_, _) => Tooltip(
                                      message: context.l10n.pickerEmotes,
                                      child: Icon(
                                        Icons.emoji_emotions_outlined,
                                        size: 24,
                                        color: _inputAccent(context),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            )),
                  suffixIcon:
                      suffixOverride ??
                      (sendOutside
                          ? null
                          : _IconSlot(
                              height: slotH,
                              child: Material(
                                type: MaterialType.transparency,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(
                                    iconBox / 2,
                                  ),
                                  onTap: enabled ? onSend : null,
                                  onLongPress: enabled ? onSendLongPress : null,
                                  child: ListenableBuilder(
                                    listenable: focusNode,
                                    builder: (_, _) {
                                      final theme = Theme.of(context);
                                      return Icon(
                                        Icons.send,
                                        size: 24,
                                        color: !enabled
                                            ? theme.colorScheme.onSurface
                                                  .withValues(alpha: 0.38)
                                            : _inputAccent(context),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            )),
                ),
              ),
              // The floated label owns the top-left corner; the counter
              // takes the top-right, clear of the send button.
              if (!searchMode)
                Positioned(
                  top: compact ? 2 : 6,
                  right: 16 + (sendOutside ? 0 : iconBox),
                  child: _CharsLeft(controller: controller),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// How many characters are left before Twitch's cap, once the message is
/// within a fifth of it; past the cap, how many over.
class _CharsLeft extends StatelessWidget {
  const _CharsLeft({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, value, _) {
      final left = kTwitchMessageMaxChars - value.text.runes.length;
      if (left > kTwitchMessageMaxChars ~/ 5) return const SizedBox.shrink();
      final scheme = Theme.of(context).colorScheme;
      return Text(
        left >= 0
            ? context.l10n.charsLeft(left)
            : context.l10n.charsOver(-left),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: left >= 0 ? scheme.onSurfaceVariant : scheme.error,
        ),
      );
    },
  );
}

/// A [height]-tall slot holding a 48pt button centered on it, spilling
/// out evenly when the slot is shorter.
class _IconSlot extends StatelessWidget {
  const _IconSlot({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 48,
    height: height,
    child: OverflowBox(
      minWidth: 48,
      maxWidth: 48,
      minHeight: 48,
      maxHeight: 48,
      child: child,
    ),
  );
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
              borderRadius: BorderRadius.circular(16),
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
