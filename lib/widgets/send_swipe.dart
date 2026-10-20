import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';

/// Hold-and-swipe menu on a send button. Holding shows a rail up to a hub
/// circle far above the button and a second rail across the screen to the
/// actions. An action runs only while the thumb rests on it. Releasing a
/// hold that never moved runs [onRecall] instead.
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
  // The hub sits this share of the screen above the button, so a stray drag
  // never reaches it.
  static const _riseShare = 0.4;
  static const _minRise = 220.0;
  static const _hubRadius = 26.0;
  static const _actionRadius = 30.0;
  // Actions sit this far in from the screen edge across from the button.
  static const _edgeInset = 44.0;
  static const _thumbSize = 28.0;
  // A hold that wanders less than this still counts as a still release.
  static const _stillSlop = 24.0;

  final _portal = OverlayPortalController();

  Offset _origin = Offset.zero;
  Offset _hub = Offset.zero;
  Offset _spamAt = Offset.zero;
  Offset _thumb = Offset.zero;
  bool _moved = false;
  bool _armed = false;
  bool _spamming = false;

  RenderBox get _overlayBox =>
      Overlay.of(context).context.findRenderObject() as RenderBox;

  void _start(LongPressStartDetails d) {
    _moved = false;
    _armed = false;
    if (!widget._hasMenu) return;
    final box = context.findRenderObject() as RenderBox;
    final overlay = _overlayBox;
    final area = overlay.size;
    _origin = overlay.globalToLocal(
      box.localToGlobal(box.size.center(Offset.zero)),
    );
    final rise = (area.height * _riseShare).clamp(_minRise, double.infinity);
    final top = MediaQuery.paddingOf(context).top + _hubRadius * 2;
    _hub = Offset(_origin.dx, (_origin.dy - rise).clamp(top, _origin.dy));
    // Across the screen from the button, so reaching it takes a full swipe.
    _spamAt = Offset(
      _origin.dx > area.width / 2 ? _edgeInset : area.width - _edgeInset,
      _hub.dy,
    );
    _thumb = _origin;
    HapticFeedback.selectionClick();
    setState(_portal.show);
  }

  // The thumb rides the rails: up the vertical one to the hub, then across
  // the horizontal one to the actions. Every state follows from where it
  // sits, so backing off undoes it.
  void _move(LongPressMoveUpdateDetails d) {
    if (d.offsetFromOrigin.distance > _stillSlop) _moved = true;
    if (!widget._hasMenu) return;
    final finger = _overlayBox.globalToLocal(d.globalPosition);
    final atHubColumn = (_thumb.dx - _hub.dx).abs() < _hubRadius;
    if (!_armed && finger.dy <= _hub.dy + _hubRadius) {
      _armed = true;
      HapticFeedback.selectionClick();
    } else if (_armed && atHubColumn && finger.dy > _hub.dy + _hubRadius * 2) {
      _armed = false;
    }
    if (_armed) {
      final lo = _spamAt.dx < _hub.dx ? _spamAt.dx : _hub.dx;
      final hi = _spamAt.dx < _hub.dx ? _hub.dx : _spamAt.dx;
      _thumb = Offset(finger.dx.clamp(lo, hi), _hub.dy);
    } else {
      _thumb = Offset(_origin.dx, finger.dy.clamp(_hub.dy, _origin.dy));
    }
    final onSpam = _armed && (_thumb - _spamAt).distance <= _actionRadius;
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
    Color rail(bool lit) => scheme.primary.withValues(alpha: lit ? 0.5 : 0.18);
    final left = _spamAt.dx < _hub.dx ? _spamAt.dx : _hub.dx;
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            left: _origin.dx - 1,
            top: _hub.dy,
            width: 2,
            height: _origin.dy - _hub.dy,
            child: ColoredBox(color: rail(!_armed)),
          ),
          Positioned(
            left: left,
            top: _hub.dy - 1,
            width: (_spamAt.dx - _hub.dx).abs(),
            height: 2,
            child: ColoredBox(color: rail(_armed)),
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
          // Shown from the first touch, dim until the hub is reached.
          at(
            _spamAt,
            _actionRadius * 2,
            AnimatedOpacity(
              opacity: _armed ? 1 : 0.45,
              duration: const Duration(milliseconds: 150),
              child: _SpamAction(active: _spamming, sends: widget.spamSends!),
            ),
          ),
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
          at(
            _thumb,
            _thumbSize,
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withValues(alpha: 0.6),
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
