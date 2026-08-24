import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

// TEMP: M3 Expressive fastSpatial stiffness (800), no-bouncy.
class _SnapPhysics extends PageScrollPhysics {
  const _SnapPhysics({super.parent});

  static final SpringDescription _spring = SpringDescription.withDampingRatio(
    mass: 1.0,
    stiffness: 800.0,
    ratio: 1.0,
  );

  @override
  _SnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _SnapPhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring => _spring;
}

class _AxisAwareFlingVelocityTracker extends VelocityTracker {
  _AxisAwareFlingVelocityTracker(super.kind)
    : _ios = IOSScrollViewFlingVelocityTracker(kind),
      super.withKind();

  final IOSScrollViewFlingVelocityTracker _ios;
  Offset? _lastPosition;
  double _totalDx = 0;
  double _totalDy = 0;

  @override
  void addPosition(Duration time, Offset position) {
    super.addPosition(time, position);
    _ios.addPosition(time, position);
    final last = _lastPosition;
    if (last != null) {
      final delta = position - last;
      _totalDx += delta.dx.abs();
      _totalDy += delta.dy.abs();
    }
    _lastPosition = position;
  }

  @override
  VelocityEstimate? getVelocityEstimate() {
    if (_totalDy >= _totalDx) {
      return super.getVelocityEstimate();
    }
    return _ios.getVelocityEstimate();
  }
}

class _SwipeScrollBehavior extends ScrollBehavior {
  const _SwipeScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return StretchingOverscrollIndicator(
      axisDirection: details.direction,
      clipBehavior: details.decorationClipBehavior ?? Clip.hardEdge,
      child: child,
    );
  }

  @override
  GestureVelocityTrackerBuilder velocityTrackerBuilder(BuildContext context) {
    return (PointerEvent event) => _AxisAwareFlingVelocityTracker(event.kind);
  }
}

class TabbedLayout extends StatefulWidget {
  final List<String> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelectedIndexChanged;
  final ValueChanged<int>? onFocusChanged;
  final IndexedWidgetBuilder pageBuilder;
  final IndexedWidgetBuilder? tabBuilder;
  final AlignmentGeometry tabAlignment;
  final bool focusOnHalfDrag;
  final Color? tabBarColor;

  /// Snappier page-settle spring (M3 Expressive fastSpatial, no-bouncy).
  /// When false, stock PageScrollPhysics is used.
  final bool fastSnap;

  static const double minEdgeExclusion = 20.0;

  const TabbedLayout({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelectedIndexChanged,
    required this.pageBuilder,
    this.onFocusChanged,
    this.tabBuilder,
    this.tabAlignment = Alignment.centerLeft,
    this.focusOnHalfDrag = false,
    this.tabBarColor,
    this.fastSnap = true,
  });

  @override
  State<TabbedLayout> createState() => TabbedLayoutState();
}

class TabbedLayoutState extends State<TabbedLayout>
    with TickerProviderStateMixin {
  TabController? _tabController;
  int _tabLength = 0;
  // The last index TabbedLayout reported upward (via onSelectedIndexChanged /
  // onFocusChanged) or was initialized/created with. Used to distinguish a
  // selection change that originated from a user gesture (already reflected by
  // the controller/page) from one that originated outside TabbedLayout (e.g.
  // programmatic navigation), which is the only case that should reposition the
  // controller. This keeps the view pager as the source of truth for the
  // visible channel so that unrelated rebuilds (a message send, a status
  // update, etc.) can never yank the page back.
  int? _lastReportedIndex;

  // True while a user finger is dragging the pager (drag-details-carrying
  // scroll notifications), as opposed to a programmatic page animation.
  bool _pointerDragging = false;
  // True when the current controller flight was grabbed by a pointer drag.
  // Such a flight ends with a notification whose index is the TAPPED target
  // even though the page never got there; committing it would select a
  // channel the user cancelled.
  bool _dragDuringFlight = false;
  // A prop-driven selection change that arrived mid-drag; applied when the
  // finger lifts instead of fighting the held page.
  int? _deferredProgrammaticIndex;
  // The pager's real visual position, captured from PageMetrics on every
  // scroll notification. TabController.index leads the page on taps and
  // animation.value always lands on the target, so neither can be trusted at
  // gesture boundaries; this is the source of truth.
  double? _lastKnownPage;

  /// Nearest page index to the pager's actual visual position, falling back
  /// to the controller animation when nothing has scrolled yet.
  int _visiblePageIndex() {
    final page = _lastKnownPage;
    if (page != null && !page.isNaN) {
      return page.round().clamp(0, _tabLength - 1);
    }
    final v = _tabController?.animation?.value ?? 0.0;
    return v.isNaN ? 0 : v.round().clamp(0, _tabLength - 1);
  }

  @override
  void initState() {
    super.initState();
    _initTabController();
  }

  void _initTabController() {
    final len = widget.tabs.length;
    _tabLength = len;
    if (len == 0) return;
    final idx = widget.selectedIndex.clamp(0, len - 1);
    _lastReportedIndex = idx;
    _tabController = TabController(length: len, vsync: this, initialIndex: idx);
    _tabController!.addListener(_onTabChanged);
    if (widget.focusOnHalfDrag) {
      _tabController!.animation!.addListener(_onAnimationTick);
    }
  }

  void _onTabChanged() {
    final ctrl = _tabController!;
    if (ctrl.indexIsChanging) {
      // Rising edge: a fresh flight is armed, so an earlier grab no longer
      // applies to it.
      _dragDuringFlight = false;
      return;
    }
    if (_dragDuringFlight) {
      // This notification is a grabbed flight ending (cancelled or completed
      // late); its index is where the TAP was headed, not where the page is.
      // Commit from the page's real position instead: focus follows what is
      // actually on screen, and the unified app-side commit makes that
      // indistinguishable from a settle commit.
      _dragDuringFlight = false;
      final nearest = _visiblePageIndex();
      if (nearest != _lastReportedIndex) {
        _lastReportedIndex = nearest;
        widget.onFocusChanged?.call(nearest);
      }
      return;
    }
    _lastReportedIndex = ctrl.index;
    if (_tabController!.index != widget.selectedIndex) {
      widget.onSelectedIndexChanged(_tabController!.index);
    }
  }

  void _onAnimationTick() {
    final ctrl = _tabController!;
    if (ctrl.indexIsChanging) return;
    final v = ctrl.animation!.value;
    if (v.isNaN) return;
    final nearest = v.round().clamp(0, _tabLength - 1);
    if (nearest != _lastReportedIndex) {
      _lastReportedIndex = nearest;
      widget.onFocusChanged?.call(nearest);
    }
  }

  @override
  void didUpdateWidget(TabbedLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    final len = widget.tabs.length;
    if (len != _tabLength) {
      _tabController?.removeListener(_onTabChanged);
      if (oldWidget.focusOnHalfDrag &&
          _tabController != null &&
          _tabController!.animation != null) {
        _tabController!.animation!.removeListener(_onAnimationTick);
      }
      _tabController?.dispose();
      _tabController = null;
      _initTabController();
    } else if (len > 0) {
      // The view pager is the source of truth for the visible channel. A rebuild
      // must never reposition the controller, otherwise an unrelated rebuild
      // (a message send, a status update, a click) landing mid-gesture can yank
      // the page back. Only drive the controller when the selection change
      // originated outside a gesture, i.e. widget.selectedIndex differs from the
      // last index this widget itself reported or was created with.
      final idx = widget.selectedIndex.clamp(0, len - 1);
      if (idx != _lastReportedIndex) {
        if (_pointerDragging) {
          // A finger holds the pager; animating now would fight it. Apply on
          // lift instead (see _onPointerDragEnd).
          _deferredProgrammaticIndex = idx;
        } else {
          _tabController!.animateTo(idx);
          _lastReportedIndex = idx;
        }
      }
    }
  }

  /// Called when the user lifts a pager drag. Applies any selection change
  /// that arrived while the finger was down.
  void _onPointerDragEnd() {
    _pointerDragging = false;
    final pending = _deferredProgrammaticIndex;
    if (pending == null || _tabController == null) return;
    _deferredProgrammaticIndex = null;
    if (pending != _lastReportedIndex && pending >= 0 && pending < _tabLength) {
      _lastReportedIndex = pending;
      _tabController!.animateTo(pending);
    }
  }

  @override
  void dispose() {
    _tabController?.removeListener(_onTabChanged);
    if (widget.focusOnHalfDrag &&
        _tabController != null &&
        _tabController!.animation != null) {
      _tabController!.animation!.removeListener(_onAnimationTick);
    }
    _tabController?.dispose();
    super.dispose();
  }

  TabAlignment _resolveTabAlignment() {
    if (widget.tabAlignment == Alignment.center) {
      return TabAlignment.center;
    }
    return TabAlignment.start;
  }

  @override
  Widget build(BuildContext context) {
    final tabs = widget.tabs;
    if (tabs.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);

    final edgeInset = MediaQuery.of(context).systemGestureInsets;
    final leftExclude = edgeInset.left > 0
        ? edgeInset.left
        : TabbedLayout.minEdgeExclusion;
    final rightExclude = edgeInset.right > 0
        ? edgeInset.right
        : TabbedLayout.minEdgeExclusion;

    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: widget.tabBarColor ?? theme.colorScheme.surfaceContainer,
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: SizedBox(
            height: 40,
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: _resolveTabAlignment(),
              labelPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 0,
              ),
              indicator: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: theme.colorScheme.primary,
                    width: 2,
                  ),
                ),
              ),
              indicatorSize: TabBarIndicatorSize.label,
              tabs: List.generate(tabs.length, (i) {
                return Tab(
                  child: widget.tabBuilder?.call(context, i) ?? Text(tabs[i]),
                );
              }),
            ),
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  final metrics = notification.metrics;
                  if (metrics is PageMetrics &&
                      metrics.page != null &&
                      !metrics.page!.isNaN) {
                    _lastKnownPage = metrics.page;
                  }
                  // Distinguish finger drags from programmatic page
                  // animations by dragDetails (null for driven scrolls).
                  if (notification is ScrollStartNotification &&
                      notification.dragDetails != null) {
                    _pointerDragging = true;
                    if (_tabController?.indexIsChanging ?? false) {
                      _dragDuringFlight = true;
                    }
                  } else if (notification is ScrollEndNotification &&
                      notification.dragDetails != null) {
                    _onPointerDragEnd();
                  }
                  return false;
                },
                child: ScrollConfiguration(
                  behavior: _SwipeScrollBehavior().copyWith(
                    dragDevices: {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.mouse,
                      PointerDeviceKind.stylus,
                      PointerDeviceKind.unknown,
                    },
                  ),
                  child: TabBarView(
                    controller: _tabController,
                    physics: widget.fastSnap
                        ? const _SnapPhysics()
                        : const PageScrollPhysics(),
                    children: List.generate(
                      tabs.length,
                      (i) => widget.pageBuilder(context, i),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: leftExclude,
                child: const EdgeExclusionZone(),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: rightExclude,
                child: const EdgeExclusionZone(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// Covers the OS-reserved edge-gesture strip (systemGestureInsets) so a swipe
// that starts there is claimed here instead of by the TabBarView's PageView.
// The OS back gesture then wins and the channel does not switch.
//
// It must NOT be opaque: an opaque box would swallow every pointer event in the
// strip, including taps/long-press on edge messages and emotes. Using a
// translucent GestureDetector that registers only a horizontal-drag recognizer
// means taps, long-press, and vertical scrolling fall through to the content
// beneath, while a horizontal drag is still captured so the page never moves.
class EdgeExclusionZone extends StatelessWidget {
  const EdgeExclusionZone({super.key});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) {},
      onHorizontalDragUpdate: (_) {},
      onHorizontalDragEnd: (_) {},
    );
  }
}
