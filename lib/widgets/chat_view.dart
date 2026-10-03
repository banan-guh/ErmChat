import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show kLongPressTimeout, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../models/twitch_message.dart';
import '../providers/feature_providers.dart' show chatNoticeProvider;
import '../util/mention.dart';
import '../util/prefs.dart';
import '../util/thread_utils.dart';
import 'glass_chrome.dart';
import 'seven_tv_paint_service.dart';
import '../util/timestamp_formatter.dart';
import '../util/haptics.dart';
import '../widgets/chat_message_tile.dart';
import '../widgets/emote_text.dart';
import '../widgets/message_builder.dart';
import '../services/link_whitelist.dart';

class ChatView extends StatefulWidget {
  // Per-channel cache bound; high enough to survive message insertions.
  static const int _maxCachedTiles = 300;

  /// Global counter for checkered mode: stripes alternate and stay glued to messages.
  static int _checkerSeq = 0;

  final String channel;
  final List<TwitchMessage> messages;

  /// Per-channel tile cache. Null builds fresh per tick (panels).
  final Map<String, Map<String?, Widget>>? tileCache;
  final ValueNotifier<bool> atBottomNotifier;
  final ValueNotifier<int> messageNotifier;
  final ScrollController scrollController;
  final MessageBuilder messageBuilder;

  /// Opens the user profile sheet.
  final void Function(String login, String? userId, {String? displayName})
  onShowUserProfile;

  /// Null disables the long-press message menu.
  final void Function(TwitchMessage)? onShowMessageMenu;

  /// Null disables copy-on-double-tap for chat messages.
  final void Function(TwitchMessage)? onCopyMessage;

  /// Notified on scroll-state flips (main chat unread/jump bookkeeping).
  final void Function(String)? onScrollActivity;
  final TwitchMessage? Function(TwitchMessage)? onFindThreadRoot;
  final void Function(TwitchMessage)? onShowThreadView;

  /// Off when thread callbacks are absent or every row is already a reply.
  final bool showReplyIndicators;
  final String emptyText;
  final ScrollPhysics? physics;

  /// Off in the mentions tab so deleted rows stay readable.
  final bool fadeDeleted;

  /// Prefixes rows with their source channel (mentions inbox).
  final bool showChannel;

  /// True keeps the list alive when it scrolls out of a pager. Channel pages
  /// pass false so background channels unmount; their scroll offset is
  /// restored through PageStorage.
  final bool keepAlive;

  /// Holds the reading position when rows arrive while scrolled up. Off for
  /// filtered views (search) where head changes are not arrivals.
  final bool keepPosition;

  /// Hero tag for the scroll-down FAB. Defaults to [channel]-keyed.
  final String? scrollFabHeroTag;
  final bool showTimestamp;
  final String timestampFormat;
  final double chatFontScale;
  final bool checkeredMessages;
  final double highlightOpacity;
  final bool lineSeparator;
  final String sharedChatMode;
  final SevenTvPaintService? paintService;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  /// Link whitelist for system-message parser. Null = use messageBuilder's.
  final LinkWhitelist? linkWhitelist;

  /// Null = no dimming; true fades the row (search dim mode).
  final bool Function(TwitchMessage)? isDimmed;

  /// Glass overlay clearance above the oldest row, below the floating header.
  final double topOverlayPadding;

  const ChatView({
    super.key,
    required this.channel,
    required this.messages,
    this.tileCache,
    required this.atBottomNotifier,
    required this.messageNotifier,
    required this.scrollController,
    required this.messageBuilder,
    required this.onShowUserProfile,
    this.onShowMessageMenu,
    this.onCopyMessage,
    this.onScrollActivity,
    this.onFindThreadRoot,
    this.onShowThreadView,
    this.showReplyIndicators = true,
    this.emptyText = 'No messages yet',
    this.physics,
    this.fadeDeleted = true,
    this.showChannel = false,
    this.keepAlive = true,
    this.keepPosition = true,
    this.scrollFabHeroTag,
    this.showTimestamp = true,
    this.timestampFormat = kDefaultTimestampFormat,
    this.chatFontScale = 1.0,
    this.checkeredMessages = false,
    this.highlightOpacity = 0.6,
    this.lineSeparator = false,
    this.sharedChatMode = 'spotlight',
    this.paintService,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    this.linkWhitelist,
    this.isDimmed,
    this.topOverlayPadding = 0,
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

/// Reading position held while the reader is scrolled away from the newest row.
///
/// The view fills in [resolve]; the physics calls it during layout, after the
/// sliver has laid out its children, so the correction lands in the same frame
/// as the content change.
class _ChatHold {
  bool paused = false;

  /// True from a content build until the correction layout consumes it.
  bool pending = false;

  /// Key of the row the reader is anchored on.
  String? anchorId;

  /// The anchor's content-space layout offset at the last settled layout.
  double anchorOffset = 0;

  /// The message list the current build is rendering.
  List<TwitchMessage>? msgs;

  /// New pixels that keep the anchor on screen, or null to leave it alone.
  double? Function(ScrollMetrics) resolve = (_) => null;
}

/// Applies [_ChatHold.resolve] on top of the platform physics. Everything else
/// delegates to the parent, so fling, overscroll and gesture routing are stock.
mixin _ChatHoldPhysicsMixin on ScrollPhysics {
  _ChatHold get hold;

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final target = hold.resolve(newPosition);
    if (target != null) return target;
    return super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
  }
}

class _ChatHoldClampingPhysics extends ClampingScrollPhysics
    with _ChatHoldPhysicsMixin {
  _ChatHoldClampingPhysics({super.parent, required this.hold});

  @override
  final _ChatHold hold;

  @override
  _ChatHoldClampingPhysics applyTo(ScrollPhysics? ancestor) =>
      _ChatHoldClampingPhysics(parent: buildParent(ancestor), hold: hold);
}

class _ChatHoldBouncingPhysics extends BouncingScrollPhysics
    with _ChatHoldPhysicsMixin {
  _ChatHoldBouncingPhysics({super.parent, required this.hold});

  @override
  final _ChatHold hold;

  @override
  _ChatHoldBouncingPhysics applyTo(ScrollPhysics? ancestor) =>
      _ChatHoldBouncingPhysics(parent: buildParent(ancestor), hold: hold);
}

class _ChatViewState extends State<ChatView>
    with AutomaticKeepAliveClientMixin {
  /// Copies the sender in the mention format pref and confirms in the chat
  /// notice bar.
  Future<void> _copyUsername(TwitchMessage msg) async {
    final prefs = await Prefs.load();
    final text = formatMention(
      prefs.mentionFormat,
      mentionName(msg),
    ).trimRight();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ProviderScope.containerOf(
      context,
      listen: false,
    ).read(chatNoticeProvider).show('Copied $text');
  }

  /// Pixels from the newest row above which the reader counts as scrolled up.
  static const double _followEps = 0.5;

  @override
  bool get wantKeepAlive => widget.keepAlive;
  double _cachedSystemScale = 1.0;
  int _lastMsgLen = -1;
  Map<String, int> _idToIndex = {};
  String? _endsFirst;
  String? _endsLast;

  // Materialized row-index range from the previous layout, plus the range the
  // current build is filling. [_findChildIndex] uses the previous range to keep
  // a moved row out of a slot that did not exist yet.
  int? _prevBuiltMin;
  int? _prevBuiltMax;
  int? _builtMin;
  int? _builtMax;

  // Rows the current build renders, and the slots [_findChildIndex] already
  // handed out this rebuild, so two elements never move into one slot.
  List<TwitchMessage> _listMsgs = const [];
  final Set<int> _claimedSlots = {};

  /// Live row gates, re-checked against the viewport after each layout.
  final Set<_RowGateState> _gates = {};
  bool _gateSyncScheduled = false;

  // Hold state shared with the physics; the physics corrects during layout so
  // a prepended row never shows in the wrong place, not even for one frame.
  final _ChatHold _hold = _ChatHold();
  bool _refreshScheduled = false;

  // Pointer-down of a possible tap on the chat, for tap-to-dismiss.
  (Offset, Duration)? _tapDown;

  // Follow intent, separate from the raw offset. A far jump can leave a
  // transient offset for a frame while the sliver rebuilds; only a user drag
  // leaves follow, so those transients cannot re-arm the hold.
  bool _follow = true;
  bool _followSnapScheduled = false;
  int _followSnapTries = 0;

  // Effective pill clearance for this frame: the explicit prop wins, zero
  // falls back to the scope so surfaces without threaded params (welcome,
  // panels) still clear the floating pill. Set at the top of every build.
  double _effBottom = 0;
  double _listExtra = 0;

  @override
  void initState() {
    super.initState();
    _hold.resolve = _resolveCorrection;
  }

  @override
  void didUpdateWidget(covariant ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.chatFontScale != oldWidget.chatFontScale) {
      setState(() {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newScale = MediaQuery.textScalerOf(context).scale(1.0);
    if (newScale != _cachedSystemScale) {
      _cachedSystemScale = newScale;
      // Pixel-sized tiles would otherwise survive the scale change.
      widget.tileCache?.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final surface = Theme.of(context).scaffoldBackgroundColor;
    final s = widget.chatFontScale * _cachedSystemScale;
    final glassScope = GlassChromeScope.maybeOf(context);
    // The pill clearance arrives through the scope, so every list (pages,
    // panels, welcome) clears the floating pill without threaded params.
    _effBottom = glassScope?.bottomClearance ?? 0;
    _listExtra = glassScope?.listExtra ?? 0;
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        // A viewport resize (keyboard) moves rows in or out of view without
        // a scroll or a build. This arrives post-frame, after layout, so it
        // syncs now: a deferred sync could wait for a frame that never comes.
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            _syncRowGates();
            return false;
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              _scheduleGateSync();
              if (notification is ScrollStartNotification) {
                if (notification.dragDetails != null) _follow = false;
                _applyScrollState(notification.metrics);
              } else if (notification is ScrollUpdateNotification) {
                if (notification.dragDetails != null) _follow = false;
                _applyScrollState(notification.metrics);
              } else if (notification is ScrollEndNotification) {
                if (notification.metrics.pixels <= _followEps) _follow = true;
                _applyScrollState(notification.metrics);
              }
              return false;
            },
            child: ScrollbarTheme(
              data: const ScrollbarThemeData(
                thickness: WidgetStatePropertyAll(0),
              ),
              child: ValueListenableBuilder<int>(
                valueListenable: widget.messageNotifier,
                builder: (_, _, _) {
                  final msgs = widget.messages;
                  _syncHold(msgs);
                  return _tapToDismiss(_buildList(context, msgs, surface, s));
                },
              ),
            ),
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: widget.atBottomNotifier,
          builder: (_, atBottom, _) {
            // Glass pill floats over the list bottom, so lift the button
            // above it by the same clearance the newest rows use.
            return Positioned(
              right: 16,
              bottom: 16 + _effBottom,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 100),
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: atBottom
                    ? const SizedBox.shrink()
                    : _effBottom > 0.5
                    ? GlassIconButton(
                        key: const ValueKey('scroll_down'),
                        icon: const Icon(Icons.keyboard_arrow_down),
                        shape: GlassIconButtonShape.roundedSquare,
                        onPressed: () {
                          iosHaptic(HapticFeedback.lightImpact);
                          _jumpToBottom();
                        },
                        quality: GlassQuality.minimal,
                      )
                    : FloatingActionButton(
                        key: const ValueKey('scroll_down'),
                        heroTag:
                            widget.scrollFabHeroTag ??
                            'scroll_down_${widget.channel}',
                        onPressed: () {
                          iosHaptic(HapticFeedback.lightImpact);
                          _jumpToBottom();
                        },
                        child: const Icon(Icons.keyboard_arrow_down),
                      ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildList(
    BuildContext context,
    List<TwitchMessage> msgs,
    Color surface,
    double s,
  ) {
    _beginBuiltRange();
    final empty = msgs.isEmpty;
    // Opaque in-flow composer sits flush under the list, so keep a small
    // fixed gap above it. Glass mode clears the measured pill instead.
    final listBottom =
        (_effBottom > 0.5 ? _effBottom : kOpaqueComposerGap) + _listExtra;
    if (!empty) {
      final cache = widget.tileCache?.putIfAbsent(
        widget.channel,
        () => <String?, Widget>{},
      );
      _refreshIndexMap(msgs, cache);
      _listMsgs = msgs;
      return ListView.builder(
        // PageStorage key restores the offset after the channel page
        // unmounts off screen; kept-alive lists need no key.
        key: widget.keepAlive
            ? ValueKey<String>(widget.channel)
            : PageStorageKey<String>('${widget.channel}:chat'),
        controller: widget.scrollController,
        reverse: true,
        physics: _scrollPhysics(),
        padding: EdgeInsets.only(
          top: widget.topOverlayPadding,
          bottom: listBottom,
        ),
        keyboardDismissBehavior: widget.keyboardDismissBehavior,
        itemCount: msgs.length,
        findChildIndexCallback: _findChildIndex,
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: false,
        addSemanticIndexes: true,
        itemBuilder: (ctx, i) {
          _noteBuiltIndex(i);
          _scheduleGateSync();
          return _RowGate(
            key: _messageKey(msgs[i]),
            gates: _gates,
            child: _buildTile(
              msgs,
              cache,
              _idToIndex,
              i,
              surface,
              s,
              ctx,
              widget.checkeredMessages,
            ),
          );
        },
      );
    }
    // Distinct key from the content list: swapping the item set under one key
    // lets the sliver graft a stale row onto the empty state.
    final emptyMsg = TwitchMessage(
      login: '',
      text: widget.emptyText,
      isSystem: true,
      channel: widget.channel,
    );
    _refreshIndexMap(const [], null);
    return ListView.builder(
      key: ValueKey<String>('${widget.channel}:empty'),
      controller: widget.scrollController,
      reverse: true,
      physics: _scrollPhysics(),
      padding: EdgeInsets.only(
        top: widget.topOverlayPadding,
        bottom: _effBottom,
      ),
      keyboardDismissBehavior: widget.keyboardDismissBehavior,
      itemCount: 1,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: false,
      addSemanticIndexes: false,
      itemBuilder: (ctx, i) => _buildTile(
        [emptyMsg],
        null,
        const {},
        0,
        surface,
        s,
        ctx,
        widget.checkeredMessages,
      ),
    );
  }

  /// A tap on the chat dismisses the keyboard. Raw pointers, so row taps
  /// keep working, and a scroll or long press does not count.
  Widget _tapToDismiss(Widget list) => Listener(
    onPointerDown: (e) => _tapDown = (e.position, e.timeStamp),
    onPointerUp: (e) {
      final down = _tapDown;
      _tapDown = null;
      if (down == null) return;
      if ((e.position - down.$1).distance > kTouchSlop) return;
      if (e.timeStamp - down.$2 > kLongPressTimeout) return;
      FocusManager.instance.primaryFocus?.unfocus();
    },
    onPointerCancel: (_) => _tapDown = null,
    child: list,
  );

  // Always scrollable, so a drag on a short list still dismisses the keyboard.
  ScrollPhysics _scrollPhysics() {
    final parent = AlwaysScrollableScrollPhysics(parent: widget.physics);
    return defaultTargetPlatform == TargetPlatform.iOS
        ? _ChatHoldBouncingPhysics(parent: parent, hold: _hold)
        : _ChatHoldClampingPhysics(parent: parent, hold: _hold);
  }

  /// Jumps to the newest row. Follow is claimed before the jump so a transient
  /// offset from the far move cannot re-arm the hold, and re-asserted after so
  /// the list actually settles on the newest row.
  void _jumpToBottom() {
    _follow = true;
    _followSnapTries = 0;
    final pos = _position;
    if (pos != null && pos.hasPixels) pos.jumpTo(0);
    widget.atBottomNotifier.value = true;
    widget.onScrollActivity?.call(widget.channel);
    _scheduleFollowSnap();
  }

  /// Rebuilds the live-id to index map used to evict tiles that left the
  /// buffer before the least recently used ones.
  void _refreshIndexMap(List<TwitchMessage> msgs, Map<String?, Widget>? cache) {
    if (msgs.isEmpty) {
      _lastMsgLen = 0;
      _idToIndex = {};
      _endsFirst = null;
      _endsLast = null;
      return;
    }
    if (msgs.length == _lastMsgLen &&
        _rowKey(msgs.first) == _endsFirst &&
        _rowKey(msgs.last) == _endsLast) {
      return;
    }
    _lastMsgLen = msgs.length;
    _endsFirst = _rowKey(msgs.first);
    _endsLast = _rowKey(msgs.last);
    final idToIndex = <String, int>{};
    if (cache != null) {
      final pending = cache.keys.whereType<String>().toSet();
      for (var i = 0; i < msgs.length && pending.isNotEmpty; i++) {
        final id = msgs[i].messageId;
        if (id != null && pending.remove(id)) {
          idToIndex[id] = i;
        }
      }
    }
    _idToIndex = idToIndex;
  }

  /// Opens a build frame: the range just built becomes the reference range for
  /// [_findChildIndex], which runs before this frame's rows are built.
  void _beginBuiltRange() {
    _prevBuiltMin = _builtMin;
    _prevBuiltMax = _builtMax;
    _builtMin = null;
    _builtMax = null;
    _claimedSlots.clear();
  }

  void _noteBuiltIndex(int index) {
    if (_builtMin == null || index < _builtMin!) _builtMin = index;
    if (_builtMax == null || index > _builtMax!) _builtMax = index;
  }

  /// Maps a row's key to its index so the sliver can move the row instead of
  /// rebuilding it. A move is only allowed into a slot that existed in the last
  /// layout: the sliver restores the moved row's offset from that slot's
  /// previous occupant, and a slot with no occupant leaves the offset null,
  /// which crashes hit testing (flutter#153922). Each slot is claimed once and
  /// must hold the keyed row: two elements sent to one slot orphan a render
  /// child, which shows as a blank row and a stuck scroll. Returning null
  /// rebuilds that one row in place instead.
  int? _findChildIndex(Key key) {
    if (key is! ValueKey<String>) return null;
    final index = _idToIndex[key.value];
    if (index == null) return null;
    final min = _prevBuiltMin;
    final max = _prevBuiltMax;
    if (min == null || max == null) return null;
    if (index < min || index > max) return null;
    if (index >= _listMsgs.length || _listMsgs[index].messageId != key.value) {
      return null;
    }
    if (!_claimedSlots.add(index)) return null;
    return index;
  }

  /// Re-checks row visibility once this frame's layout settles.
  void _scheduleGateSync() {
    if (_gateSyncScheduled) return;
    _gateSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gateSyncScheduled = false;
      if (mounted) _syncRowGates();
    });
  }

  /// Freezes emotes in rows that sit in the cache extent: laid out beyond the
  /// viewport but never painted, so their animation is pure waste.
  void _syncRowGates() {
    final pos = _position;
    final viewport = pos?.context.notificationContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return;
    final extent = viewport.size.height;
    for (final gate in _gates) {
      final box = gate.context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      gate.visible.value = top < extent && top + box.size.height > 0;
    }
  }

  /// Applies the scroll state for a user or ballistic update and mirrors it to
  /// [atBottomNotifier]. Only a user drag clears [_follow].
  void _applyScrollState(ScrollMetrics metrics) {
    final atBottom = metrics.pixels <= _followEps;
    if (atBottom && !widget.atBottomNotifier.value) {
      widget.atBottomNotifier.value = true;
      widget.onScrollActivity?.call(widget.channel);
    } else if (!atBottom && widget.atBottomNotifier.value) {
      widget.atBottomNotifier.value = false;
      widget.onScrollActivity?.call(widget.channel);
    }
    final paused = !_follow && metrics.pixels > _followEps;
    _hold.paused = paused;
    if (paused && widget.keepPosition) {
      _scheduleAnchorRefresh();
    } else if (!paused) {
      _hold.pending = false;
      if (atBottom) _followSnapTries = 0;
    }
  }

  /// Re-asserts the bottom while following. A far jump can leave a transient
  /// offset for a frame while the sliver rebuilds, and without the snap the
  /// hold would read that offset as a pause and never resume following.
  void _scheduleFollowSnap() {
    if (_followSnapScheduled) return;
    _followSnapScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followSnapScheduled = false;
      if (!mounted || !_follow) return;
      final pos = _position;
      if (pos == null || !pos.hasPixels || pos.pixels <= _followEps) return;
      pos.jumpTo(0);
      if (_followSnapTries++ < 4) _scheduleFollowSnap();
    });
  }

  ScrollPosition? get _position => widget.scrollController.hasClients
      ? widget.scrollController.position
      : null;

  /// Flags a content build so the physics can hold the reader's row this frame.
  ///
  /// The anchor was captured at the last settled layout. The physics re-reads
  /// its offset once the new rows are laid out and shifts the scroll by the
  /// difference, so any number of inserts, evicts or middle deletes in one
  /// frame is handled without counting them.
  void _syncHold(List<TwitchMessage> msgs) {
    _hold.msgs = msgs;
    final pos = _position;
    if (pos == null || !pos.hasPixels) {
      _hold.paused = false;
      _hold.pending = false;
      return;
    }
    if (_follow) {
      // Following: a far jump or a sliver rebuild can leave a transient
      // offset. Snap back instead of treating it as a pause.
      if (pos.pixels > _followEps) _scheduleFollowSnap();
      _hold.paused = false;
      _hold.pending = false;
      return;
    }
    final paused = pos.pixels > _followEps;
    _hold.paused = paused;
    if (!paused) {
      _hold.pending = false;
      return;
    }
    if (widget.keepPosition && _hold.anchorId != null) {
      _hold.pending = true;
      // Equal-height churn leaves the extents unchanged, so force the viewport
      // to evaluate the physics even when min/max did not move.
      pos.correctBy(0);
    }
    if (widget.keepPosition) _scheduleAnchorRefresh();
  }

  /// Physics hook: the pixels that keep the anchor at its captured position,
  /// or null when there is nothing to hold.
  double? _resolveCorrection(ScrollMetrics newPosition) {
    if (!_hold.paused || !_hold.pending || _hold.anchorId == null) return null;
    _hold.pending = false;
    final sliver = _findSliver();
    final msgs = _hold.msgs;
    if (sliver == null || msgs == null) return null;
    double? newOffset;
    for (
      RenderBox? child = sliver.firstChild;
      child != null;
      child = sliver.childAfter(child)
    ) {
      final pd = child.parentData as SliverMultiBoxAdaptorParentData?;
      final index = pd?.index;
      final offset = pd?.layoutOffset;
      if (index == null ||
          offset == null ||
          index < 0 ||
          index >= msgs.length) {
        continue;
      }
      if (_rowKey(msgs[index]) == _hold.anchorId) {
        newOffset = offset;
        break;
      }
    }
    if (newOffset == null) return null;
    final target = newPosition.pixels + (newOffset - _hold.anchorOffset);
    return target.clamp(
      newPosition.minScrollExtent,
      newPosition.maxScrollExtent,
    );
  }

  /// The list's sliver, so child offsets can be read during layout.
  RenderSliverMultiBoxAdaptor? _findSliver() {
    final root = _position?.context.notificationContext?.findRenderObject();
    if (root == null) return null;
    final viewport = _findDescendant<RenderViewport>(root);
    final firstSliver = viewport?.firstChild;
    if (firstSliver == null) return null;
    return _findDescendant<RenderSliverMultiBoxAdaptor>(firstSliver);
  }

  T? _findDescendant<T extends RenderObject>(RenderObject node) {
    if (node is T) return node;
    T? found;
    node.visitChildren((child) {
      found ??= _findDescendant<T>(child);
    });
    return found;
  }

  /// Captures the reader's anchor once the frame settles, so the next content
  /// change has a stable id and offset to hold.
  void _scheduleAnchorRefresh() {
    if (_refreshScheduled) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (!mounted || !_hold.paused || !widget.keepPosition) return;
      _refreshAnchor();
    });
  }

  void _refreshAnchor() {
    final sliver = _findSliver();
    final msgs = _hold.msgs;
    final pos = _position;
    if (sliver == null || msgs == null || pos == null || !pos.hasPixels) return;
    final pixels = pos.pixels;
    RenderBox? first;
    for (
      RenderBox? child = sliver.firstChild;
      child != null;
      child = sliver.childAfter(child)
    ) {
      final pd = child.parentData as SliverMultiBoxAdaptorParentData?;
      final offset = pd?.layoutOffset;
      final index = pd?.index;
      if (offset == null ||
          index == null ||
          index < 0 ||
          index >= msgs.length) {
        continue;
      }
      if (offset + child.size.height > pixels) {
        first = child;
        break;
      }
    }
    if (first == null) {
      _hold.anchorId = null;
      return;
    }
    final pd = first.parentData! as SliverMultiBoxAdaptorParentData;
    _hold.anchorId = _rowKey(msgs[pd.index!]);
    _hold.anchorOffset = pd.layoutOffset!;
  }

  Widget _buildTile(
    List<TwitchMessage> msgs,
    Map<String?, Widget>? cache,
    Map<String, int> idToIndex,
    int i,
    Color surface,
    double s,
    BuildContext context,
    bool doCheckered,
  ) {
    final msg = msgs[i];
    // Use the row's own channel for badge/emote resolution.
    final tileChannel = msg.channel ?? widget.channel;

    // DankChat-style: parity assigned once per message via global counter, cached.
    // Cache holds the undimmed tile; dim wraps per build so queries never
    // poison it.
    final cached = cache?[msg.messageId];
    if (cached != null) {
      final id = msg.messageId;
      if (id != null && cache != null) {
        // Touch on use: keep the window centered on what is on screen so
        // eviction drops rows that were scrolled away from, not visible ones.
        cache.remove(id);
        cache[id] = cached;
      }
      return _maybeDim(cached, msg, surface);
    }
    final parity = doCheckered ? (++ChatView._checkerSeq).isEven : i.isEven;

    // System rows take no taps, reply line, paint, or embeds; the tile reads
    // their body from systemBodyBuilder.
    final chatRow = !msg.isSystem;
    final body = ChatMessageTile(
      message: msg,
      channel: tileChannel,
      surface: surface,
      textScale: s,
      showTimestamp: widget.showTimestamp,
      timestampFormat: widget.timestampFormat,
      buildBadgeSpans: widget.messageBuilder.buildBadgeSpans,
      buildMessageSpans: widget.messageBuilder.buildMessageSpans,
      bodyIsCached: widget.messageBuilder.bodyIsCached,
      systemBodyBuilder: (msg, scale) => parseTextWithLinks(
        msg.text,
        linkWhitelist: widget.linkWhitelist?.entries,
        onEmailTap: widget.messageBuilder.onEmailTap,
      ),
      onTapUser: chatRow
          ? (login, userId) => widget.onShowUserProfile(
              login,
              userId,
              displayName: msg.displayName,
            )
          : null,
      onDoubleTapUser: chatRow ? () => _copyUsername(msg) : null,
      onLongPress: chatRow && widget.onShowMessageMenu != null
          ? () => widget.onShowMessageMenu!(msg)
          : null,
      onDoubleTap: chatRow && widget.onCopyMessage != null
          ? () => widget.onCopyMessage!(msg)
          : null,
      replyIndicator:
          chatRow &&
              widget.showReplyIndicators &&
              widget.onFindThreadRoot != null &&
              widget.onShowThreadView != null &&
              msg.replyToUser != null
          ? _buildReplyIndicator(context, msg, s)
          : null,
      checkeredMessages: widget.checkeredMessages,
      highlightOpacity: widget.highlightOpacity,
      lineSeparator: widget.lineSeparator,
      isAlternateBackground: parity,
      fadeDeleted: widget.fadeDeleted,
      sharedChatMode: widget.sharedChatMode,
      showChannel: widget.showChannel,
      paintService: chatRow ? widget.paintService : null,
      showImages: chatRow && widget.messageBuilder.showImages,
      imageHeight: widget.messageBuilder.imageHeight,
      linkWhitelist:
          widget.linkWhitelist?.entries ??
          widget.messageBuilder.linkWhitelist.entries,
    );

    // Key by messageId for rematch on index shifts; cached tiles short-circuit.
    final tile = RepaintBoundary(child: body);
    if (cache != null && msg.messageId != null) {
      cache[msg.messageId!] = tile;
      // Mark the freshly cached row as live for this frame. The eviction check
      // below reads the buffer snapshot taken before this frame, which does not
      // know about the row just inserted; without this it would look stale and
      // be evicted immediately.
      idToIndex[msg.messageId!] = i;
      if (cache.length > ChatView._maxCachedTiles) {
        // Evict a row that left the buffer first, then the least recently used.
        String? stale;
        for (final k in cache.keys) {
          if (k != null && !idToIndex.containsKey(k)) {
            stale = k;
            break;
          }
        }
        cache.remove(stale ?? cache.keys.first);
      }
    }
    return _maybeDim(tile, msg, surface);
  }

  // Search dim mode only; same alpha as the shared-chat fade.
  Widget _maybeDim(Widget tile, TwitchMessage msg, Color surface) {
    if (widget.isDimmed?.call(msg) ?? false) {
      return fadeOver(tile, surface, 0.55);
    }
    return tile;
  }

  // Key by messageId; falls back to an identity key from immutable fields.
  Key _messageKey(TwitchMessage msg) =>
      ValueKey<String>(msg.messageId ?? _anonKey(msg));

  // Stable row identity for end markers and the hold anchor, so a capped
  // buffer with steady length still refreshes its eviction index when the
  // oldest or newest row turns over.
  String _rowKey(TwitchMessage msg) {
    final id = msg.messageId;
    return id != null ? 'msg-$id' : _anonKey(msg);
  }

  static String _anonKey(TwitchMessage msg) =>
      'anon-${msg.timestamp.microsecondsSinceEpoch}-${msg.login}-${msg.text.hashCode}';

  Widget _buildReplyIndicator(
    BuildContext context,
    TwitchMessage msg,
    double scale,
  ) {
    final preview = formatReplyPreview(msg.replyToText ?? '');
    final variant = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 2),
      child: InkWell(
        onTap: () {
          final root = widget.onFindThreadRoot?.call(msg);
          if (root != null) widget.onShowThreadView?.call(root);
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.reply, size: 16 * scale, color: variant),
            SizedBox(width: 4 * scale),
            Flexible(
              child: Text(
                'Replying to @${msg.replyToUser ?? 'unknown'}: $preview',
                style: TextStyle(fontSize: 12 * scale, color: variant),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chat row that pauses its emotes while it sits outside the viewport.
/// Starts enabled so a row built offscreen still decodes its first frame.
class _RowGate extends StatefulWidget {
  const _RowGate({super.key, required this.gates, required this.child});

  final Set<_RowGateState> gates;
  final Widget child;

  @override
  State<_RowGate> createState() => _RowGateState();
}

class _RowGateState extends State<_RowGate> {
  final ValueNotifier<bool> visible = ValueNotifier(true);

  @override
  void initState() {
    super.initState();
    widget.gates.add(this);
  }

  @override
  void didUpdateWidget(_RowGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.gates, widget.gates)) {
      oldWidget.gates.remove(this);
      widget.gates.add(this);
    }
  }

  @override
  void dispose() {
    widget.gates.remove(this);
    visible.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: visible,
    builder: (_, on, child) => TickerMode(enabled: on, child: child!),
    child: widget.child,
  );
}
