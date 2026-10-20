import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';

/// Hold-and-swipe menu on a send button. Holding shows a hub circle far
/// above the button; reaching it reveals the actions beside it, and an
/// action runs only while the finger rests on it. Releasing a hold that
/// never moved runs [onRecall] instead.
class SendSwipe extends StatefulWidget {
  const SendSwipe({
    super.key,
    required this.enabled,
    required this.child,
    this.onRecall,
    this.onSpamStart,
    this.onSpamStop,
    this.spamSends,
  });

  final bool enabled;
  final VoidCallback? onRecall;

  /// Without these the hold only recalls and no menu shows.
  final VoidCallback? onSpamStart;
  final VoidCallback? onSpamStop;

  /// Bumped on each repeated send; the spam action pulses with it.
  final ValueListenable<int>? spamSends;

  bool get _hasMenu =>
      onSpamStart != null && onSpamStop != null && spamSends != null;

  final Widget child;

  @override
  State<SendSwipe> createState() => _SendSwipeState();
}

class _SendSwipeState extends State<SendSwipe> {
  // Far enough above the button that a stray drag never reaches it.
  static const _hubRise = 150.0;
  static const _hubRadius = 26.0;
  static const _actionGap = 76.0;
  static const _actionRadius = 30.0;
  // A hold that wanders less than this still counts as a still release.
  static const _stillSlop = 24.0;

  final _portal = OverlayPortalController();

  Offset _origin = Offset.zero;
  Offset _finger = Offset.zero;
  bool _moved = false;
  bool _armed = false;
  bool _spamming = false;

  Offset get _hub => _origin - const Offset(0, _hubRise);

  // Left of the hub, mirrored when the hub sits at the screen's left edge.
  Offset get _spamAt {
    final left = _hub - const Offset(_actionGap, 0);
    return left.dx < _actionRadius + 8
        ? _hub + const Offset(_actionGap, 0)
        : left;
  }

  void _start(LongPressStartDetails d) {
    final box = context.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    _origin = overlay.globalToLocal(
      box.localToGlobal(box.size.center(Offset.zero)),
    );
    _finger = overlay.globalToLocal(d.globalPosition);
    _moved = false;
    _armed = false;
    if (!widget._hasMenu) return;
    HapticFeedback.selectionClick();
    setState(_portal.show);
  }

  void _move(LongPressMoveUpdateDetails d) {
    if (d.offsetFromOrigin.distance > _stillSlop) _moved = true;
    if (!widget._hasMenu) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    _finger = overlay.globalToLocal(d.globalPosition);
    if (!_armed && (_finger - _hub).distance <= _hubRadius) {
      _armed = true;
      HapticFeedback.selectionClick();
    }
    final onSpam = _armed && (_finger - _spamAt).distance <= _actionRadius;
    if (onSpam != _spamming) {
      _spamming = onSpam;
      if (onSpam) {
        HapticFeedback.mediumImpact();
        widget.onSpamStart!();
      } else {
        widget.onSpamStop!();
      }
    }
    setState(() {});
  }

  void _end(LongPressEndDetails _) {
    if (!_moved) widget.onRecall?.call();
    _close();
  }

  void _close() {
    if (_spamming) widget.onSpamStop?.call();
    _spamming = false;
    _armed = false;
    if (mounted) setState(_portal.hide);
  }

  @override
  void didUpdateWidget(SendSwipe old) {
    super.didUpdateWidget(old);
    // A disabled button never sees the release, so the menu closes here.
    if (!widget.enabled && _portal.isShowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _close());
    }
  }

  @override
  void dispose() {
    if (_spamming) widget.onSpamStop?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: _menu,
    child: GestureDetector(
      onLongPressStart: widget.enabled ? _start : null,
      onLongPressMoveUpdate: widget.enabled ? _move : null,
      onLongPressEnd: widget.enabled ? _end : null,
      onLongPressCancel: widget.enabled ? _close : null,
      child: widget.child,
    ),
  );

  Widget _menu(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget at(Offset c, double size, Widget child) => Positioned(
      left: c.dx - size / 2,
      top: c.dy - size / 2,
      width: size,
      height: size,
      child: child,
    );
    return IgnorePointer(
      child: Stack(
        children: [
          // The path up to the hub.
          Positioned(
            left: _origin.dx - 1,
            top: _hub.dy,
            width: 2,
            height: _hubRise,
            child: ColoredBox(color: scheme.primary.withValues(alpha: 0.18)),
          ),
          at(
            _hub,
            _hubRadius * 2,
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _armed
                    ? scheme.primary.withValues(alpha: 0.25)
                    : scheme.surfaceContainerHighest.withValues(alpha: 0.9),
                border: Border.all(color: scheme.primary, width: 2),
              ),
            ),
          ),
          at(
            _spamAt,
            _actionRadius * 2,
            AnimatedScale(
              scale: _armed ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutBack,
              child: _SpamAction(active: _spamming, sends: widget.spamSends!),
            ),
          ),
          if (_armed)
            Positioned(
              left: _spamAt.dx - 60,
              top: _spamAt.dy + _actionRadius + 4,
              width: 120,
              child: Text(
                context.l10n.sendMenuSpam,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          // The finger's own marker, so the thumb never hides where it is.
          at(
            _finger,
            28,
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withValues(alpha: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The spam bubble: fills while held and pulses on every repeated send.
class _SpamAction extends StatelessWidget {
  const _SpamAction({required this.active, required this.sends});

  final bool active;
  final ValueListenable<int> sends;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<int>(
      valueListenable: sends,
      builder: (context, count, child) => TweenAnimationBuilder<double>(
        // A new key per send restarts the pulse.
        key: ValueKey(active ? count : -1),
        tween: Tween(begin: active ? 1.2 : 1, end: 1),
        duration: const Duration(milliseconds: 220),
        builder: (context, scale, child) =>
            Transform.scale(scale: scale, child: child),
        child: child,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? scheme.primary : scheme.surfaceContainerHighest,
          border: Border.all(color: scheme.primary, width: 2),
        ),
        child: Icon(
          Icons.repeat,
          size: 22,
          color: active ? scheme.onPrimary : scheme.primary,
        ),
      ),
    );
  }
}
