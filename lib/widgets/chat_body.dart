import 'dart:async';

import 'package:flutter/material.dart';

import '../composer/composer_bar.dart';
import '../util/prefs.dart';

/// Builds the chat content above the composer for the available box.
typedef ChatBodyBuilder =
    Widget Function(
      BuildContext context, {
      required bool hideChromeForKeyboard,
      required double maxWidth,
      required double maxHeight,
      required double keyboardH,
      required double composerH,
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
/// Geometry rides the stock Scaffold resize, which replays the system ticks
/// directly with no second animator to cross them. The debounced lift below
/// feeds discrete decisions only (chrome collapse, video hide), so those
/// flip once per gesture instead of mid-animation. All content comes in as
/// builders/widgets so this file holds geometry only, no chat logic.
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
    required this.keyboardH,
    this.composer,
    this.notice,
    this.isInPip = false,
  });

  final ChatBodyBuilder bodyBuilder;
  final Widget threadPanel;
  final Widget mentionsPanel;
  final Widget modViewPanel;
  final EmotePickerBuilder emotePickerBuilder;
  final Widget autocomplete;
  final double emoteMaxFraction;
  final Widget? composer;

  /// System PiP mode: render the body builder output only. Composer,
  /// panels, picker, autocomplete, and notice stay out of the tree so the
  /// OS window shows just the video (the activity is what shrinks).
  final bool isInPip;

  /// Inline notice bar floating over the chat, anchored above the composer.
  /// In the body stack (not the Scaffold overlay), so it tracks keyboard
  /// and composer height changes by layout instead of a frozen margin.
  final Widget? notice;

  /// True keyboard overlap in dp, read ABOVE the Scaffold: the Scaffold
  /// consumes viewInsets for its body, so reading them here is always 0
  /// on the resize path and every keyboard-driven rule silently dies.
  final double keyboardH;

  @override
  State<ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<ChatBody> {
  double? _fullBoxHeight;

  // Settled composer height for keyboard-room math downstream. Measured
  // post-layout: reading inputBarKey.size during build throws every frame.
  double _composerH = 56.0;

  // Debounced lift for decisions only. Raw ticks are smooth on their own;
  // replaying each one into chrome/video/sheet rules makes those flip
  // mid-gesture, so rules read this once-per-gesture value instead.
  double _liftH = 0;
  double _settledKeyboardH = 0;
  double _persistedKeyboardH = 0;
  double _lastRawH = 0;
  Timer? _settleTimer;

  // Last learned open height, persisted so decisions start right even on a
  // cold start. Re-learned every session, so a stale value self-corrects.
  void _loadSettledHeight() async {
    try {
      final prefs = await Prefs.load();
      final v = prefs.keyboardSettledHeight;
      if (v > 50 && v < 1500) {
        _settledKeyboardH = v;
        _persistedKeyboardH = v;
      }
    } catch (_) {}
  }

  void _saveSettledHeight(double v) {
    if (v <= 50 || v >= 1500) return;
    if ((v - _persistedKeyboardH).abs() < 10) return;
    _persistedKeyboardH = v;
    try {
      Prefs.load().then((prefs) => prefs.setKeyboardSettledHeight(v));
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _loadSettledHeight();
    _lastRawH = widget.keyboardH;
    if (widget.keyboardH > 0) {
      _liftH = widget.keyboardH;
      _settledKeyboardH = widget.keyboardH;
    }
  }

  @override
  void didUpdateWidget(ChatBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    _handleRawKeyboardH(widget.keyboardH);
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }

  void _handleRawKeyboardH(double raw) {
    if ((raw - _lastRawH).abs() < 0.5) return;
    final wasClosed = _lastRawH <= 0.5;
    _lastRawH = raw;
    if (raw <= 0.5) {
      _settleTimer?.cancel();
      if (_liftH != 0) setState(() => _liftH = 0);
      return;
    }
    if (wasClosed) {
      // Opening: commit the learned height at once so rules decide on the
      // final geometry from the first frame instead of flapping mid-gesture.
      final target = _settledKeyboardH > 0 ? _settledKeyboardH : raw;
      if ((_liftH - target).abs() > 0.5) setState(() => _liftH = target);
    }
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      final stable = _lastRawH;
      if (stable <= 0.5) return;
      _settledKeyboardH = stable;
      _saveSettledHeight(stable);
      if ((_liftH - stable).abs() > 0.5) setState(() => _liftH = stable);
    });
  }

  void _cacheComposerH() {
    if (!mounted || widget.composer == null) return;
    final h = inputBarKey.currentContext?.size?.height;
    if (h != null && (h - _composerH).abs() > 0.5) {
      setState(() => _composerH = h);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Decisions read the debounced lift; geometry comes from the resized
    // constraints below, which already track the keyboard tick by tick.
    final keyboardH = _liftH;
    final rawH = widget.keyboardH;
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    final composer = widget.composer;
    // Cache the settled composer height after layout for keyboard-room
    // math; converges after one extra frame on height changes.
    if (composer != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _cacheComposerH());
    }
    final composerH = composer == null ? 0.0 : _composerH;
    // No manual lift: the Scaffold shrank the body, so the composer sits
    // above the keyboard at settled constraints with no second animator
    // to cross the system motion. The key stays for post-layout measuring.
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (widget.isInPip) {
                return widget.bodyBuilder(
                  context,
                  hideChromeForKeyboard: false,
                  maxWidth: constraints.maxWidth,
                  maxHeight: constraints.maxHeight,
                  keyboardH: 0,
                  composerH: 0,
                );
              }
              final statusBarH = MediaQuery.paddingOf(context).top;
              if (rawH <= 0.5) {
                _fullBoxHeight = constraints.maxHeight;
              }
              final fullBoxH =
                  (_fullBoxHeight ?? constraints.maxHeight) - statusBarH;
              // Full-box canvas for the sheet: the Positioned box may run
              // past the top of the shrunk Stack (clipped, harmless) so the
              // Draggable fractions keep measuring against the full box and
              // the sheet anchors to the bottom, above the keyboard.
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
                    composerH: composerH,
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
                  // Chat notice - floats over the chat, anchored just above
                  // the composer. Overlay, not column content, so showing it
                  // never resizes the chat.
                  if (widget.notice != null)
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: widget.notice!,
                    ),
                ],
              );
            },
          ),
        ),
        if (!widget.isInPip)
          composer == null
              ? const SizedBox.shrink()
              : Padding(
                  key: inputBarKey,
                  padding: EdgeInsets.only(bottom: bottomPad),
                  child: composer,
                ),
      ],
    );
  }
}
