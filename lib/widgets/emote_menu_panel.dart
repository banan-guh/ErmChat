import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/generic_emote.dart';
import '../services/emote_manager.dart';
import '../util/sheet_drag.dart';
import '../widgets/tabbed_layout.dart';

class EmoteMenuPanelWidget extends StatefulWidget {
  final ScrollController scrollController;
  final bool isActive;
  final String? selectedChannel;
  final void Function(GenericEmote) onEmoteSelected;
  final VoidCallback onClose;
  final EmoteManager emoteManager;
  final DraggableScrollableController sheetCtrl;
  final double emoteMaxFraction;
  final Duration sheetAnimDuration;
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
    required this.sheetAnimDuration,
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

  int _emoteTabIndex = 0;
  List<GenericEmote> _cachedRecentEmotes = [];
  bool _recentEmotesLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadRecentEmotes();
    widget.emoteManager.addListener(_loadRecentEmotes);
  }

  @override
  void dispose() {
    widget.emoteManager.removeListener(_loadRecentEmotes);
    super.dispose();
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
    final theme = Theme.of(context);
    final panelColor = theme.colorScheme.surfaceContainerLow;
    final radius = BorderRadius.circular(16);
    return Container(
      margin: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: panelColor,
        borderRadius: radius,
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
            final newPixels = widget.sheetCtrl.pixels - details.primaryDelta!;
            final newSize = widget.sheetCtrl
                .pixelsToSize(newPixels)
                .clamp(0.0, 1.0);
            if (widget.sheetCtrl.isAttached) {
              widget.sheetCtrl.jumpTo(newSize);
            }
          },
          // Close on drag-below-threshold or a fast flick down (shared
          // thresholds in util/sheet_drag.dart). Position close triggers at
          // 5% of screen height; momentum is more sensitive than before.
          onVerticalDragEnd: (details) {
            if (!widget.sheetCtrl.isAttached) return;
            final velocity = details.primaryVelocity ?? 0;
            final fraction = widget.sheetCtrl.size / widget.emoteMaxFraction;
            if (shouldCloseSheet(
              fraction: fraction,
              velocity: velocity,
              closeFraction: _emoteCloseFraction / widget.emoteMaxFraction,
            )) {
              widget.onClose();
            } else {
              widget.sheetCtrl.animateTo(
                widget.emoteMaxFraction,
                duration: widget.sheetAnimDuration,
                curve: Curves.easeOutCubic,
              );
            }
          },
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 24),
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
    final screenWidth = MediaQuery.of(context).size.width;
    final sidePadding = screenWidth * 0.08;
    return CustomScrollView(
      controller: scrollController,
      slivers: [
        for (final entry in byChannel.entries) ...[
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
              delegate: SliverChildBuilderDelegate((_, i) {
                final cellPadding = _computeCellPadding();
                return _buildEmoteGridItem(entry.value[i], cellPadding);
              }, childCount: entry.value.length),
            ),
          ),
        ],
      ],
    );
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
    final emotes = widget.emoteManager.globalEmotes();
    if (emotes.isEmpty) {
      return _buildEmoteEmptyState(
        scrollController,
        const Center(child: Text('No global emotes')),
      );
    }
    return _buildEmoteGrid(emotes, scrollController);
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
    final screenWidth = MediaQuery.of(context).size.width;
    final sidePadding = screenWidth * 0.08;
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
    );
  }

  double _computeCellPadding() {
    final screenWidth = MediaQuery.of(context).size.width;
    final sidePadding = screenWidth * 0.08;
    final cellWidth = (screenWidth - 2 * sidePadding - 4 * 8) / 5;
    return cellWidth * 0.08;
  }

  Widget _buildEmoteGridItem(GenericEmote emote, double cellPadding) {
    return Material(
      type: MaterialType.transparency,
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: () => widget.onEmoteSelected(emote),
        child: Padding(
          padding: EdgeInsets.all(cellPadding),
          child: CachedNetworkImage(
            imageUrl: emote.urlLarge ?? emote.url,
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.contain,
            fadeInDuration: Duration.zero,
            placeholder: (_, _) => const SizedBox(),
            errorWidget: (_, _, _) => const Icon(Icons.broken_image, size: 20),
          ),
        ),
      ),
    );
  }
}
