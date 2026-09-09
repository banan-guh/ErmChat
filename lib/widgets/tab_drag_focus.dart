import 'package:flutter/material.dart';

// Half-drag tab focus for TabBarView panels, mirroring TabbedLayout's
// channel pager: side effects fire when a drag crosses the 50% point
// instead of waiting for the settle animation.
class TabDragFocus {
  TabDragFocus({required this.tab, required this.onFocusChanged})
    : _lastReported = tab().index;

  final TabController Function() tab;
  final ValueChanged<int> onFocusChanged;

  /// Nearest page while a finger holds the view. Null when settled.
  final dragFocus = ValueNotifier<int?>(null);

  int _lastReported = -1;
  bool _dragging = false;
  bool _inFlight = false;
  bool _disposed = false;

  /// Warp destination of a jumpTo-driven direct index set. The warp
  /// travels with indexIsChanging false, so without this its travel
  /// updates would flyover-report intermediate pages.
  int? _warpTarget;

  /// Drag focus while dragging or flying, controller index on settle.
  int get effectiveIndex => dragFocus.value ?? tab().index;

  /// Listener entry for the TabBarView body. Drag updates always count;
  /// fling ballistics count too, since the finger is gone but the gesture
  /// is still the user's. Programmatic animates (tab taps) run under
  /// TabController.animateTo, so indexIsChanging filters their flyover.
  bool onNotification(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (metrics is! PageMetrics || metrics.page == null) return false;
    final count = tab().length;
    if (count < 1) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _dragging = true;
      _warpTarget = null;
    }
    if (notification is ScrollUpdateNotification &&
        (notification.dragDetails != null || !tab().indexIsChanging)) {
      final nearest = metrics.page!.round().clamp(0, count - 1);
      if (_dragging || _inFlight) {
        dragFocus.value = nearest;
      } else if (_warpTarget != null) {
        // Warp travel from jumpTo: swallow everything short of landing.
        if (nearest != _warpTarget) return false;
        _warpTarget = null;
        dragFocus.value = null;
      } else {
        // Jump-shaped (direct index set has no finger and no flight):
        // no travel, so report the landing through settle semantics
        // instead of the live branch.
        dragFocus.value = null;
      }
      _report(nearest);
    } else if (notification is ScrollEndNotification) {
      if (notification.dragDetails != null) {
        // Finger lift: the ballistic snap follows; its landing resolves.
        // Keep the drag focus so the effective index never reverts to
        // the stale controller value mid-flight. At exact rest with no
        // velocity there is no ballistic and no trailing ScrollEnd, so
        // don't latch _inFlight or settle syncs strand forever.
        _dragging = false;
        final page = metrics.page!;
        final velocity = notification.dragDetails!.velocity.pixelsPerSecond.dx
            .abs();
        _inFlight =
            dragFocus.value != null &&
            (page != page.roundToDouble() || velocity > 0);
      } else {
        // Ballistic rest: resolve a pending flight to the honest position.
        _dragging = false;
        _inFlight = false;
        if (dragFocus.value != null) {
          dragFocus.value = null;
          _report(metrics.page!.round().clamp(0, count - 1));
        }
      }
    }
    return false;
  }

  /// Settle path for the tab-controller listener. No-ops mid-drag and
  /// mid-flight (ticks still carry the stale index); the flight arrival
  /// adopts the controller value once it reaches the flight target.
  /// A reporting sync outside any gesture arms warp suppression: a
  /// direct index set warps next, and its travel must not flyover.
  void syncFromController() {
    if (_dragging) return;
    final count = tab().length;
    if (count < 1) return;
    final index = tab().index.clamp(0, count - 1);
    if (_inFlight) {
      // Ballistic landing: only the arrival at the flight target counts;
      // earlier ticks still carry the stale index.
      if (dragFocus.value == null || index != dragFocus.value) return;
      dragFocus.value = null;
      _inFlight = false;
      _report(index);
      return;
    }
    dragFocus.value = null;
    if (index == _lastReported) return;
    _warpTarget = index;
    _report(index);
  }

  /// Programmatic jump for show verbs: clears flight state and sets the
  /// index, whose settle sync arms warp suppression for the travel that
  /// follows. A no-op when already there.
  void jumpTo(int index) {
    if (_disposed) return;
    final count = tab().length;
    if (count < 1) return;
    _warpTarget = null;
    if (tab().index == index.clamp(0, count - 1)) return;
    _inFlight = false;
    dragFocus.value = null;
    tab().index = index.clamp(0, count - 1);
  }

  /// Panel close hook: drop stranded drag state. Never reseed from a
  /// mid-gesture controller index; the next settle then still reports.
  void reset() {
    if (_disposed) return;
    final inGesture = _dragging || _inFlight || dragFocus.value != null;
    _dragging = false;
    _inFlight = false;
    _warpTarget = null;
    dragFocus.value = null;
    if (!inGesture) {
      final count = tab().length;
      _lastReported = count > 0 ? tab().index.clamp(0, count - 1) : 0;
    }
  }

  void dispose() {
    _disposed = true;
    dragFocus.dispose();
  }

  void _report(int index) {
    if (index == _lastReported) return;
    _lastReported = index;
    onFocusChanged(index);
  }
}
