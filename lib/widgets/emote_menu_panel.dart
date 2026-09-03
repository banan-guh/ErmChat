import 'package:flutter/material.dart';
import '../models/generic_emote.dart';
import '../services/emote_manager.dart';
import '../util/sheet_drag.dart';
import '../widgets/tabbed_layout.dart';
import 'emote_image.dart';
import 'emote_image_provider.dart';

class EmoteMenuPanelWidget extends StatefulWidget {
  final ScrollController scrollController;
  final bool isActive;
  final String? selectedChannel;
  final void Function(GenericEmote) onEmoteSelected;
  final VoidCallback onClose;
  final EmoteManager emoteManager;
  final DraggableScrollableController sheetCtrl;
  final double emoteMaxFraction;

  const EmoteMenuPanelWidget({
    required this.scrollController,
    required this.isActive,
    required this.sheetCtrl,
    required this.selectedChannel,
    required this.onEmoteSelected,
    required this.onClose,
    required this.emoteManager,
    required this.emoteMaxFraction,
    super.key,
  });

  @override
  State<EmoteMenuPanelWidget> createState() => EmoteMenuPanelWidgetState();
}

class EmoteMenuPanelWidgetState extends State<EmoteMenuPanelWidget> {
  // Close threshold: 5% of screen height (sheet-size units).
  static const double _emoteCloseFraction = 0.05;

  // Max panel width: keeps emotes phone-sized on tablets.
  static const double _maxPanelWidth = 480;

  int _emoteTabIndex = 0;
  List<GenericEmote> _cachedRecentEmotes = [];
  bool _recentEmotesLoaded = false;
  // Cached grid cells by emote id. Validated against URL + padding; 7TV deltas short-circuit.
  final Map<
    String,
    ({String url, double padding, Widget widget, bool uncapped})
  >
  _cellCache = {};
  double? _lastPanelWidth;

  @override
  void initState() {
    super.initState();
    _loadRecentEmotes();
    widget.emoteManager.addListener(_onEmoteManagerChanged);
  }

  @override
  void didUpdateWidget(covariant EmoteMenuPanelWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _cellCache.clear();
      _loadRecentEmotes();
    } else if (!widget.isActive && oldWidget.isActive) {
      _cellCache.clear();
    } else if (widget.isActive &&
        widget.selectedChannel != oldWidget.selectedChannel) {
      _loadRecentEmotes();
    }
  }

  @override
  void dispose() {
    widget.emoteManager.removeListener(_onEmoteManagerChanged);
    super.dispose();
  }

  void _onEmoteManagerChanged() {
    // Rebuild only while open; recents refresh on reopen.
    if (!widget.isActive) return;
    _loadRecentEmotes();
  }

  Future<void> _loadRecentEmotes() async {
    final recent = await widget.emoteManager.recentsForChannel(
      widget.selectedChannel ?? '',
    );
    if (mounted) {
      setState(() {
        _cachedRecentEmotes = recent;
        _recentEmotesLoaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive) return const SizedBox.shrink();
    final width = _panelWidth;
    if (_lastPanelWidth != null && _lastPanelWidth != width) {
      // Cell padding is baked into cached cells; rebuild them on width change.
      _cellCache.clear();
    }
    _lastPanelWidth = width;
    final theme = Theme.of(context);
    final panelColor = theme.colorScheme.surfaceContainerLow;
    final radius = BorderRadius.circular(16);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxPanelWidth),
        child: Container(
          margin: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: panelColor,
            borderRadius: radius,
            border: Border.all(color: theme.colorScheme.outlineVariant),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 12,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          clipBehavior: Clip.none,
          child: ClipRRect(
            borderRadius: radius,
            child: GestureDetector(
              key: const Key('emote_panel_handle'),
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (details) {
                final newPixels =
                    widget.sheetCtrl.pixels - details.primaryDelta!;
                final newSize = widget.sheetCtrl
                    .pixelsToSize(newPixels)
                    .clamp(0.0, 1.0);
                if (widget.sheetCtrl.isAttached) {
                  widget.sheetCtrl.jumpTo(newSize);
                }
              },
              // Close on drag-below-threshold or fast flick (shared thresholds).
              onVerticalDragEnd: (details) {
                if (!widget.sheetCtrl.isAttached) return;
                final velocity = details.primaryVelocity ?? 0;
                final fraction =
                    widget.sheetCtrl.size / widget.emoteMaxFraction;
                if (shouldCloseSheet(
                  fraction: fraction,
                  velocity: velocity,
                  closeFraction: _emoteCloseFraction / widget.emoteMaxFraction,
                )) {
                  widget.onClose();
                } else {
                  // Settle duration scales with remaining distance and release speed.
                  final remaining =
                      ((widget.emoteMaxFraction - widget.sheetCtrl.size) /
                              widget.emoteMaxFraction)
                          .clamp(0.0, 1.0);
                  final velocityFactor = (velocity.abs() / 5000).clamp(
                    0.0,
                    0.5,
                  );
                  final duration = Duration(
                    milliseconds: (150 + 200 * remaining * (1 - velocityFactor))
                        .round(),
                  );
                  widget.sheetCtrl.animateTo(
                    widget.emoteMaxFraction,
                    duration: duration,
                    curve: Curves.easeInOutCubicEmphasized,
                  );
                }
              },
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(
                      top: 15,
                      bottom: 24,
                    ), // exactly 15 to line up with the other line
                    child: Center(
                      child: SizedBox(
                        width: 32,
                        height: 4,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.grey.shade400,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: TabbedLayout(
                      tabAlignment: Alignment.center,
                      tabBarColor: panelColor,
                      tabs: const ['Recent', 'Subs', 'Channel', 'Global'],
                      selectedIndex: _emoteTabIndex,
                      onSelectedIndexChanged: (i) =>
                          setState(() => _emoteTabIndex = i),
                      pageBuilder: (_, i) => _buildEmoteTabPage(
                        i,
                        i == _emoteTabIndex ? widget.scrollController : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmoteTabPage(int tabIndex, ScrollController? scrollController) {
    switch (tabIndex) {
      case 0:
        return _buildEmoteRecentGrid(scrollController);
      case 1:
        return _buildEmoteSubsGrid(scrollController);
      case 2:
        return _buildEmoteChannelGrid(scrollController);
      default:
        return _buildEmoteGlobalGrid(scrollController);
    }
  }

  Widget _buildEmoteRecentGrid(ScrollController? scrollController) {
    if (!_recentEmotesLoaded) {
      return _buildEmoteEmptyState(
        scrollController,
        const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_cachedRecentEmotes.isEmpty) {
      return _buildEmoteEmptyState(
        scrollController,
        const Center(child: Text('No recently used emotes')),
      );
    }
    return _buildEmoteGrid(_cachedRecentEmotes, scrollController);
  }

  Widget _buildEmoteSubsGrid(ScrollController? scrollController) {
    final byChannel = widget.emoteManager.subsGrouped(
      pinnedChannel: widget.selectedChannel,
    );
    if (byChannel.isEmpty) {
      return _buildEmoteEmptyState(
        scrollController,
        const Center(child: Text('No subscriber emotes available')),
      );
    }
    return _buildGroupedEmoteGrid(byChannel, scrollController);
  }

  Widget _buildEmoteChannelGrid(ScrollController? scrollController) {
    final channel = widget.selectedChannel ?? '';
    final emotes = widget.emoteManager.channelTabEmotes(channel);
    if (emotes.isEmpty) {
      return _buildEmoteEmptyState(
        scrollController,
        const Center(child: Text('No channel emotes')),
      );
    }
    return _buildEmoteGrid(emotes, scrollController);
  }

  Widget _buildEmoteGlobalGrid(ScrollController? scrollController) {
    final byProvider = widget.emoteManager.globalEmotesByProvider();
    if (byProvider.isEmpty) {
      return _buildEmoteEmptyState(
        scrollController,
        const Center(child: Text('No global emotes')),
      );
    }
    return _buildGroupedEmoteGrid(byProvider, scrollController);
  }

  // Sectioned grid with group headers (Subs by channel, Global by provider).
  Widget _buildGroupedEmoteGrid(
    Map<String, List<GenericEmote>> groups,
    ScrollController? scrollController,
  ) {
    final sidePadding = _panelWidth * 0.08;
    return CustomScrollView(
      controller: scrollController,
      slivers: [
        for (final entry in groups.entries) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(left: 8, top: 8, right: 8),
              child: Text(
                entry.key,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: sidePadding),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1,
              ),
              delegate: SliverChildBuilderDelegate(
                (_, i) {
                  final cellPadding = _computeCellPadding();
                  return _buildEmoteGridItem(entry.value[i], cellPadding);
                },
                childCount: entry.value.length,
                findChildIndexCallback: _idToIndexClosure(entry.value),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildEmoteEmptyState(
    ScrollController? scrollController,
    Widget child,
  ) {
    if (scrollController == null) return child;
    return CustomScrollView(
      controller: scrollController,
      slivers: [SliverFillRemaining(child: child)],
    );
  }

  Widget _buildEmoteGrid(
    List<GenericEmote> emotes,
    ScrollController? scrollController,
  ) {
    final sidePadding = _panelWidth * 0.08;
    // CustomScrollView (not GridView): swapping scrollable types mid-open kills the animation.
    return CustomScrollView(
      controller: scrollController,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: sidePadding, vertical: 4),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 5,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1,
            ),
            delegate: SliverChildBuilderDelegate(
              (_, i) {
                final cellPadding = _computeCellPadding();
                return _buildEmoteGridItem(emotes[i], cellPadding);
              },
              childCount: emotes.length,
              findChildIndexCallback: _idToIndexClosure(emotes),
            ),
          ),
        ),
      ],
    );
  }

  // Maps cached ids to current indices. Keyed reconciliation moves unchanged cells.
  Map<String, int> _idToIndex(List<GenericEmote> emotes) {
    final pending = _cellCache.keys.toSet();
    if (pending.isEmpty) return const {};
    final map = <String, int>{};
    for (var i = 0; i < emotes.length && pending.isNotEmpty; i++) {
      final id = emotes[i].id;
      if (id.isNotEmpty && pending.remove(id)) {
        map[id] = i;
      }
    }
    return map;
  }

  ChildIndexGetter _idToIndexClosure(List<GenericEmote> emotes) {
    final idToIndex = _idToIndex(emotes);
    return (key) {
      if (key is ValueKey<String>) return idToIndex[key.value];
      return null;
    };
  }

  double _computeCellPadding() {
    final sidePadding = _panelWidth * 0.08;
    final cellWidth = (_panelWidth - 2 * sidePadding - 4 * 8) / 5;
    return cellWidth * 0.08;
  }

  double get _panelWidth {
    final w = MediaQuery.of(context).size.width;
    return w > _maxPanelWidth ? _maxPanelWidth : w;
  }

  Widget _buildEmoteGridItem(GenericEmote emote, double cellPadding) {
    // Preview cells use EmoteImage: shared decode, disposed with last widget.
    final url = emote.url;
    final cached = _cellCache[emote.id];
    final uncapped = EmoteUrlProvider.alwaysAnimatePanel;
    if (cached != null &&
        cached.url == url &&
        cached.padding == cellPadding &&
        cached.uncapped == uncapped) {
      return cached.widget;
    }
    // Usage marks deferred via post-frame callback (side effect, must not run during build).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.emoteManager.markEmoteViewed(emote);
    });
    final cell = Material(
      key: ValueKey<String>(emote.id),
      type: MaterialType.transparency,
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: () => widget.onEmoteSelected(emote),
        child: Padding(
          padding: EdgeInsets.all(cellPadding),
          child: EmoteImage(
            url: url,
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.contain,
            alternateUrls: [if (emote.url1x != null) emote.url1x!],
            errorWidget: const Icon(Icons.broken_image, size: 20),
            uncapped: uncapped,
          ),
        ),
      ),
    );
    if (emote.id.isNotEmpty) {
      _cellCache[emote.id] = (
        url: url,
        padding: cellPadding,
        widget: cell,
        uncapped: uncapped,
      );
    }
    return cell;
  }
}
