import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/generic_emote.dart';
import '../services/emote_manager.dart';
import '../widgets/tabbed_layout.dart';

class EmoteMenuPanelWidget extends StatefulWidget {
  final ScrollController scrollController;
  final bool isActive;
  final double uiScale;
  final String? selectedChannel;
  final void Function(GenericEmote) onEmoteSelected;
  final VoidCallback onClose;
  final EmoteManager emoteManager;
  final DraggableScrollableController sheetCtrl;
  final double emoteMaxFraction;
  final Duration sheetAnimDuration;

  const EmoteMenuPanelWidget({
    required this.scrollController,
    required this.isActive,
    required this.sheetCtrl,
    required this.uiScale,
    required this.selectedChannel,
    required this.onEmoteSelected,
    required this.onClose,
    required this.emoteManager,
    required this.emoteMaxFraction,
    required this.sheetAnimDuration,
    super.key,
  });

  @override
  State<EmoteMenuPanelWidget> createState() => EmoteMenuPanelWidgetState();
}

class EmoteMenuPanelWidgetState extends State<EmoteMenuPanelWidget> {
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
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        children: [
          GestureDetector(
            key: const Key('emote_panel_handle'),
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (details) {
              final newPixels = widget.sheetCtrl.pixels - details.primaryDelta!;
              final newSize = widget.sheetCtrl.pixelsToSize(newPixels).clamp(0.0, 1.0);
              if (widget.sheetCtrl.isAttached) {
                widget.sheetCtrl.jumpTo(newSize);
              }
            },
            onVerticalDragEnd: (details) {
              if (!widget.sheetCtrl.isAttached) return;
              final velocity = details.primaryVelocity ?? 0;
              if (widget.sheetCtrl.size < 0.3 || velocity > 400) {
                widget.onClose();
              } else {
                widget.sheetCtrl.animateTo(
                  widget.emoteMaxFraction,
                  duration: widget.sheetAnimDuration,
                  curve: Curves.easeOut,
                );
              }
            },
            child: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 16),
              child: Center(
                child: SizedBox(
                  width: 32,
                  height: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.grey,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: TabbedLayout(
              tabAlignment: Alignment.center,
              tabs: const ['Recent', 'Subs', 'Channel', 'Global'],
              selectedIndex: _emoteTabIndex,
              onSelectedIndexChanged: (i) => setState(() => _emoteTabIndex = i),
              pageBuilder: (_, i) => _buildEmoteTabPage(
                i,
                i == _emoteTabIndex ? widget.scrollController : null,
              ),
            ),
          ),
        ],
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
    if (_cachedRecentEmotes.isEmpty) {
      return _buildEmoteEmptyState(
        scrollController,
        const Center(child: Text('No recently used emotes')),
      );
    }
    return _buildEmoteGrid(_cachedRecentEmotes, scrollController);
  }

  Widget _buildEmoteSubsGrid(ScrollController? scrollController) {
    final byChannel = widget.emoteManager.subscriberEmotesByChannel();
    if (byChannel.isEmpty) {
      return _buildEmoteEmptyState(
        scrollController,
        const Center(child: Text('No subscriber emotes available')),
      );
    }
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
          SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 5,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1,
            ),
            delegate: SliverChildBuilderDelegate(
              (_, i) => _buildEmoteGridItem(entry.value[i]),
              childCount: entry.value.length,
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
      slivers: [
        SliverFillRemaining(child: child),
      ],
    );
  }

  Widget _buildEmoteGrid(
    List<GenericEmote> emotes,
    ScrollController? scrollController,
  ) {
    return GridView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(4),
      physics: const AlwaysScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: emotes.length,
      itemBuilder: (_, i) => _buildEmoteGridItem(emotes[i]),
    );
  }

  Widget _buildEmoteGridItem(GenericEmote emote) {
    return Material(
      type: MaterialType.transparency,
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: () => widget.onEmoteSelected(emote),
        child: CachedNetworkImage(
          imageUrl: emote.url,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.contain,
          fadeInDuration: Duration.zero,
          placeholder: (_, _) => const SizedBox(),
          errorWidget: (_, _, _) => const Icon(Icons.broken_image, size: 20),
        ),
      ),
    );
  }
}
