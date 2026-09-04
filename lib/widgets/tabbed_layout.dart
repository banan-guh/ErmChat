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
  final ValueChanged<int>? onTabTapped;
  final IndexedWidgetBuilder pageBuilder;
  final IndexedWidgetBuilder? tabBuilder;
  final AlignmentGeometry tabAlignment;
  final bool focusOnHalfDrag;
  final Color? tabBarColor;

  /// Snappier page-settle spring. False = stock PageScrollPhysics.
  final bool fastSnap;

  /// Off hides tab strip (hidden-chrome / fullscreen mode).
  final bool showTabBar;

  /// Tab-strip show/hide animation duration. Zero = instant for keyboard collapse.
  final Duration tabBarAnimationDuration;

  /// Overlay anchored top-right below tab strip (hidden-chrome menu).
  final Widget? chromeMenu;

  /// Slot between the tab strip and the pages (stream player dock).
  final Widget? belowTabBar;

  static const double minEdgeExclusion = 20.0;

  const TabbedLayout({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelectedIndexChanged,
    required this.pageBuilder,
    this.onFocusChanged,
    this.onTabTapped,
    this.tabBuilder,
    this.tabAlignment = Alignment.centerLeft,
    this.focusOnHalfDrag = false,
    this.tabBarColor,
    this.fastSnap = true,
    this.showTabBar = true,
    this.chromeMenu,
    this.belowTabBar,
    this.tabBarAnimationDuration = const Duration(milliseconds: 200),
  });

  @override
  State<TabbedLayout> createState() => TabbedLayoutState();
}

class TabbedLayoutState extends State<TabbedLayout>
    with TickerProviderStateMixin {
  // Pager is single writer: indicator, focus, selection derived one-way from its position.
  PageController? _pageController;

  // Visual mirror for tab strip. Index set instantly; offset rides on [TabController.offset].
  TabController? _tabController;

  int _tabLength = 0;
  // Last reported index. Dedups settle commits.
  int _lastReportedIndex = 0;
  // In-flight jump target. Intermediate crossings are flyover (no focus/commit). Cleared on land or finger grab.
  int? _programmaticTarget;
  // True while a finger holds the pager.
  bool _pointerDragging = false;
  // A prop-driven selection change that arrived mid-drag; applied on lift.
  int? _deferredProgrammaticIndex;

  static const _jumpDuration = Duration(milliseconds: 300);

  void _initControllers() {
    final len = widget.tabs.length;
    _tabLength = len;
    _tabController?.dispose();
    _tabController = null;
    if (len == 0) {
      _pageController?.dispose();
      _pageController = null;
      return;
    }
    final idx = widget.selectedIndex.clamp(0, len - 1);
    _lastReportedIndex = idx;
    _programmaticTarget = null;
    _deferredProgrammaticIndex = null;
    _pointerDragging = false;
    // PageController kept across tab-count changes (swap reuses stale ScrollPosition). Only TabController recreated.
    _pageController ??= PageController(initialPage: idx);
    _tabController = TabController(length: len, vsync: this, initialIndex: idx);
    // Force page to selection on controller swap via _goTo (suppresses flyover commits).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _goTo(idx);
      // The page reaches idx via _goTo, but the scrollable tab strip only
      // auto-scrolls to the selected tab on an index change/animation, and a
      // controller swap sets initialIndex without firing that. When the page
      // is already parked on idx (initialPage honored) _goTo early-returns and
      // no scroll notification fires, so the new tab stays off-screen. Drive
      // the strip directly so it always reveals the added channel.
      _tabController?.animateTo(idx);
    });
  }

  // ---- One-way mirror: physical page -> tab strip visuals ------------------

  void _mirrorPageToStrip(double page) {
    final ctrl = _tabController;
    if (ctrl == null || ctrl.indexIsChanging) return;
    final clamped = page.clamp(0.0, (_tabLength - 1).toDouble());
    final nearest = clamped.round();
    if (nearest != ctrl.index) {
      ctrl.index = nearest;
    }
    // Sign matches TabBarView's own sync: offset = page - index.
    ctrl.offset = clamped - nearest;
  }

  // ---- The single funnel: physical page position ---------------------------

  bool _onPageNotification(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (metrics is! PageMetrics || metrics.page == null) return false;
    final page = metrics.page!.clamp(0.0, (_tabLength - 1).toDouble());

    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      // Finger grabbed pager: animated jump loses ownership.
      _pointerDragging = true;
      _programmaticTarget = null;
    }

    _mirrorPageToStrip(page);

    // Half-drag focus: follow nearest page, skip flyover of targeted jumps.
    if (notification is ScrollUpdateNotification &&
        !_isProgrammaticJump &&
        widget.focusOnHalfDrag) {
      final nearest = page.round().clamp(0, _tabLength - 1);
      if (nearest != _lastReportedIndex) {
        _lastReportedIndex = nearest;
        widget.onFocusChanged?.call(nearest);
      }
    }

    if (notification is ScrollEndNotification) {
      final wasDragging = _pointerDragging;
      // Scroll end = no finger. Stolen pointer (back/shade/switcher) cancels drag without dragDetails.
      _pointerDragging = false;
      final nearest = page.round().clamp(0, _tabLength - 1);
      if (!wasDragging) {
        // Final rest: page's actual position wins. HomeScreen selection guard dedupes.
        _programmaticTarget = null;
        if (nearest != _lastReportedIndex) {
          _lastReportedIndex = nearest;
          widget.onSelectedIndexChanged(nearest);
        }
      } else if (notification.dragDetails != null) {
        // Finger lift: the ballistic snap follows; its landing commits.
        _applyDeferredProgrammatic();
      } else {
        // Pointer steal: commit honest position, settle or fly to deferred selection.
        _programmaticTarget = null;
        if (nearest != _lastReportedIndex) {
          _lastReportedIndex = nearest;
          widget.onSelectedIndexChanged(nearest);
        }
        if (_deferredProgrammaticIndex != null) {
          _applyDeferredProgrammatic();
        } else {
          _goTo(nearest);
        }
      }
    }
    return false;
  }

  bool get _isProgrammaticJump => _programmaticTarget != null;

  // ---- Entry points that drive the pager -----------------------------------

  void _goTo(int index) {
    if (index < 0 || index >= _tabLength) return;
    final pc = _pageController;
    final page = (pc != null && pc.hasClients) ? pc.page : null;
    if (page != null && page.round() == index) {
      // Zero-distance jump: settle bookkeeping here.
      _programmaticTarget = null;
      if (_lastReportedIndex != index) {
        _lastReportedIndex = index;
        widget.onSelectedIndexChanged(index);
      }
      return;
    }
    _programmaticTarget = index;
    // forcePixels past maxScrollExtent to materialize the new page (lazy PageView extent is stale).
    final vw = pc!.position.viewportDimension;
    final target = index * vw;
    if (target > pc.position.maxScrollExtent) {
      // ignore: invalid_use_of_protected_member
      pc.position.forcePixels(target);
      _programmaticTarget = null;
      if (_lastReportedIndex != index) {
        _lastReportedIndex = index;
        widget.onSelectedIndexChanged(index);
      }
      return;
    }
    pc.animateToPage(index, duration: _jumpDuration, curve: Curves.ease);
  }

  void _onTabTap(int index) {
    widget.onTabTapped?.call(index);
    // Commit on landing, not at tap (flight may be dragged back).
    _goTo(index);
  }

  void _applyDeferredProgrammatic() {
    final pending = _deferredProgrammaticIndex;
    if (pending == null) return;
    _deferredProgrammaticIndex = null;
    _goTo(pending);
  }

  @override
  void initState() {
    super.initState();
    _initControllers();
  }

  @override
  void didUpdateWidget(TabbedLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    final len = widget.tabs.length;
    if (len != _tabLength) {
      _initControllers();
    } else if (len > 0) {
      // Externally-driven selection change. Pager follows unless finger is down (defers to lift).
      final idx = widget.selectedIndex.clamp(0, len - 1);
      if (idx != _lastReportedIndex) {
        if (_pointerDragging) {
          _deferredProgrammaticIndex = idx;
        } else if (!_isProgrammaticJump || _programmaticTarget != idx) {
          _goTo(idx);
        }
      }
    }
  }

  @override
  void dispose() {
    _pageController?.dispose();
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
        AnimatedSize(
          duration: widget.tabBarAnimationDuration,
          curve: Curves.easeInOut,
          child: widget.showTabBar
              ? Container(
                  decoration: BoxDecoration(
                    color:
                        widget.tabBarColor ??
                        theme.colorScheme.surfaceContainer,
                    border: Border(
                      bottom: BorderSide(color: theme.dividerColor),
                    ),
                  ),
                  child: SizedBox(
                    height: 40,
                    child: TabBar(
                      controller: _tabController,
                      onTap: _onTabTap,
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
                          child:
                              widget.tabBuilder?.call(context, i) ??
                              Text(tabs[i]),
                        );
                      }),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        if (widget.belowTabBar != null) widget.belowTabBar!,
        Expanded(
          child: Stack(
            children: [
              NotificationListener<ScrollNotification>(
                onNotification: _onPageNotification,
                child: ScrollConfiguration(
                  behavior: _SwipeScrollBehavior().copyWith(
                    dragDevices: {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.mouse,
                      PointerDeviceKind.stylus,
                      PointerDeviceKind.unknown,
                    },
                  ),
                  child: PageView(
                    controller: _pageController,
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
              if (widget.chromeMenu != null)
                Positioned(
                  top: widget.showTabBar
                      ? 8.0
                      : MediaQuery.of(context).padding.top + 8,
                  right: 8,
                  child: widget.chromeMenu!,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// Covers OS edge-gesture strip so swipes are captured (back gesture wins). Must be translucent to pass taps/vertical scroll through.
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
