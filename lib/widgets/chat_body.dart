import 'package:flutter/material.dart';

import '../composer/composer_bar.dart';

/// Builds the chat content above the composer for the available box.
typedef ChatBodyBuilder =
    Widget Function(
      BuildContext context, {
      required bool hideChromeForKeyboard,
      required double maxWidth,
      required double maxHeight,
      required double keyboardH,
    });

/// Builds the emote picker overlay for the computed sheet box height.
typedef EmotePickerBuilder =
    Widget Function(BuildContext context, {required double sheetBoxHeight});

/// Below this box height the keyboard leaves too little room for the chrome,
/// so the app bar and channel tabs collapse instantly (like DankChat) and the
/// chat keeps enough room instead of overflowing. Tuned so portrait phones
/// and roomy landscape tablets keep the bar.
const double kKeyboardChromeCollapseBelowHeight = 300.0;

/// Collapse the top chrome when the keyboard eats so much vertical space
/// that the chat would overflow. Pure so the rule stays unit-testable and
/// deletable in one place when the keyboard layout changes again.
bool collapseChromeForKeyboard({
  required double keyboardH,
  required double maxHeight,
}) => keyboardH > 0 && maxHeight < kKeyboardChromeCollapseBelowHeight;

/// Layout assembly for the chat screen: body stack plus composer.
///
/// Owns the single keyboard-inset subscription for the chat layout and the
/// full-height capture used to size the emote picker. All content comes in
/// as builders/widgets so this file holds geometry only, no chat logic.
class ChatBody extends StatefulWidget {
  const ChatBody({
    super.key,
    required this.bodyBuilder,
    required this.threadPanel,
    required this.mentionsPanel,
    required this.modViewPanel,
    required this.emotePickerBuilder,
    required this.autocomplete,
    required this.emoteMaxFraction,
    this.composer,
  });

  final ChatBodyBuilder bodyBuilder;
  final Widget threadPanel;
  final Widget mentionsPanel;
  final Widget modViewPanel;
  final EmotePickerBuilder emotePickerBuilder;
  final Widget autocomplete;
  final double emoteMaxFraction;
  final Widget? composer;

  @override
  State<ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<ChatBody> {
  double? _fullBoxHeight;

  @override
  Widget build(BuildContext context) {
    // Single inset subscription for the whole layout, composer included.
    final keyboardH = MediaQuery.viewInsetsOf(context).bottom;
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    final composer = widget.composer;
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final statusBarH = MediaQuery.paddingOf(context).top;
              if (keyboardH == 0) {
                _fullBoxHeight = constraints.maxHeight;
              }
              final fullBoxH =
                  (_fullBoxHeight ?? constraints.maxHeight) - statusBarH;
              // Squash the box only when the keyboard is taller than the
              // anticipated gap, so the sheet (emoteMaxFraction of the box)
              // never extends past the top of the current Stack.
              final maxFitBoxH =
                  (constraints.maxHeight - statusBarH) /
                  widget.emoteMaxFraction;
              final sheetBoxHeight = fullBoxH < maxFitBoxH
                  ? fullBoxH
                  : maxFitBoxH;
              final hideChromeForKeyboard = collapseChromeForKeyboard(
                keyboardH: keyboardH,
                maxHeight: constraints.maxHeight,
              );
              return Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  widget.bodyBuilder(
                    context,
                    hideChromeForKeyboard: hideChromeForKeyboard,
                    maxWidth: constraints.maxWidth,
                    maxHeight: constraints.maxHeight,
                    keyboardH: keyboardH,
                  ),
                  widget.threadPanel,
                  widget.mentionsPanel,
                  widget.modViewPanel,
                  widget.emotePickerBuilder(
                    context,
                    sheetBoxHeight: sheetBoxHeight,
                  ),
                  // Autocomplete dropdown - floats above chat, anchored just
                  // above the message input, 60% width like DankChat's popup.
                  Positioned(
                    bottom: 0,
                    left: 0,
                    child: SizedBox(
                      width: (MediaQuery.sizeOf(context).width * 0.6).clamp(
                        0.0,
                        340.0,
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(context).height * 0.25,
                        ),
                        child: widget.autocomplete,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        // No AnimatedSize: the composer rides the live inset, and filtering
        // that through a fixed duration janks. The key stays on the padded
        // box so snackbar and video sizing measure the same height as before.
        composer == null
            ? const SizedBox.shrink()
            : Padding(
                key: inputBarKey,
                padding: EdgeInsets.only(bottom: keyboardH + bottomPad),
                child: composer,
              ),
      ],
    );
  }
}
