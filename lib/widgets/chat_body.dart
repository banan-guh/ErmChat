import 'dart:async';

import 'package:flutter/material.dart';

import '../util/prefs.dart';
import 'emote_url_provider.dart';

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
    this.liquidGlass = false,
    this.onKeyboardDismissed,
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

  /// Glass spike: floats the composer as a pill above the chat instead of
  /// docking it in flow. Rows slide underneath the blur.
  final bool liquidGlass;

  /// Fired once when the keyboard transitions open to closed, so the host
  /// can drop input focus instead of leaving the field focused silently.
  final VoidCallback? onKeyboardDismissed;

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

class _ChatBodyState extends State<ChatBody> with WidgetsBindingObserver {
  double? _fullBoxHeight;

  // DIAG STRIP: frozen chat subtree. Built once, reused across ticks.
  Widget? _frozenList;
  String? _frozenKey;

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
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    // Tick feed with zero rebuilds: platform insets read directly, no
    // MediaQuery subscription, so motion schedules no Dart builds at all.
    // Decisions apply once on stillness. Scaffold layout positions the
    // input synchronously, same as apps that never subscribe.
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final view = views.first;
    final raw = view.viewInsets.bottom / view.devicePixelRatio;
    // DIAG: tick log for rate analysis. Revert after.
    debugPrint('INSETTICK inset=${raw.toStringAsFixed(1)}');
    _handleRawKeyboardH(raw);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settleTimer?.cancel();
    EmoteUrlProvider.motionSerialize = false;
    super.dispose();
  }

  void _handleRawKeyboardH(double raw) {
    if ((raw - _lastRawH).abs() < 0.5) return;
    _lastRawH = raw;
    // Motion starts: serialize emote flips to one per vsync plus hold
    // stream decodes. Static flags only, no build.
    EmoteUrlProvider.motionSerialize = true;
    // No setState during motion. Decisions apply once on stillness below.
    _settleTimer?.cancel();
    _settleTimer = Timer(
      const Duration(milliseconds: 120),
      _onKeyboardSettled,
    );
  }

  void _onKeyboardSettled() {
    if (!mounted) return;
    EmoteUrlProvider.motionSerialize = false;
    EmoteUrlProvider.resumeMotionHeld();
    final stable = _lastRawH;
    if (stable <= 0.5) {
      if (_liftH != 0) setState(() => _liftH = 0);
      // Unfocus only once the close settles: stillness, not a fixed delay,
      // so it adapts to animation length. Firing the hide mid-animation
      // races the IME state machine and the next open pays with an
      // overshoot; a reopen first cancels this silently.
      widget.onKeyboardDismissed?.call();
      return;
    }
    _settledKeyboardH = stable;
    _saveSettledHeight(stable);
    if ((_liftH - stable).abs() > 0.5) setState(() => _liftH = stable);
  }

  // DIAG STRIP: no composer measuring.

  @override
  Widget build(BuildContext context) {
    final composer = widget.composer;
    // DIAG STRIP: fixed composer height, no measuring, body frozen.
    const composerH = 56.0;
    final frozenKey = '${widget.isInPip}:${composer != null}';
    if (_frozenKey != frozenKey) {
      _frozenKey = frozenKey;
      _frozenList = null;
    }
    _frozenList ??= Expanded(
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
          final fullBoxH = constraints.maxHeight - statusBarH;
          final maxFitBoxH =
              (constraints.maxHeight - statusBarH) / widget.emoteMaxFraction;
          final sheetBoxHeight = fullBoxH < maxFitBoxH ? fullBoxH : maxFitBoxH;
          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              widget.bodyBuilder(
                context,
                hideChromeForKeyboard: false,
                maxWidth: constraints.maxWidth,
                maxHeight: constraints.maxHeight,
                keyboardH: 0,
                composerH: composerH,
              ),
              widget.threadPanel,
              widget.mentionsPanel,
              widget.modViewPanel,
              widget.emotePickerBuilder(
                context,
                sheetBoxHeight: sheetBoxHeight,
              ),
            ],
          );
        },
      ),
    );
    return Column(
      children: [
        _frozenList!,
        if (!widget.isInPip && composer != null)
          // DIAG STRIP: in-flow input, positioned by layout like testapp.
          Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.paddingOf(context).bottom,
            ),
            child: composer,
          ),
      ],
    );
  }
}
