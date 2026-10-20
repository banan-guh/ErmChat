import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';

/// Hold-and-swipe menu on a send button. Holding runs [onRecall] at once;
/// dragging up then opens a path to a hub above the button and across the
/// screen to the actions. The thumb only moves along the path, and an action
/// runs only while the thumb rests in its zone.
class SendSwipe extends StatefulWidget {
  const SendSwipe({
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

  /// Reverts [onRecall] when the hold turns into a swipe.
  final VoidCallback? onRecallUndo;

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
  static const _riseShare = 0.28;
  static const _minRise = 180.0;
  static const _hubRadius = 26.0;
  static const _actionRadius = 30.0;
  // Actions sit this far in from the screen edge across from the button.
  static const _edgeInset = 44.0;
  static const _thumbSize = 32.0;
  static const _railWidth = 6.0;
  // How far the finger may stray from the path and still drive the thumb.
  static const _pathSlack = 56.0;
  // How far one move may advance along the path. A bigger jump cuts a
  // corner, which counts as leaving the path.
  static const _maxAdvance = 80.0;
  // Rejoining after leaving may land only this far past the thumb.
  static const _rejoinSlack = 16.0;
  // The last share of the cross rail where spam runs.
  static const _zoneShare = 0.25;
  // Resting in the zone this long starts spam, so passing through never does.
  static const _charge = Duration(milliseconds: 250);
  // Dragging this far up from the hold opens the menu.
  static const _openRise = 24.0;
  // A press this long shows the swipe hint, so quick taps never flash it.
  static const _hintDelay = Duration(milliseconds: 150);

  final _portal = OverlayPortalController();
  // Pins the hint above the button even while a keyboard moves it.
  final _link = LayerLink();

  // The portal shows the hint alone until the swipe opens the menu.
  bool _menuOpen = false;
  Timer? _hintTimer;

  Offset _origin = Offset.zero;
  // The cross rail runs this way along x: -1 left, 1 right.
  double _dir = -1;
  double _rise = 0;
  double _run = 0;
  // Where the hold landed. The finger is read as an offset from here, so a
  // send target wider than the slack, or a keyboard that opens on recall and
  // moves the button, never shifts the path under it.
  Offset _anchor = Offset.zero;

  // Distance along the path (up, then across) the thumb sits at.
  double _progress = 0;
  bool _offPath = false;
  bool _charging = false;
  bool _spamming = false;
  Timer? _chargeTimer;

  Offset get _hub => _origin - Offset(0, _rise);
  Offset get _spamAt => _hub + Offset(_dir * _run, 0);
  bool get _armed => _progress >= _rise;
  double get _zoneStart => _rise + _run * (1 - _zoneShare);

  Offset _pointAt(double s) => s <= _rise
      ? _origin - Offset(0, s)
      : _hub + Offset(_dir * (s - _rise), 0);

  RenderBox get _overlayBox =>
      Overlay.of(context).context.findRenderObject() as RenderBox;

  // The finger can reach the menu two ways: swiping up straight from the
  // touch, or holding first. Holding recalls the last message at once, as it
  // always has, and the menu still waits for an upward drag.
  void _down(Offset global) {
    _offPath = false;
    _progress = 0;
    _anchor = _overlayBox.globalToLocal(global);
    _hintTimer?.cancel();
    _hintTimer = Timer(_hintDelay, _showHint);
  }

  void _hold(LongPressStartDetails d) {
    widget.onRecall?.call();
    _down(d.globalPosition);
    _showHint();
  }

  void _showHint() {
    _hintTimer?.cancel();
    if (mounted && !_portal.isShowing) setState(_portal.show);
  }

  // Lays the path out from where the button sits now.
  void _openMenu() {
    _hintTimer?.cancel();
    _menuOpen = true;
    final box = context.findRenderObject() as RenderBox;
    final overlay = _overlayBox;
    final area = overlay.size;
    _origin = overlay.globalToLocal(
      box.localToGlobal(box.size.center(Offset.zero)),
    );
    final top = MediaQuery.paddingOf(context).top + _hubRadius * 2;
    final room = _origin.dy - top;
    final want = area.height * _riseShare;
    _rise = (want < _minRise ? _minRise : want).clamp(0.0, room < 0 ? 0 : room);
    // Across the screen from the button, so reaching it takes a full swipe.
    _dir = _origin.dx > area.width / 2 ? -1 : 1;
    final end = _dir < 0 ? _edgeInset : area.width - _edgeInset;
    _run = (end - _origin.dx).abs();
    widget.onRecallUndo?.call();
    HapticFeedback.selectionClick();
    if (!_portal.isShowing) _portal.show();
  }

  /// The path distance nearest [f], or null when [f] is off the path.
  double? _project(Offset f) {
    final up = (_origin.dy - f.dy).clamp(0.0, _rise);
    final upDist = (f.dx - _origin.dx).abs();
    final across = ((f.dx - _origin.dx) * _dir).clamp(0.0, _run);
    final acrossDist = (f.dy - _hub.dy).abs();
    final onUp = upDist <= _pathSlack;
    final onAcross = acrossDist <= _pathSlack;
    if (onUp && onAcross) {
      // Near the corner both rails match; the closer one wins.
      return upDist < acrossDist ? up : _rise + across;
    }
    if (onUp) return up;
    if (onAcross) return _rise + across;
    return null;
  }

  // The thumb follows the finger along the path. Leaving the path holds the
  // thumb where it was, and the finger picks it back up anywhere at or
  // before that point, never past it. Every other state follows from where
  // the thumb sits, so backing off undoes it.
  void _move(Offset global) {
    if (!widget._hasMenu) return;
    final drag = _overlayBox.globalToLocal(global) - _anchor;
    if (!_menuOpen) {
      if (drag.dy > -_openRise) return;
      _openMenu();
    }
    final s = _project(_origin + drag);
    final reach = _offPath ? _rejoinSlack : _maxAdvance;
    final wasArmed = _armed;
    if (s != null && s <= _progress + reach) {
      _progress = s;
      _offPath = false;
    } else {
      _offPath = true;
    }
    if (_armed && !wasArmed) HapticFeedback.selectionClick();
    _updateSpam();
    setState(() {});
  }

  void _updateSpam() {
    final inZone = !_offPath && _progress >= _zoneStart;
    if (inZone) {
      if (_charging || _spamming) return;
      _charging = true;
      _chargeTimer = Timer(_charge, () {
        _charging = false;
        _spamming = true;
        HapticFeedback.mediumImpact();
        widget.onSpamStart!();
        if (mounted) setState(() {});
      });
    } else {
      _chargeTimer?.cancel();
      _charging = false;
      if (_spamming) {
        _spamming = false;
        widget.onSpamStop!();
      }
    }
  }

  void _close() {
    _hintTimer?.cancel();
    _menuOpen = false;
    _chargeTimer?.cancel();
    _charging = false;
    if (_spamming) widget.onSpamStop?.call();
    _spamming = false;
    _offPath = false;
    _progress = 0;
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
    _hintTimer?.cancel();
    _chargeTimer?.cancel();
    if (_spamming) widget.onSpamStop?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: _menu,
    child: GestureDetector(
      onLongPressStart: widget.enabled ? _hold : null,
      onLongPressMoveUpdate: widget.enabled
          ? (d) => _move(d.globalPosition)
          : null,
      onLongPressEnd: widget.enabled ? (_) => _close() : null,
      // A swipe without the hold. Down only records the anchor, so a tap or
      // a hold that wins the arena instead is unaffected.
      onVerticalDragDown: widget.enabled && widget._hasMenu
          ? (d) => _down(d.globalPosition)
          : null,
      onVerticalDragUpdate: widget.enabled && widget._hasMenu
          ? (d) => _move(d.globalPosition)
          : null,
      onVerticalDragEnd: widget.enabled ? (_) => _close() : null,
      onVerticalDragCancel: widget.enabled ? _close : null,
      child: CompositedTransformTarget(link: _link, child: widget.child),
    ),
  );

  BoxDecoration _thumbDecoration(ColorScheme scheme) => BoxDecoration(
    shape: BoxShape.circle,
    color: _offPath ? scheme.surface : scheme.primary,
    border: Border.all(
      color: _offPath ? scheme.error : scheme.onPrimary,
      width: 3,
    ),
    boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black45)],
  );

  // Before the swipe: an arrow pops up above the button, styled like the
  // thumb it turns into once the menu opens.
  Widget _hint(ColorScheme scheme) => Positioned(
    left: 0,
    top: 0,
    child: CompositedTransformFollower(
      link: _link,
      showWhenUnlinked: false,
      targetAnchor: Alignment.topCenter,
      followerAnchor: Alignment.bottomCenter,
      offset: const Offset(0, -8),
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.4, end: 1),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutBack,
          builder: (context, t, child) => Transform.scale(
            scale: t,
            child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
          ),
          child: SizedBox.square(
            dimension: _thumbSize,
            child: DecoratedBox(
              decoration: _thumbDecoration(scheme),
              child: Icon(
                Icons.keyboard_arrow_up,
                size: 20,
                color: scheme.onPrimary,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _menu(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!_menuOpen) return Stack(children: [_hint(scheme)]);
    Widget at(Offset c, double size, Widget child) => Positioned(
      left: c.dx - size / 2,
      top: c.dy - size / 2,
      width: size,
      height: size,
      child: child,
    );
    // A straight rail from a to b, as a rounded track.
    Widget track(Offset a, Offset b, Color color) => Positioned.fromRect(
      rect: Rect.fromPoints(a, b).inflate(_railWidth / 2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(_railWidth / 2),
        ),
      ),
    );

    final idle = scheme.surfaceContainerHighest;
    final fill = scheme.primary;
    final thumb = _pointAt(_progress);
    final menu = TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: Stack(
        children: [
          // Dims the chat to 0.8x so the menu reads as its own layer.
          Positioned.fill(
            child: ColoredBox(color: scheme.scrim.withValues(alpha: 0.2)),
          ),
          track(_origin, _hub, idle),
          track(_hub, _spamAt, idle),
          // The zone where spam runs.
          track(_pointAt(_zoneStart), _spamAt, fill.withValues(alpha: 0.3)),
          // Progress fills behind the thumb, like a slider.
          track(_origin, _pointAt(_progress.clamp(0, _rise)), fill),
          if (_armed) track(_hub, thumb, fill),
          at(
            _hub,
            _hubRadius * 2,
            AnimatedScale(
              scale: _armed ? 1.15 : 1,
              duration: const Duration(milliseconds: 150),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _armed ? fill : idle,
                ),
                child: Icon(
                  _dir < 0 ? Icons.chevron_left : Icons.chevron_right,
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
              charging: _charging,
              charge: _charge,
              reachable: _armed && !_offPath,
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
        ],
      ),
    );
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fill(child: menu),
          // Outside the fade, so the hint arrow turns straight into it. Off
          // the path the thumb waits, hollow, for the finger to return.
          at(
            thumb,
            _thumbSize,
            DecoratedBox(decoration: _thumbDecoration(scheme)),
          ),
        ],
      ),
    );
  }
}

/// The spam bubble: a ring fills while it charges, then the bubble fills
/// and pulses on every repeated send.
class _SpamAction extends StatelessWidget {
  const _SpamAction({
    required this.active,
    required this.charging,
    required this.charge,
    required this.reachable,
    required this.sends,
  });

  final bool active;
  final bool charging;
  final Duration charge;

  /// The thumb is on the rail that leads here.
  final bool reachable;
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
