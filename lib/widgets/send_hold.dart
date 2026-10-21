import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../util/haptics.dart';

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
  });

  final bool enabled;
  final VoidCallback? onRecall;

  /// Reverts [onRecall] when spam starts, so it spams the draft.
  final VoidCallback? onRecallUndo;

  /// Without these the hold only recalls and no spam button shows.
  final VoidCallback? onSpamStart;
  final VoidCallback? onSpamStop;

  bool get _hasSpam => onSpamStart != null && onSpamStop != null;

  final Widget child;

  @override
  State<SendHold> createState() => _SendHoldState();
}

class _SendHoldState extends State<SendHold> {
  // Holding the spam button this long starts spam.
  static const _charge = Duration(milliseconds: 500);
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

  // The opposite corner from send, below the top bar, so a second thumb
  // finds it.
  Widget _spamButton(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final scheme = Theme.of(context).colorScheme;
    final lit = _charging || _spamming;
    return Positioned(
      left: padding.left + _inset,
      top: padding.top + kToolbarHeight + _inset,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _spamDown,
        onPointerUp: _spamUp,
        onPointerCancel: _spamUp,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FloatingActionButton.small(
              heroTag: null,
              onPressed: () {},
              backgroundColor: lit ? scheme.primary : null,
              foregroundColor: lit ? scheme.onPrimary : null,
              child: const Icon(Icons.repeat),
            ),
            Text(
              context.l10n.sendMenuSpam,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
      ),
    );
  }
}
