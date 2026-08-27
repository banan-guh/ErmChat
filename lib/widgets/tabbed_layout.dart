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

  /// When false, only the chat PageView is rendered (no channel tab strip).
  /// Used by the hidden-chrome / fullscreen mode.
  final bool showTabBar;

  /// Overlay anchored top-right just below the tab strip (above the chat).
  /// Used for the hidden-chrome menu arrow; stays visible in fullscreen.
  final Widget? chromeMenu;

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
    this.showTabBar = true,
    this.chromeMenu,
  });

  @override
  State<TabbedLayout> createState() => TabbedLayoutState();
}

class TabbedLayoutState extends State<TabbedLayout>
    with TickerProviderStateMixin {
  // The pager is the single writer. It is the only animated thing here, and
  // everything else (tab indicator, focus, selection) is derived one-way from
  // its physical position, committed through one funnel. Focus cannot
  // disagree with the visible page because it IS round(visible page).
  //
  // This replaces the previous TabBarView + TabController pairing, where the
  // framework wrote TabController.index behind our back at gesture boundaries
  // (tap flights led the page, ScrollEnd wrote index back, interrupted
  // animations notified with unreachable targets), which made focus-vs-page
  // desync representable no matter how carefully listeners reconciled.
  PageController? _pageController;

  // Visual mirror for the tab strip. Never animated by us: index is set
  // instantly on integer crossings and the fractional position rides on
  // [TabController.offset], the same writes TabBarView used, so the
  // indicator behaves pixel-identically.
  TabController? _tabController;

  int _tabLength = 0;
  // Last index reported upward (focus or select) or initialized with.
  // Dedups settle commits; derived, never a competing writer.
  int _lastReportedIndex = 0;
  // While set, an animated jump to this index is in flight (tab tap or
  // programmatic navigation). Intermediate page crossings are flyover: they
  // must not focus or commit channels swept past. Cleared when the page
  // lands or a finger grabs the pager.
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
    // The PageController is created once and kept across channel-count changes.
    // A swap (dispose + new controller) makes Flutter reuse the surviving
    // ScrollPosition, which keeps the OLD maxScrollExtent from the previous tab
    // count; animateToPage(newIndex) then clamps to newIndex-1 and the pager
    // stops one channel short of the added one. Keeping the controller attached
    // lets the position recompute its extent against the new children. Only the
    // TabController needs recreating, since it carries the tab count.
    _pageController ??= PageController(initialPage: idx);
    _tabController = TabController(length: len, vsync: this, initialIndex: idx);
    // initialPage only applies when the controller first attaches; on a
    // controller swap the surviving scroll position keeps its old pixels, so
    // the page must be forced to the selection once mounted. Route it through
    // _goTo (which sets _programmaticTarget) rather than a bare jumpToPage:
    // that suppresses the focusOnHalfDrag flyover commits that would otherwise
    // select a channel swept past mid-transition, and a mid-transition rebuild
    // from history/connection state then can't re-commit a neighbor.
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
      // A finger grabbed the pager: any animated jump we were driving loses
      // ownership, the finger decides from here.
      _pointerDragging = true;
      _programmaticTarget = null;
    }

    _mirrorPageToStrip(page);

    // Half-drag focus: follow the nearest page while scrolling under finger
    // or momentum, but never for the flyover of a targeted jump.
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
      // Any scroll end means no finger is left on the pager. Lifts carry
      // dragDetails, but a stolen pointer (back gesture, notification shade,
      // app switcher) cancels the drag and its ScrollEnd has none. Treating
      // only lifts as finger-up stranded this flag, and every later
      // prop-driven selection parked in _deferredProgrammaticIndex forever:
      // highlight moved, page did not.
      _pointerDragging = false;
      final nearest = page.round().clamp(0, _tabLength - 1);
      if (!wasDragging) {
        // Final rest: fling settle or targeted-jump arrival. A jump that
        // did not land on its target was superseded or lost; the page's
        // actual position wins. HomeScreen's selection guard is the single
        // dedup point: never skip a report against the selectedIndex prop,
        // which lags behind focus commits that rebuild nothing.
        _programmaticTarget = null;
        if (nearest != _lastReportedIndex) {
          _lastReportedIndex = nearest;
          widget.onSelectedIndexChanged(nearest);
        }
      } else if (notification.dragDetails != null) {
        // Finger lift: the ballistic snap follows; its landing commits.
        _applyDeferredProgrammatic();
      } else {
        // Pointer steal: the OS cancelled the drag, so no ballistic is
        // coming and the pixels would rest mid-page forever. Commit the
        // honest position, then settle through the normal jump path - or
        // fly straight to a selection that arrived mid-drag.
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
      // Zero-distance jump: nothing will land, so settle the bookkeeping
      // here. HomeScreen's guard dedupes when it already knows.
      _programmaticTarget = null;
      if (_lastReportedIndex != index) {
        _lastReportedIndex = index;
        widget.onSelectedIndexChanged(index);
      }
      return;
    }
    _programmaticTarget = index;
    // Lazy PageView only lays out pages within the current maxScrollExtent, so
    // after a channel is appended the extent is stale (still the old tab count)
    // and animateToPage would clamp to newIndex-1, parking one channel short of
    // the added one. forcePixels sets pixels without clamping, which forces the
    // viewport to materialize the new page and recompute its extent.
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
    // Commit on landing, not at tap: a tap whose flight is caught and
    // dragged back commits nothing for the abandoned channel. Until then the
    // jump target suppresses flyover commits.
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
      // A selection change that did not originate from this widget's pager
      // (notification tap, channel list change). The pager follows it, but
      // never while a finger holds the page: defer to lift.
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
          duration: const Duration(milliseconds: 200),
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

// Covers the OS-reserved edge-gesture strip (systemGestureInsets) so a swipe
// that starts there is claimed here instead of by the pager's PageView.
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
