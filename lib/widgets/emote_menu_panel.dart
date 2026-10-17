import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../emotes/emote.dart';
import '../l10n/l10n.dart';
import '../emotes/emote_picker.dart';
import '../providers/app_providers.dart';
import '../providers/emote_providers.dart';
import '../services/emote_images.dart';
import '../services/emote_manager.dart';
import '../util/sheet_drag.dart';
import '../widgets/tabbed_layout.dart';
import 'emote_scale_resolver.dart';

class EmoteMenuPanelWidget extends ConsumerStatefulWidget {
  final ScrollController scrollController;
  final bool isActive;
  final String? selectedChannel;
  final void Function(Emote) onEmoteSelected;
  final VoidCallback onClose;
  final DraggableScrollableController sheetCtrl;
  final double emoteMaxFraction;

  const EmoteMenuPanelWidget({
    required this.scrollController,
    required this.isActive,
    required this.sheetCtrl,
    required this.selectedChannel,
    required this.onEmoteSelected,
    required this.onClose,
    required this.emoteMaxFraction,
    super.key,
  });

  @override
  ConsumerState<EmoteMenuPanelWidget> createState() =>
      EmoteMenuPanelWidgetState();
}

/// A run of emotes under an optional title (a sub channel, a provider).
typedef _Group = ({String? title, List<Emote> emotes});

/// One of the scroll's sections (Recent, Subs, Channel, Global).
typedef _Section = ({String label, List<_Group> groups});

class EmoteMenuPanelWidgetState extends ConsumerState<EmoteMenuPanelWidget> {
  late final EmoteManager _emoteManager = ref.read(emoteManagerProvider);
  late final EmoteImages _images = ref.read(emoteImagesProvider);

  // Close threshold: 5% of screen height (sheet-size units).
  static const double _emoteCloseFraction = 0.05;

  // Max panel width: keeps emotes phone-sized on tablets.
  static const double _maxPanelWidth = 480;

  static const int _columns = 5;
  static const double _spacing = 8;

  /// Section and group title heights, fixed so section offsets compute
  /// without laying out the far grids.
  static const double _sectionH = 32;
  static const double _groupH = 26;

  /// 0 emotes, 1 channel points. Each open starts on emotes.
  int _tab = 0;
  List<Emote> _cachedRecentEmotes = [];
  // Cached grid cells by emote id, validated against URL and padding on each
  // rebuild so a changed asset or cell size rebuilds the cell.
  final Map<String, ({double padding, Widget widget})> _cellCache = {};
  double? _lastPanelWidth;

  @override
  void initState() {
    super.initState();
    _loadRecentEmotes();
  }

  @override
  void didUpdateWidget(covariant EmoteMenuPanelWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _cellCache.clear();
      _tab = 0;
      _loadRecentEmotes();
    } else if (!widget.isActive && oldWidget.isActive) {
      _cellCache.clear();
    } else if (widget.isActive &&
        widget.selectedChannel != oldWidget.selectedChannel) {
      _loadRecentEmotes();
    }
  }

  Future<void> _loadRecentEmotes() async {
    final recent = await _emoteManager.recentsForChannel(
      widget.selectedChannel ?? '',
    );
    if (mounted) setState(() => _cachedRecentEmotes = recent);
  }

  @override
  Widget build(BuildContext context) {
    // Refresh recents while open; reopen handles the closed case.
    ref.listen(emoteStateProvider, (_, _) {
      if (!widget.isActive) return;
      _loadRecentEmotes();
    });
    if (!widget.isActive) return const SizedBox.shrink();
    final width = _panelWidth;
    if (_lastPanelWidth != null && _lastPanelWidth != width) {
      // Cell padding is baked into cached cells; rebuild them on width change.
      _cellCache.clear();
    }
    _lastPanelWidth = width;
    final theme = Theme.of(context);
    final panelColor = theme.colorScheme.surfaceContainerLow;
    const radius = BorderRadius.vertical(top: Radius.circular(16));
    // Edge to edge: the sides hug the screen and the top edge carries the
    // border, so the panel reads as a sheet rather than a floating card.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxPanelWidth),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: panelColor,
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            shadows: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 12,
                offset: const Offset(0, -2),
              ),
            ],
          ),
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
                      tabs: [
                        context.l10n.pickerEmotes,
                        context.l10n.pickerPoints,
                      ],
                      selectedIndex: _tab,
                      onSelectedIndexChanged: (i) => setState(() => _tab = i),
                      pageBuilder: (_, i) => i == 0
                          ? _emotesPage(
                              i == _tab ? widget.scrollController : null,
                            )
                          : Center(child: Text(context.l10n.pickerPointsSoon)),
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

  List<_Section> _sections() {
    final l10n = context.l10n;
    List<_Group> groups(Map<String, List<Emote>> byTitle) => [
      for (final e in byTitle.entries)
        if (e.value.isNotEmpty) (title: e.key, emotes: e.value),
    ];
    return [
      if (_cachedRecentEmotes.isNotEmpty)
        (
          label: l10n.emoteTabRecent,
          groups: [(title: null, emotes: _cachedRecentEmotes)],
        ),
      (
        label: l10n.emoteTabSubs,
        groups: groups(
          _emoteManager.subsGrouped(pinnedChannel: widget.selectedChannel),
        ),
      ),
      (
        label: l10n.emoteTabChannel,
        groups: groups(
          _emoteManager.channelEmotesByProvider(widget.selectedChannel ?? ''),
        ),
      ),
      (
        label: l10n.emoteTabGlobal,
        groups: groups(_emoteManager.globalEmotesByProvider()),
      ),
    ].where((s) => s.groups.isNotEmpty).toList();
  }

  double get _sidePadding => _panelWidth * 0.08;

  double get _cellExtent =>
      (_panelWidth - 2 * _sidePadding - (_columns - 1) * _spacing) / _columns;

  /// A group's grid height, its bottom gap included.
  double _gridExtent(int count) {
    final rows = (count / _columns).ceil();
    return rows * _cellExtent + math.max(0, rows - 1) * _spacing + _spacing;
  }

  /// Every section in one scroll, with the edge scroller jumping between
  /// them.
  Widget _emotesPage(ScrollController? scrollController) {
    final sections = _sections();
    if (sections.isEmpty) {
      final empty = Center(
        child: _emoteManager.subEmoteFetchInFlight
            ? const CircularProgressIndicator(strokeWidth: 2)
            : Text(context.l10n.noGlobalEmotes),
      );
      if (scrollController == null) return empty;
      return CustomScrollView(
        controller: scrollController,
        slivers: [SliverFillRemaining(child: empty)],
      );
    }
    final cellPadding = _computeCellPadding();
    final titleStyle = Theme.of(context).textTheme.labelLarge;
    final groupStyle = const TextStyle(
      fontWeight: FontWeight.w600,
      fontSize: 13,
    );
    final offsets = <double>[];
    var at = 0.0;
    final slivers = <Widget>[];
    for (final section in sections) {
      offsets.add(at);
      at += _sectionH;
      slivers.add(
        SliverToBoxAdapter(
          child: SizedBox(
            height: _sectionH,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(section.label.toUpperCase(), style: titleStyle),
              ),
            ),
          ),
        ),
      );
      for (final group in section.groups) {
        if (group.title case final title?) {
          at += _groupH;
          slivers.add(
            SliverToBoxAdapter(
              child: SizedBox(
                height: _groupH,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Text(title, style: groupStyle),
                  ),
                ),
              ),
            ),
          );
        }
        at += _gridExtent(group.emotes.length);
        slivers.add(
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              _sidePadding,
              0,
              _sidePadding,
              _spacing,
            ),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _columns,
                mainAxisSpacing: _spacing,
                crossAxisSpacing: _spacing,
                childAspectRatio: 1,
              ),
              delegate: SliverChildBuilderDelegate(
                (_, i) => _buildEmoteGridItem(group.emotes[i], cellPadding),
                childCount: group.emotes.length,
                findChildIndexCallback: _idToIndexClosure(group.emotes),
              ),
            ),
          ),
        );
      }
    }
    // CustomScrollView (not GridView): swapping scrollable types mid-open
    // kills the animation.
    final scroll = CustomScrollView(
      controller: scrollController,
      slivers: slivers,
    );
    if (scrollController == null) return scroll;
    return _SectionScroller(
      controller: scrollController,
      labels: [for (final s in sections) s.label],
      offsets: offsets,
      child: scroll,
    );
  }

  // Maps cached ids to current indices. Keyed reconciliation moves unchanged cells.
  Map<String, int> _idToIndex(List<Emote> emotes) {
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

  ChildIndexGetter _idToIndexClosure(List<Emote> emotes) {
    final idToIndex = _idToIndex(emotes);
    return (key) {
      if (key is ValueKey<String>) return idToIndex[key.value];
      return null;
    };
  }

  double _computeCellPadding() => _cellExtent * 0.08;

  double get _panelWidth {
    final w = MediaQuery.of(context).size.width;
    return w > _maxPanelWidth ? _maxPanelWidth : w;
  }

  Widget _buildEmoteGridItem(Emote emote, double cellPadding) {
    // Cells resolve their own scale, so the cache only tracks layout.
    final cached = _cellCache[emote.id];
    if (cached != null && cached.padding == cellPadding) {
      return cached.widget;
    }
    // Usage marks deferred via post-frame callback (side effect, must not run during build).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _emoteManager.markEmoteViewed(emote);
    });
    final cell = Material(
      key: ValueKey<String>(emote.id),
      type: MaterialType.transparency,
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: () => widget.onEmoteSelected(emote),
        child: Padding(
          padding: EdgeInsets.all(cellPadding),
          child: EmoteScaleResolver(
            emote: emote,
            surface: EmoteSurface.grid,
            images: _images,
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.contain,
            errorWidget: const Icon(Icons.broken_image, size: 20),
          ),
        ),
      ),
    );
    if (emote.id.isNotEmpty) {
      _cellCache[emote.id] = (padding: cellPadding, widget: cell);
    }
    return cell;
  }
}

/// A fast scroller on the right edge, as in a photo gallery: a thumb that
/// drags the scroll anywhere, a marker where each section starts, and the
/// current section's name beside the thumb while it moves.
class _SectionScroller extends StatefulWidget {
  const _SectionScroller({
    required this.controller,
    required this.labels,
    required this.offsets,
    required this.child,
  });

  final ScrollController controller;
  final List<String> labels;

  /// Where each section starts, in scroll pixels.
  final List<double> offsets;
  final Widget child;

  @override
  State<_SectionScroller> createState() => _SectionScrollerState();
}

class _SectionScrollerState extends State<_SectionScroller> {
  static const double _thumbH = 44;
  static const double _hit = 36;
  static const double _pad = 6;

  bool _dragging = false;
  bool _shown = false;
  Timer? _hide;
  int _section = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
    // The extent is known after the first layout; show the markers then.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(_SectionScroller old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    _hide?.cancel();
    super.dispose();
  }

  ScrollPosition? get _pos {
    final c = widget.controller;
    return c.hasClients && c.positions.length == 1 ? c.position : null;
  }

  int _sectionAt(double pixels) {
    var i = 0;
    while (i + 1 < widget.offsets.length &&
        widget.offsets[i + 1] <= pixels + 1) {
      i++;
    }
    return i;
  }

  void _onScroll() {
    final pos = _pos;
    if (pos == null || !pos.hasContentDimensions) return;
    final section = _sectionAt(pos.pixels);
    if (_dragging && section != _section) HapticFeedback.selectionClick();
    _section = section;
    _hide?.cancel();
    if (!_dragging) {
      _hide = Timer(const Duration(milliseconds: 1200), () {
        if (mounted) setState(() => _shown = false);
      });
    }
    setState(() => _shown = true);
  }

  void _dragTo(double y, double track) {
    final pos = _pos;
    if (pos == null || !pos.hasContentDimensions) return;
    final f = ((y - _thumbH / 2) / (track - _thumbH)).clamp(0.0, 1.0);
    pos.jumpTo(f * pos.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        final track = box.maxHeight - _pad * 2;
        final pos = _pos;
        final max = pos != null && pos.hasContentDimensions
            ? pos.maxScrollExtent
            : 0.0;
        // One tree shape always, so the scroll view never remounts.
        if (max <= 0 || track <= _thumbH) {
          return Stack(children: [widget.child]);
        }
        double yOf(double pixels) =>
            _pad + (pixels / max).clamp(0.0, 1.0) * (track - _thumbH);
        final thumbY = yOf(pos!.pixels);
        final active = _dragging || _shown;
        return Stack(
          children: [
            widget.child,
            // Section markers, centered where the thumb sits at each start.
            for (final o in widget.offsets)
              Positioned(
                right: 2,
                top: yOf(o) + _thumbH / 2 - 1,
                child: AnimatedOpacity(
                  opacity: active ? 1 : 0.4,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    width: 10,
                    height: 2,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            Positioned(
              right: 0,
              top: thumbY,
              child: AnimatedOpacity(
                opacity: active ? 1 : 0.5,
                duration: const Duration(milliseconds: 150),
                child: Container(
                  width: _dragging ? 8 : 5,
                  height: _thumbH,
                  decoration: BoxDecoration(
                    color: _dragging ? scheme.primary : scheme.onSurfaceVariant,
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
            if (active)
              Positioned(
                right: 18,
                top: thumbY + _thumbH / 2 - 14,
                height: 28,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Center(
                      widthFactor: 1,
                      child: Text(
                        widget.labels[_section.clamp(
                          0,
                          widget.labels.length - 1,
                        )],
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: scheme.onPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // The grab strip along the edge.
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: _hit,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragStart: (d) {
                  setState(() => _dragging = true);
                  _dragTo(d.localPosition.dy, track);
                },
                onVerticalDragUpdate: (d) => _dragTo(d.localPosition.dy, track),
                onVerticalDragEnd: (_) {
                  setState(() => _dragging = false);
                  _onScroll();
                },
                onVerticalDragCancel: () => setState(() => _dragging = false),
              ),
            ),
          ],
        );
      },
    );
  }
}
