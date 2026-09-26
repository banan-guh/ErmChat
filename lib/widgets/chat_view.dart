import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:scrollview_observer/scrollview_observer.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../models/twitch_message.dart';
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

  /// Glass overlay clearance below the newest row, above the composer pill.
  /// Zero falls back to the GlassChromeScope clearance, so panel and welcome
  /// lists clear the floating pill without threaded params.
  final double bottomOverlayPadding;

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
    this.bottomOverlayPadding = 0,
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

/// Restores the framework default for [ScrollPhysics.shouldAcceptUserOffset].
///
/// The upstream chat physics forces `true`, which keeps the list's drag
/// recognizer registered even when it cannot scroll. On a short channel that
/// recognizer swallows horizontal pager swipes, so channel switching breaks.
/// Re-applying the default lets the pager win when the list has nothing to
/// scroll.
mixin _FrameworkUserOffset on ScrollPhysics {
  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) {
    if (!allowUserScrolling) return false;
    final p = parent;
    if (p == null) {
      return position.pixels != 0.0 ||
          position.minScrollExtent != position.maxScrollExtent;
    }
    return p.shouldAcceptUserOffset(position);
  }
}

class _ChatAnchorClampingPhysics extends ChatObserverClampingScrollPhysics
    with _FrameworkUserOffset {
  _ChatAnchorClampingPhysics({super.parent, required super.observer});

  @override
  _ChatAnchorClampingPhysics applyTo(ScrollPhysics? ancestor) =>
      _ChatAnchorClampingPhysics(
        parent: buildParent(ancestor),
        observer: observer,
      );
}

class _ChatAnchorBouncingPhysics extends ChatObserverBouncingScrollPhysics
    with _FrameworkUserOffset {
  _ChatAnchorBouncingPhysics({super.parent, required super.observer});

  @override
  _ChatAnchorBouncingPhysics applyTo(ScrollPhysics? ancestor) =>
      _ChatAnchorBouncingPhysics(
        parent: buildParent(ancestor),
        observer: observer,
      );
}

class _ChatViewState extends State<ChatView>
    with AutomaticKeepAliveClientMixin {
  /// Above this many rows prepended in one tick the anchor can fall outside the
  /// cache area, so hold is skipped and the list is left to settle.
  static const int _maxHoldBatch = 64;

  @override
  bool get wantKeepAlive => widget.keepAlive;
  double _cachedSystemScale = 1.0;
  int _lastMsgLen = -1;
  Map<String, int> _idToIndex = {};
  String? _endsFirst;
  String? _endsLast;

  // Anchoring bridge: ListViewObserver feeds ChatScrollObserver, whose physics
  // keeps the row under the reader pinned when earlier rows are inserted.
  ListObserverController? _observerController;
  ChatScrollObserver? _chatObserver;
  ScrollController? _observerScrollController;

  // Snapshot of the previous tick used to measure head shifts.
  int _prevLen = -1;
  String? _prevHead;
  bool _hasSnapshot = false;

  // Effective pill clearance for this frame: the explicit prop wins, zero
  // falls back to the scope so surfaces without threaded params (welcome,
  // panels) still clear the floating pill. Set at the top of every build.
  double _effBottom = 0;

  @override
  void initState() {
    super.initState();
    _ensureObservers();
  }

  @override
  void didUpdateWidget(covariant ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.chatFontScale != oldWidget.chatFontScale) {
      setState(() {});
    }
    if (widget.scrollController != oldWidget.scrollController) {
      _ensureObservers();
    }
  }

  void _ensureObservers() {
    if (identical(_observerScrollController, widget.scrollController)) return;
    _observerScrollController = widget.scrollController;
    _observerController = ListObserverController(
      controller: widget.scrollController,
    )..cacheJumpIndexOffset = false;
    _chatObserver = ChatScrollObserver(_observerController!)
      ..fixedPositionOffset = 8;
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
    _effBottom = widget.bottomOverlayPadding > 0.5
        ? widget.bottomOverlayPadding
        : (GlassChromeScope.maybeOf(context)?.bottomClearance ?? 0);
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollUpdateNotification) {
              final scrolledUp = notification.metrics.pixels > 0.5;
              final atBottom = widget.atBottomNotifier.value;
              if (scrolledUp && atBottom) {
                widget.atBottomNotifier.value = false;
                widget.onScrollActivity?.call(widget.channel);
              } else if (!scrolledUp && !atBottom) {
                widget.atBottomNotifier.value = true;
                widget.onScrollActivity?.call(widget.channel);
              }
            } else if (notification is ScrollEndNotification) {
              if (notification.metrics.pixels <= 0.5 &&
                  !widget.atBottomNotifier.value) {
                widget.atBottomNotifier.value = true;
                widget.onScrollActivity?.call(widget.channel);
              }
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
                return _buildList(context, msgs, surface, s);
              },
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
                          widget.atBottomNotifier.value = true;
                          widget.scrollController.jumpTo(0);
                          widget.onScrollActivity?.call(widget.channel);
                        },
                        useOwnLayer: true,
                        quality: GlassQuality.premium,
                      )
                    : FloatingActionButton(
                        key: const ValueKey('scroll_down'),
                        heroTag:
                            widget.scrollFabHeroTag ??
                            'scroll_down_${widget.channel}',
                        onPressed: () {
                          iosHaptic(HapticFeedback.lightImpact);
                          widget.atBottomNotifier.value = true;
                          widget.scrollController.jumpTo(0);
                          widget.onScrollActivity?.call(widget.channel);
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
    final empty = msgs.isEmpty;
    if (!empty) {
      final cache = widget.tileCache?.putIfAbsent(
        widget.channel,
        () => <String?, Widget>{},
      );
      _refreshIndexMap(msgs, cache);
      return ListViewObserver(
        controller: _observerController!,
        child: ListView.builder(
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
            bottom: _effBottom,
          ),
          keyboardDismissBehavior: widget.keyboardDismissBehavior,
          itemCount: msgs.length,
          findChildIndexCallback: _findChildIndex,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: false,
          addSemanticIndexes: false,
          itemBuilder: (ctx, i) => _buildTile(
            msgs,
            cache,
            _idToIndex,
            i,
            surface,
            s,
            ctx,
            widget.checkeredMessages,
          ),
        ),
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
    return ListViewObserver(
      controller: _observerController!,
      child: ListView.builder(
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
      ),
    );
  }

  ScrollPhysics _scrollPhysics() {
    final observer = _chatObserver!;
    final anchor = defaultTargetPlatform == TargetPlatform.iOS
        ? _ChatAnchorBouncingPhysics(observer: observer)
        : _ChatAnchorClampingPhysics(observer: observer);
    return anchor.applyTo(widget.physics);
  }

  /// Rebuilds the cached-id to index map so element reuse follows shifted rows.
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

  int? _findChildIndex(Key key) {
    if (key is ValueKey<String>) return _idToIndex[key.value];
    return null;
  }

  /// Measures head arrivals since the last tick and hands the count to the
  /// chat observer so it can hold the reader's row. History merges land at the
  /// tail and leave the head alone, so they need no hold.
  void _syncHold(List<TwitchMessage> msgs) {
    final observer = _chatObserver;
    if (observer == null) return;
    final len = msgs.length;
    final head = len == 0 ? null : _rowKey(msgs.first);
    if (!_hasSnapshot) {
      _prevLen = len;
      _prevHead = head;
      _hasSnapshot = true;
      return;
    }
    if (widget.keepPosition && len > _prevLen && _prevHead != null) {
      final shifted = _headShift(msgs);
      if (shifted > 0 && shifted <= _maxHoldBatch) {
        unawaited(observer.standby(changeCount: shifted));
      }
    } else if (len < _prevLen) {
      unawaited(observer.standby(isRemove: true));
    }
    _prevLen = len;
    _prevHead = head;
  }

  /// Index the previous head moved to, or -1 when it left the window.
  int _headShift(List<TwitchMessage> msgs) {
    final prev = _prevHead!;
    final limit = msgs.length < _maxHoldBatch + 1
        ? msgs.length
        : _maxHoldBatch + 1;
    for (var i = 0; i < limit; i++) {
      if (_rowKey(msgs[i]) == prev) return i;
    }
    return -1;
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
      return _maybeDim(cached, msg);
    }
    final parity = doCheckered ? (++ChatView._checkerSeq).isEven : i.isEven;

    final Widget body;
    if (msg.isSystem) {
      body = ChatMessageTile(
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
        checkeredMessages: widget.checkeredMessages,
        highlightOpacity: widget.highlightOpacity,
        lineSeparator: widget.lineSeparator,
        isAlternateBackground: parity,
        fadeDeleted: widget.fadeDeleted,
        sharedChatMode: widget.sharedChatMode,
      );
    } else {
      body = ChatMessageTile(
        message: msg,
        channel: tileChannel,
        surface: surface,
        textScale: s,
        showTimestamp: widget.showTimestamp,
        timestampFormat: widget.timestampFormat,
        buildBadgeSpans: widget.messageBuilder.buildBadgeSpans,
        buildMessageSpans: widget.messageBuilder.buildMessageSpans,
        bodyIsCached: widget.messageBuilder.bodyIsCached,
        onTapUser: (login, userId) => widget.onShowUserProfile(
          login,
          userId,
          displayName: msg.displayName,
        ),
        onLongPress: widget.onShowMessageMenu == null
            ? null
            : () => widget.onShowMessageMenu!(msg),
        onDoubleTap: widget.onCopyMessage == null
            ? null
            : () => widget.onCopyMessage!(msg),
        replyIndicator:
            widget.showReplyIndicators &&
                widget.onFindThreadRoot != null &&
                widget.onShowThreadView != null &&
                msg.replyToUser != null
            ? _buildReplyIndicator(context, msg)
            : null,
        checkeredMessages: widget.checkeredMessages,
        highlightOpacity: widget.highlightOpacity,
        lineSeparator: widget.lineSeparator,
        isAlternateBackground: parity,
        fadeDeleted: widget.fadeDeleted,
        sharedChatMode: widget.sharedChatMode,
        paintService: widget.paintService,
        showImages: widget.messageBuilder.showImages,
        imageHeight: widget.messageBuilder.imageHeight,
        linkWhitelist:
            widget.linkWhitelist?.entries ??
            widget.messageBuilder.linkWhitelist.entries,
      );
    }

    // Key by messageId for rematch on index shifts; cached tiles short-circuit.
    final tile = RepaintBoundary(key: _messageKey(msg), child: body);
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
    return _maybeDim(tile, msg);
  }

  // Search dim mode only; same alpha as the shared-chat fade.
  Widget _maybeDim(Widget tile, TwitchMessage msg) {
    if (widget.isDimmed?.call(msg) ?? false) {
      return Opacity(opacity: 0.55, child: tile);
    }
    return tile;
  }

  // Key by messageId; falls back to an identity key from immutable fields.
  Key _messageKey(TwitchMessage msg) {
    final id = msg.messageId;
    if (id != null) return ValueKey<String>(id);
    return ValueKey<String>(
      'anon-${msg.timestamp.microsecondsSinceEpoch}-${msg.login}-${msg.text.hashCode}',
    );
  }

  // Stable row identity for end markers. Mirrors the onItemKey logic so a
  // capped buffer with steady length still refreshes its eviction index
  // when the oldest or newest row turns over.
  String _rowKey(TwitchMessage msg) {
    final id = msg.messageId;
    if (id != null) return 'msg-$id';
    return 'anon-${msg.timestamp.microsecondsSinceEpoch}-${msg.login}-${msg.text.hashCode}';
  }

  Widget _buildReplyIndicator(BuildContext context, TwitchMessage msg) {
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
            Icon(Icons.subdirectory_arrow_right, size: 14, color: variant),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                'replying to ${msg.replyToUser ?? 'unknown'}: $preview',
                style: TextStyle(fontSize: 11, color: variant),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
