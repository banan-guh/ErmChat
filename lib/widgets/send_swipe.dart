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
  static const _thumbSize = 32.0;
  static const _railWidth = 6.0;
  // How far the finger may stray from a rail before the thumb derails.
  static const _railSlack = 36.0;
  // A hold that wanders less than this still counts as a still release.
  static const _stillSlop = 24.0;

  final _portal = OverlayPortalController();

  Offset _origin = Offset.zero;
  Offset _hub = Offset.zero;
  Offset _spamAt = Offset.zero;
  Offset _thumb = Offset.zero;
  // Where the hold landed: the vertical slack counts from here, since the
  // send target can be wider than the slack.
  double _startX = 0;
  bool _moved = false;
  bool _armed = false;
  bool _spamming = false;
  // Left the path: nothing runs until the finger lifts.
  bool _derailed = false;

  RenderBox get _overlayBox =>
      Overlay.of(context).context.findRenderObject() as RenderBox;

  void _start(LongPressStartDetails d) {
    _moved = false;
    _armed = false;
    _derailed = false;
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
    _startX = overlay.globalToLocal(d.globalPosition).dx;
    HapticFeedback.selectionClick();
    setState(_portal.show);
  }

  // The thumb rides the rails: up the vertical one to the hub, then across
  // the horizontal one to the actions. Straying off a rail derails it until
  // the finger lifts, so only the drawn path reaches an action. Every other
  // state follows from where the thumb sits, so backing off undoes it.
  void _move(LongPressMoveUpdateDetails d) {
    if (d.offsetFromOrigin.distance > _stillSlop) _moved = true;
    if (!widget._hasMenu || _derailed) return;
    final finger = _overlayBox.globalToLocal(d.globalPosition);
    final lo = _spamAt.dx < _hub.dx ? _spamAt.dx : _hub.dx;
    final hi = _spamAt.dx < _hub.dx ? _hub.dx : _spamAt.dx;
    if (_armed) {
      final offRail =
          (finger.dy - _hub.dy).abs() > _railSlack ||
          finger.dx < lo - _railSlack ||
          finger.dx > hi + _railSlack;
      // Back down the vertical rail from the hub disarms; any other exit
      // derails.
      final backDown =
          (finger.dx - _startX).abs() <= _railSlack &&
          finger.dy > _hub.dy + _hubRadius;
      if (backDown) {
        _armed = false;
      } else if (offRail) {
        _derail();
        return;
      }
    } else {
      if ((finger.dx - _startX).abs() > _railSlack ||
          finger.dy < _hub.dy - _railSlack) {
        _derail();
        return;
      }
      if ((finger.dy - _hub.dy).abs() <= _hubRadius) {
        _armed = true;
        HapticFeedback.selectionClick();
      }
    }
    _thumb = _armed
        ? Offset(finger.dx.clamp(lo, hi), _hub.dy)
        : Offset(_origin.dx, finger.dy.clamp(_hub.dy, _origin.dy));
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

  void _derail() {
    if (_spamming) widget.onSpamStop?.call();
    _spamming = false;
    _armed = false;
    _derailed = true;
    _thumb = _origin;
    HapticFeedback.heavyImpact();
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
    // A rail from a to b (one axis shared), as a rounded track.
    Widget track(Offset a, Offset b, Color color) {
      final rect = Rect.fromPoints(a, b).inflate(_railWidth / 2);
      return Positioned.fromRect(
        rect: rect,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(_railWidth / 2),
          ),
        ),
      );
    }

    final idle = scheme.surfaceContainerHighest;
    final fill = _derailed ? scheme.error : scheme.primary;
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        builder: (context, t, child) => Opacity(opacity: t, child: child),
        child: Stack(
          children: [
            // Dims the chat so the menu reads as its own layer.
            Positioned.fill(
              child: ColoredBox(color: scheme.scrim.withValues(alpha: 0.6)),
            ),
            track(_origin, _hub, idle),
            track(_hub, _spamAt, idle),
            // Progress fills behind the thumb, like a slider.
            if (!_armed) track(_origin, _thumb, fill),
            if (_armed) ...[
              track(_origin, _hub, fill),
              track(_hub, _thumb, fill),
            ],
            at(
              _hub,
              _hubRadius * 2,
              AnimatedScale(
                scale: _armed ? 1.15 : 1,
                duration: const Duration(milliseconds: 150),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _armed ? scheme.primary : idle,
                  ),
                  child: Icon(
                    _spamAt.dx < _hub.dx
                        ? Icons.chevron_left
                        : Icons.chevron_right,
                    color: _armed ? scheme.onPrimary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            at(
              _spamAt,
              _actionRadius * 2,
              _SpamAction(
                active: _spamming,
                reachable: _armed,
                sends: widget.spamSends!,
              ),
            ),
            Positioned(
              left: _spamAt.dx - 60,
              top: _spamAt.dy + _actionRadius + 6,
              width: 120,
              child: Text(
                context.l10n.sendMenuSpam,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(color: scheme.onSurface),
              ),
            ),
            if (!_derailed)
              at(
                _thumb,
                _thumbSize,
                DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.primary,
                    border: Border.all(color: scheme.onPrimary, width: 3),
                    boxShadow: const [
                      BoxShadow(blurRadius: 8, color: Colors.black45),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The spam bubble: fills while held and pulses on every repeated send.
class _SpamAction extends StatelessWidget {
  const _SpamAction({
    required this.active,
    required this.reachable,
    required this.sends,
  });

  final bool active;

  /// The thumb is on the rail that leads here.
  final bool reachable;
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? scheme.primary : scheme.surfaceContainerHighest,
          border: Border.all(
            color: reachable ? scheme.primary : scheme.outlineVariant,
            width: 2,
          ),
        ),
        child: Icon(
          Icons.repeat,
          size: 24,
          color: active
              ? scheme.onPrimary
              : reachable
              ? scheme.primary
              : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
