import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Floating composer island: the field and the bottom buttons in one shell,
/// inset from the screen edges. The radius matches the opaque island's.
const double kComposerIslandMargin = 8.0;
const double kComposerIslandRadius = 16.0;

// Visible gap between the newest row and the composer surface, in every
// layout (floating island, docked pane, history).
const double kComposerGap = 8.0;

// Gap the list keeps above an in-flow composer. The pane adds the rest of
// [kComposerGap] as the island's top margin.
const double kOpaqueComposerGap = kComposerGap / 2;

// The floating island's margin is already in the measured clearance, so the
// list pays the whole gap.
const double kFloatingComposerGap = kComposerGap;

/// The floating island's footprint over the chat body, in every composer
/// style. ChatBody's layout publishes it after laying out the island and
/// before the body, and [IslandSpacer]/[IslandInset] read it in their own
/// layout, so rows clear the island in the frame it changes.
class IslandMetrics {
  double _top = 0;
  double _height = 0;
  double _footer = 0;
  double _extra = 0;
  double _trim = 0;
  double Function(String channel)? _footerFor;
  final _readers = <RenderObject>{};
  bool _settlePending = false;

  /// Runs after a frame that changed the metrics, for readers that size in
  /// build (the emote sheet).
  VoidCallback? onSettled;

  /// Whether an island floats over the body.
  bool get floating => _top > 0.5;

  /// The island's top above the body's bottom, where overlays anchor.
  double get top => _top;

  /// The island's own height, as laid out.
  double get height => _height;

  /// Overlays above the island (the reply header) that lists clear too.
  double get extra => _extra;

  /// How far a list clears the island, without [extra]. A channel page
  /// passes its [page] channel and clears that channel's island, so it is
  /// placed before a switch lands. Every other list clears the island on
  /// screen, whatever channel its rows belong to.
  double clearance({String? page}) {
    if (!floating) return 0;
    final onScreen = _top - _trim;
    final footerFor = _footerFor;
    if (page == null || footerFor == null) return onScreen;
    return onScreen - _footer + footerFor(page);
  }

  /// A chat list's bottom padding: the clearance plus a visual gap, or a
  /// small fixed gap above a docked composer.
  double listGap({String? page}) =>
      (floating
          ? clearance(page: page) + kFloatingComposerGap
          : kOpaqueComposerGap) +
      _extra;

  /// Called by ChatBody's layout only. [footer] is the footer's laid-out
  /// height, which [footerFor] predicts per channel; [trim] is empty room
  /// above the island the lists may overlap.
  void publish({
    required double top,
    required double height,
    required double footer,
    required double extra,
    required double trim,
    required double Function(String channel)? footerFor,
  }) {
    if (top == _top &&
        height == _height &&
        footer == _footer &&
        extra == _extra &&
        trim == _trim &&
        footerFor == _footerFor) {
      return;
    }
    _top = top;
    _height = height;
    _footer = footer;
    _extra = extra;
    _trim = trim;
    _footerFor = footerFor;
    for (final reader in _readers) {
      reader.markNeedsLayout();
    }
    if (_settlePending) return;
    _settlePending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _settlePending = false;
      onSettled?.call();
    });
  }
}

/// Provides ChatBody's [IslandMetrics] to the lists and overlays that clear
/// the floating island.
class IslandScope extends InheritedWidget {
  const IslandScope({super.key, required this.metrics, required super.child});

  final IslandMetrics metrics;

  static IslandScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<IslandScope>();

  @override
  bool updateShouldNotify(IslandScope oldWidget) =>
      metrics != oldWidget.metrics;
}

/// A render object that reads [IslandMetrics] in layout and lays out again
/// when they change.
mixin _IslandReader on RenderObject {
  IslandMetrics? _metrics;
  String? _page;

  void _bind(IslandMetrics? metrics, String? page) {
    if (!identical(metrics, _metrics)) {
      if (attached) {
        _metrics?._readers.remove(this);
        metrics?._readers.add(this);
      }
      _metrics = metrics;
      markNeedsLayout();
    }
    if (page != _page) {
      _page = page;
      markNeedsLayout();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _metrics?._readers.add(this);
  }

  @override
  void detach() {
    _metrics?._readers.remove(this);
    super.detach();
  }
}

/// Empty space as tall as a list's clearance over the island, sized in
/// layout. Lists put it at their bottom end so the last rows scroll clear of
/// the island and on behind it. [page] is set on a channel's page (see
/// [IslandMetrics.clearance]).
class IslandSpacer extends LeafRenderObjectWidget {
  const IslandSpacer({super.key, this.page, this.chat = false});

  final String? page;

  /// A chat list keeps [IslandMetrics.listGap]. Other lists clear the island
  /// and the overlays above it flush.
  final bool chat;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderIslandSpacer(chat)
        .._bind(IslandScope.maybeOf(context)?.metrics, page);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderIslandSpacer)
      ..chat = chat
      .._bind(IslandScope.maybeOf(context)?.metrics, page);
  }
}

class _RenderIslandSpacer extends RenderBox with _IslandReader {
  _RenderIslandSpacer(this._chat);

  bool _chat;
  set chat(bool value) {
    if (value == _chat) return;
    _chat = value;
    markNeedsLayout();
  }

  double get _extent {
    final metrics = _metrics;
    if (metrics == null) return _chat ? kOpaqueComposerGap : 0;
    return _chat
        ? metrics.listGap(page: _page)
        : metrics.clearance(page: _page) + metrics.extra;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(Size(0, _extent));

  @override
  double computeMinIntrinsicHeight(double width) => _extent;

  @override
  double computeMaxIntrinsicHeight(double width) => _extent;

  @override
  void performLayout() => size = computeDryLayout(constraints);
}

/// Pads [child] from below by the island clearance, in layout, so a button
/// over a list rides above the island with its rows.
class IslandInset extends SingleChildRenderObjectWidget {
  const IslandInset({super.key, this.page, super.child});

  /// See [IslandSpacer.page].
  final String? page;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderIslandInset().._bind(IslandScope.maybeOf(context)?.metrics, page);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderIslandInset)._bind(
        IslandScope.maybeOf(context)?.metrics,
        page,
      );
}

class _RenderIslandInset extends RenderShiftedBox with _IslandReader {
  _RenderIslandInset() : super(null);

  @override
  void performLayout() {
    final bottom = _metrics?.clearance(page: _page) ?? 0;
    final child = this.child;
    if (child == null) {
      size = constraints.constrain(Size(0, bottom));
      return;
    }
    child.layout(
      constraints.deflate(EdgeInsets.only(bottom: bottom)),
      parentUsesSize: true,
    );
    (child.parentData! as BoxParentData).offset = Offset.zero;
    size = constraints.constrain(
      Size(child.size.width, child.size.height + bottom),
    );
  }
}
