import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../util/haptics.dart';
import 'design_tokens.dart';

/// Hold menu on a send button. Holding runs [onRecall] at once and shows a
/// spam button in the top-left corner. Holding that with a second finger
/// for [_charge] spams until either finger lifts, so it never starts by
/// accident.
class SendHold extends StatefulWidget {
  const SendHold({
    super.key,
    required this.enabled,
    required this.child,
    this.onRecall,
    this.onRecallUndo,
    this.onSpamStart,
    this.onSpamStop,
    this.spamSends,
  });

  final bool enabled;
  final VoidCallback? onRecall;

  /// Reverts [onRecall] when spam starts, so it spams the draft.
  final VoidCallback? onRecallUndo;

  /// Without these the hold only recalls and no spam button shows.
  final VoidCallback? onSpamStart;
  final VoidCallback? onSpamStop;

  /// Bumped on each repeated send; the spam button pulses with it.
  final ValueListenable<int>? spamSends;

  bool get _hasSpam =>
      onSpamStart != null && onSpamStop != null && spamSends != null;

  final Widget child;

  @override
  State<SendHold> createState() => _SendHoldState();
}

class _SendHoldState extends State<SendHold> {
  // Holding the spam button this long starts spam.
  static const _charge = Duration(milliseconds: 500);
  static const _size = 64.0;
  static const _inset = 16.0;

  final _portal = OverlayPortalController();
  // The finger on the spam button; a second one there is ignored.
  int? _spamPointer;
  bool _charging = false;
  bool _spamming = false;
  Timer? _chargeTimer;

  void _hold(LongPressStartDetails _) {
    widget.onRecall?.call();
    if (!widget._hasSpam) return;
    Haptics.press();
    setState(_portal.show);
  }

  void _release() {
    _stopSpam();
    _spamPointer = null;
    if (mounted && _portal.isShowing) setState(_portal.hide);
  }

  void _spamDown(PointerDownEvent e) {
    if (_spamPointer != null) return;
    _spamPointer = e.pointer;
    setState(() => _charging = true);
    _chargeTimer = Timer(_charge, () {
      _charging = false;
      _spamming = true;
      Haptics.major();
      widget.onRecallUndo?.call();
      widget.onSpamStart!();
      if (mounted) setState(() {});
    });
  }

  void _spamUp(PointerEvent e) {
    if (e.pointer != _spamPointer) return;
    _spamPointer = null;
    _stopSpam();
    if (mounted) setState(() {});
  }

  void _stopSpam() {
    _chargeTimer?.cancel();
    _charging = false;
    if (_spamming) widget.onSpamStop?.call();
    _spamming = false;
  }

  @override
  void didUpdateWidget(SendHold old) {
    super.didUpdateWidget(old);
    // A disabled button never sees the release, so the hold ends here.
    if (!widget.enabled && _portal.isShowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _release());
    }
  }

  @override
  void dispose() {
    _chargeTimer?.cancel();
    if (_spamming) widget.onSpamStop?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: _spamButton,
    child: GestureDetector(
      onLongPressStart: widget.enabled ? _hold : null,
      onLongPressEnd: widget.enabled ? (_) => _release() : null,
      onLongPressCancel: widget.enabled ? _release : null,
      child: widget.child,
    ),
  );

  // The opposite corner from send, so a second thumb finds it.
  Widget _spamButton(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return Positioned(
      left: padding.left + _inset,
      top: padding.top + _inset,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.6, end: 1),
        duration: Motion.fast,
        curve: Motion.enter,
        builder: (context, t, child) => Transform.scale(
          scale: t,
          child: Opacity(opacity: (t - 0.6) / 0.4, child: child),
        ),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _spamDown,
          onPointerUp: _spamUp,
          onPointerCancel: _spamUp,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: _size,
                child: _SpamAction(
                  active: _spamming,
                  charging: _charging,
                  charge: _charge,
                  sends: widget.spamSends!,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                context.l10n.sendMenuSpam,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The spam button: a ring fills while it charges, then the button fills
/// and pulses on every repeated send.
class _SpamAction extends StatelessWidget {
  const _SpamAction({
    required this.active,
    required this.charging,
    required this.charge,
    required this.sends,
  });

  final bool active;
  final bool charging;
  final Duration charge;
  final ValueListenable<int> sends;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bubble = ValueListenableBuilder<int>(
      valueListenable: sends,
      builder: (context, count, child) => TweenAnimationBuilder<double>(
        // A new key per send restarts the pulse.
        key: ValueKey(active ? count : -1),
        tween: Tween(begin: active ? 1.2 : 1, end: 1),
        duration: Motion.normal,
        builder: (context, scale, child) =>
            Transform.scale(scale: scale, child: child),
        child: child,
      ),
      child: AnimatedContainer(
        duration: Motion.fast,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? scheme.primary : scheme.surfaceContainerHighest,
          border: Border.all(color: scheme.primary, width: 2),
          boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black45)],
        ),
        child: Icon(
          Icons.repeat,
          size: 28,
          color: active ? scheme.onPrimary : scheme.primary,
        ),
      ),
    );
    if (!charging) return bubble;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        bubble,
        Positioned.fill(
          left: -5,
          top: -5,
          right: -5,
          bottom: -5,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: charge,
            builder: (context, t, _) => CircularProgressIndicator(
              value: t,
              strokeWidth: 3,
              color: scheme.primary,
            ),
          ),
        ),
      ],
    );
  }
}
