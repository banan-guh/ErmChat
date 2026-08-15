import 'package:flutter/material.dart';
import '../models/generic_emote.dart';
import '../services/emote_manager.dart';
import '../util/sheet_drag.dart';
import '../widgets/tabbed_layout.dart';
import 'emote_image.dart';

class EmoteMenuPanelWidget extends StatefulWidget {
  final ScrollController scrollController;
  final bool isActive;
  final String? selectedChannel;
  final void Function(GenericEmote) onEmoteSelected;
  final VoidCallback onClose;
  final EmoteManager emoteManager;
  final DraggableScrollableController sheetCtrl;
  final double emoteMaxFraction;
  final bool tintedTabBar;

  const EmoteMenuPanelWidget({
    required this.scrollController,
    required this.isActive,
    required this.sheetCtrl,
    required this.selectedChannel,
    required this.onEmoteSelected,
    required this.onClose,
    required this.emoteManager,
    required this.emoteMaxFraction,
    this.tintedTabBar = false,
    super.key,
  });

  @override
  State<EmoteMenuPanelWidget> createState() => EmoteMenuPanelWidgetState();
}

class EmoteMenuPanelWidgetState extends State<EmoteMenuPanelWidget> {
  // Position-based close triggers below 5% of screen height (in sheet-size
  // units, hence the division by emoteMaxFraction in onDragEnd).
  static const double _emoteCloseFraction = 0.05;

  // Cap the panel width so emotes keep phone-sized proportions (5 columns of
  // a consistent size) on wide devices like tablets instead of ballooning
  // across the full screen.
  static const double _maxPanelWidth = 480;

  int _emoteTabIndex = 0;
  List<GenericEmote> _cachedRecentEmotes = [];
  bool _recentEmotesLoaded = false;
  // Cached grid cells keyed by emote id. A 7TV delta only adds/removes/moves
  // cells at and below the change point in the code-sorted lists; unchanged
  // emotes return the identical cached widget instance, so Flutter
  // short-circuits rebuilds above the event. Validated against the emote's
  // URL + the cell padding, so refetches and width changes rebuild cleanly.
  final Map<String, ({String url, double padding, Widget widget})> _cellCache =
      {};
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
      // Fresh recents + a clean cell cache on (re)open.
      _cellCache.clear();
      _loadRecentEmotes();
    } else if (!widget.isActive && oldWidget.isActive) {
      _cellCache.clear();
    }
  }

  @override
  void dispose() {
    widget.emoteManager.removeListener(_onEmoteManagerChanged);
    super.dispose();
  }

  void _onEmoteManagerChanged() {
    // Rebuild only while the sheet is open; recents refresh on reopen via
    // didUpdateWidget.
    if (!widget.isActive) return;
    _loadRecentEmotes();
  }

  Future<void> _loadRecentEmotes() async {
    final recent = await widget.emoteManager.recentEmotes();
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
              // Close on drag-below-threshold or a fast flick down (shared
              // thresholds in util/sheet_drag.dart). Position close triggers
              // at 5% of screen height; momentum is more sensitive than
              // before.
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
                  // Scale the settle duration by how far the sheet still has
                  // to travel and how fast it was released: a short remaining
                  // distance or a quick fling settles faster.
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
                      tabBarColor: widget.tintedTabBar
                          ? theme.colorScheme.primaryContainer
                          : panelColor,
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
      case 3:
        return _buildEmoteGlobalGrid(scrollController);
      default:
        return const SizedBox();
    }
  }

  Widget _buildEmoteRecentGrid(ScrollController? scrollController) {
    if (!_recentEmotesLoaded) {
      return _buildEmoteEmptyState(
        scrollController,
        const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    // Only show recents available in the current channel. Falls through to
    // all recents if channel emotes are not yet loaded.
    final channelEmotes = widget.emoteManager.byCode(
      widget.selectedChannel ?? '',
    );
    final filtered = channelEmotes != null
        ? () {
            final channelIds = channelEmotes.suggestions
                .map((e) => e.id)
                .toSet();
            return _cachedRecentEmotes
                .where((e) => channelIds.contains(e.id))
                .toList();
          }()
        : _cachedRecentEmotes;

    if (filtered.isEmpty) {
      return _buildEmoteEmptyState(
        scrollController,
        const Center(child: Text('No recently used emotes')),
      );
    }
    return _buildEmoteGrid(filtered, scrollController);
  }

  Widget _buildEmoteSubsGrid(ScrollController? scrollController) {
    final byChannel = widget.emoteManager.subscriberEmotesByChannel();
    if (byChannel.isEmpty) {
      return _buildEmoteEmptyState(
        scrollController,
        const Center(child: Text('No subscriber emotes available')),
      );
    }
    // Pin the currently viewed channel's group to the top when the account
    // is subscribed to it; the remaining groups keep their alphabetical
    // order. The original map is left untouched so the manager cache stays
    // valid for later calls.
    final selected = widget.selectedChannel;
    if (selected != null && byChannel.containsKey(selected)) {
      final reordered = <String, List<GenericEmote>>{
        selected: byChannel[selected]!,
        for (final entry in byChannel.entries)
          if (entry.key != selected) entry.key: entry.value,
      };
      return _buildGroupedEmoteGrid(reordered, scrollController);
    }
    return _buildGroupedEmoteGrid(byChannel, scrollController);
  }

  Widget _buildEmoteChannelGrid(ScrollController? scrollController) {
    final channel = widget.selectedChannel ?? '';
    final emotes = widget.emoteManager.channelNonTwitchEmotes(channel);
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

  // Sectioned grid with a header per group (used by the Subs tab grouped by
  // channel and the Global tab grouped by provider).
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
    return GridView.builder(
      controller: scrollController,
      padding: EdgeInsets.symmetric(horizontal: sidePadding, vertical: 4),
      physics: const AlwaysScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: emotes.length,
      itemBuilder: (_, i) {
        final cellPadding = _computeCellPadding();
        return _buildEmoteGridItem(emotes[i], cellPadding);
      },
      findChildIndexCallback: _idToIndexClosure(emotes),
    );
  }

  // Maps cached-cell emote ids to their current index in a displayed list,
  // scanning only until every cached id is located (lists can be far larger
  // than the cache). Keyed reconciliation lets Flutter move unchanged cells
  // below a 7TV delta instead of rebuilding them.
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
    // Preview cells render through EmoteImage like chat: frames are decoded
    // once per URL, shared, and disposed with the last visible widget.
    final url = emote.url;
    final cached = _cellCache[emote.id];
    if (cached != null && cached.url == url && cached.padding == cellPadding) {
      return cached.widget;
    }
    widget.emoteManager.markEmoteViewed(emote);
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
            placeholder: const ShimmerEmotePlaceholder(),
            errorWidget: const Icon(Icons.broken_image, size: 20),
          ),
        ),
      ),
    );
    if (emote.id.isNotEmpty) {
      _cellCache[emote.id] = (url: url, padding: cellPadding, widget: cell);
    }
    return cell;
  }
}
