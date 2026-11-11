import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, ValueListenable;
import 'package:flutter/gestures.dart' show PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'chat_rows.dart';
import 'island_metrics.dart';

/// Rows a re-anchor shifted within one sliver: each row's new index by its
/// key, and the layout offset at each new index. Live for the one rebuild
/// and layout that apply the re-anchor.
class ChatMoves {
  final Map<String, int> indexOf = {};
  final Map<int, double> offsets = {};

  int? find(Key key) => key is ValueKey<String> ? indexOf[key.value] : null;

  void clear() {
    indexOf.clear();
    offsets.clear();
  }
}

/// A [SliverList] that restores the offsets of rows [ChatMoves] shifted. A
/// moved child otherwise keeps no offset unless its new slot held a child
/// last layout, and the sliver drops it or fails hit testing on it
/// (flutter#153922).
class MovingChatSliverList extends SliverList {
  const MovingChatSliverList({
    super.key,
    required super.delegate,
    required this.moves,
  });

  final ChatMoves moves;

  @override
  RenderSliverList createRenderObject(BuildContext context) =>
      _RenderMovingChatSliverList(
        childManager: context as SliverMultiBoxAdaptorElement,
        moves: moves,
      );
}

class _RenderMovingChatSliverList extends RenderSliverList {
  _RenderMovingChatSliverList({
    required super.childManager,
    required this.moves,
  });

  final ChatMoves moves;

  @override
  void performLayout() {
    final offsets = moves.offsets;
    if (offsets.isNotEmpty) {
      for (RenderBox? c = firstChild; c != null; c = childAfter(c)) {
        final d = c.parentData! as SliverMultiBoxAdaptorParentData;
        final o = offsets[d.index];
        if (o != null) d.layoutOffset = o;
      }
      offsets.clear();
    }
    super.performLayout();
  }
}

/// Applies a resolver on top of the platform physics. Everything else
/// delegates to the parent, so fling, overscroll and gesture routing are
/// stock.
mixin _HoldPhysicsMixin on ScrollPhysics {
  double? Function(ScrollMetrics, bool bouncing) get resolve;

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) =>
      resolve(newPosition, isScrolling && this is BouncingScrollPhysics) ??
      super.adjustPositionForNewDimensions(
        oldPosition: oldPosition,
        newPosition: newPosition,
        isScrolling: isScrolling,
        velocity: velocity,
      );
}

class _HoldClampingPhysics extends ClampingScrollPhysics
    with _HoldPhysicsMixin {
  const _HoldClampingPhysics({super.parent, required this.resolve});

  @override
  final double? Function(ScrollMetrics, bool bouncing) resolve;

  @override
  _HoldClampingPhysics applyTo(ScrollPhysics? ancestor) =>
      _HoldClampingPhysics(parent: buildParent(ancestor), resolve: resolve);
}

class _HoldBouncingPhysics extends BouncingScrollPhysics
    with _HoldPhysicsMixin {
  const _HoldBouncingPhysics({super.parent, required this.resolve});

  @override
  final double? Function(ScrollMetrics, bool bouncing) resolve;

  @override
  _HoldBouncingPhysics applyTo(ScrollPhysics? ancestor) =>
      _HoldBouncingPhysics(parent: buildParent(ancestor), resolve: resolve);
}

/// The shared scroll surface for chat-like lists. It owns the reversed
/// [CustomScrollView], the hold physics, the island inset and the
/// scroll-down button. It knows nothing about live chat, the archive or
/// markers; callers pass the slivers.
class ChatListShell extends StatelessWidget {
  const ChatListShell({
    super.key,
    required this.controller,
    required this.slivers,
    required this.onScrollNotification,
    this.onPointerSignal,
    this.center,
    this.resolve,
    this.physics,
    this.atBottom,
    this.onJumpToBottom,
    this.heroTag,
    this.islandPage,
    this.clearsIsland = true,
    this.cacheExtent,
    this.scrollViewKey,
    this.semanticChildCount,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    this.dismissKeyboardOnTap = true,
  });

  final ScrollController controller;
  final List<Widget> slivers;
  final bool Function(ScrollNotification notification) onScrollNotification;
  final void Function(PointerSignalEvent event)? onPointerSignal;
  final Key? center;
  final double? Function(ScrollMetrics metrics, bool bouncing)? resolve;
  final ScrollPhysics? physics;
  final ValueListenable<bool>? atBottom;
  final VoidCallback? onJumpToBottom;
  final Object? heroTag;
  final String? islandPage;

  /// Whether this list clears the floating island. Split chat turns it off
  /// for the pane that does not sit over it.
  final bool clearsIsland;
  final ScrollCacheExtent? cacheExtent;
  final Key? scrollViewKey;
  final int? semanticChildCount;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  /// iOS only: a tap on empty chat space dismisses the keyboard. Rows are
  /// InkWells, so their own taps win the arena and never dismiss.
  final bool dismissKeyboardOnTap;

  ScrollPhysics _physics() {
    final resolve = this.resolve;
    if (resolve == null) {
      return physics ?? const ClampingScrollPhysics();
    }
    return defaultTargetPlatform == TargetPlatform.iOS
        ? _HoldBouncingPhysics(
            parent: AlwaysScrollableScrollPhysics(parent: physics),
            resolve: resolve,
          )
        : _HoldClampingPhysics(parent: physics, resolve: resolve);
  }

  @override
  Widget build(BuildContext context) {
    final atBottom = this.atBottom;
    final onJumpToBottom = this.onJumpToBottom;
    Widget content = Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Listener(
          onPointerSignal: onPointerSignal,
          child: NotificationListener<ScrollNotification>(
            onNotification: onScrollNotification,
            child: CustomScrollView(
              key: scrollViewKey,
              controller: controller,
              reverse: true,
              physics: _physics(),
              scrollCacheExtent: cacheExtent,
              center: center,
              semanticChildCount: semanticChildCount,
              keyboardDismissBehavior: keyboardDismissBehavior,
              slivers: slivers,
            ),
          ),
        ),
        if (atBottom != null && onJumpToBottom != null)
          ValueListenableBuilder<bool>(
            valueListenable: atBottom,
            builder: (_, value, _) {
              final button = Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16, bottom: 16),
                  child: ScrollDownButton(
                    atBottom: value,
                    heroTag: heroTag ?? 'scroll_down',
                    onPressed: onJumpToBottom,
                  ),
                ),
              );
              return Positioned.fill(
                child: clearsIsland
                    ? IslandInset(page: islandPage, child: button)
                    : button,
              );
            },
          ),
      ],
    );
    if (dismissKeyboardOnTap && defaultTargetPlatform == TargetPlatform.iOS) {
      content = GestureDetector(
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: content,
      );
    }
    return content;
  }
}
