import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

class _SwipePhysics extends PageScrollPhysics {
  const _SwipePhysics({super.parent});

  @override
  _SwipePhysics applyTo(ScrollPhysics? ancestor) {
    return _SwipePhysics(parent: buildParent(ancestor));
  }

// stock fling distances for horizontal swipe are too high, just increased sensitivity here
  @override
  double get minFlingDistance => 10.0;

  @override
  double get minFlingVelocity => 20.0;
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
    return (PointerEvent event) =>
        IOSScrollViewFlingVelocityTracker(event.kind);
  }
}

class TabbedLayout extends StatefulWidget {
  final List<String> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelectedIndexChanged;
  final IndexedWidgetBuilder pageBuilder;
  final IndexedWidgetBuilder? tabBuilder;
  final AlignmentGeometry tabAlignment;
  final bool focusOnHalfDrag;

  static const double minEdgeExclusion = 20.0;

  const TabbedLayout({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelectedIndexChanged,
    required this.pageBuilder,
    this.tabBuilder,
    this.tabAlignment = Alignment.centerLeft,
    this.focusOnHalfDrag = false,
  });

  @override
  State<TabbedLayout> createState() => TabbedLayoutState();
}

class TabbedLayoutState extends State<TabbedLayout>
    with TickerProviderStateMixin {
  TabController? _tabController;
  int _tabLength = 0;

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
    _tabController = TabController(length: len, vsync: this, initialIndex: idx);
    _tabController!.addListener(_onTabChanged);
    if (widget.focusOnHalfDrag) {
      _tabController!.animation!.addListener(_onAnimationTick);
    }
  }

  void _onTabChanged() {
    if (_tabController!.indexIsChanging) return;
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
    if (nearest != widget.selectedIndex) {
      widget.onSelectedIndexChanged(nearest);
    }
  }

  @override
  void didUpdateWidget(TabbedLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    final len = widget.tabs.length;
    if (len != _tabLength) {
      _tabController?.removeListener(_onTabChanged);
      if (oldWidget.focusOnHalfDrag && _tabController != null && _tabController!.animation != null) {
        _tabController!.animation!.removeListener(_onAnimationTick);
      }
      _tabController?.dispose();
      _tabController = null;
      _tabLength = len;
      if (len > 0) {
        final idx = widget.selectedIndex.clamp(0, len - 1);
        _tabController = TabController(length: len, vsync: this);
        _tabController!.addListener(_onTabChanged);
        if (widget.focusOnHalfDrag) {
          _tabController!.animation!.addListener(_onAnimationTick);
        }
        _tabController!.index = idx;
      }
    } else if (len > 0) {
      final idx = widget.selectedIndex.clamp(0, len - 1);
      final ctrl = _tabController!;
      if (ctrl.index != idx && !ctrl.indexIsChanging) {
        if (widget.focusOnHalfDrag) {
          final v = ctrl.animation!.value;
          final dragInFlight = !v.isNaN && v.round() != ctrl.index;
          if (!dragInFlight) ctrl.index = idx;
        } else {
          ctrl.index = idx;
        }
      }
    }
  }

  @override
  void dispose() {
    _tabController?.removeListener(_onTabChanged);
    if (widget.focusOnHalfDrag && _tabController != null && _tabController!.animation != null) {
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
    final leftExclude = edgeInset.left > 0 ? edgeInset.left : TabbedLayout.minEdgeExclusion;
    final rightExclude = edgeInset.right > 0 ? edgeInset.right : TabbedLayout.minEdgeExclusion;

    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
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
              ScrollConfiguration(
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
                  physics: const _SwipePhysics(),
                  children: List.generate(
                    tabs.length,
                    (i) => widget.pageBuilder(context, i),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: leftExclude,
                child: const _EdgeExclusionZone(),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: rightExclude,
                child: const _EdgeExclusionZone(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EdgeExclusionZone extends StatelessWidget {
  const _EdgeExclusionZone();

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {},
      onPointerMove: (_) {},
      onPointerUp: (_) {},
      onPointerCancel: (_) {},
    );
  }
}
