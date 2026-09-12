import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import '../third_party/flutter_list_view/flutter_list_view.dart';
import '../models/twitch_message.dart';
import '../util/thread_utils.dart';
import '../services/seven_tv_paint_service.dart';
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
  final FlutterListViewController scrollController;
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
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  double _cachedSystemScale = 1.0;
  int _lastMsgLen = -1;
  Map<String, int> _idToIndex = const {};
  String? _endsFirst;
  String? _endsLast;

  // Stable row builders: plain methods, so the list delegate below keeps
  // its identity across ticks and the fork skips its O(buffered messages)
  // invalidation. All data is read live from widget.messages at call time,
  // so freshness never depends on rebuilds.
  FlutterListViewDelegate? _delegate;
  int? _delegateLen;
  String? _delegateChannel;

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
  void didUpdateWidget(covariant ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.chatFontScale != oldWidget.chatFontScale) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final surface = Theme.of(context).scaffoldBackgroundColor;
    final s = widget.chatFontScale * _cachedSystemScale;
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
                if (msgs.isEmpty) {
                  _lastMsgLen = 0;
                  _idToIndex = const {};
                  _endsFirst = null;
                  _endsLast = null;
                  final emptyMsg = TwitchMessage(
                    login: '',
                    text: widget.emptyText,
                    isSystem: true,
                    channel: widget.channel,
                  );
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: FlutterListView(
                      // Distinct key from the content list below: the fork
                      // reuses row elements across delegate swaps with the
                      // same list key, which grafts the last content tile
                      // onto the empty state (search hide-to-empty).
                      key: ValueKey('${widget.channel}:empty'),
                      controller: widget.scrollController,
                      reverse: true,
                      physics: widget.physics,
                      keyboardDismissBehavior: widget.keyboardDismissBehavior,
                      delegate: FlutterListViewDelegate(
                        (_, i) => _buildTile(
                          [emptyMsg],
                          null,
                          const {},
                          i,
                          surface,
                          s,
                          context,
                          widget.checkeredMessages,
                        ),
                        childCount: 1,
                        onItemKey: (_) => 'empty',
                        keepPosition: true,
                        keepPositionOffset: 0.5,
                        addAutomaticKeepAlives: false,
                        addRepaintBoundaries: false,
                      ),
                    ),
                  );
                }

                final cache = widget.tileCache?.putIfAbsent(
                  widget.channel,
                  () => <String?, Widget>{},
                );

                if (msgs.length != _lastMsgLen ||
                    _rowKey(msgs.first) != _endsFirst ||
                    _rowKey(msgs.last) != _endsLast) {
                  _lastMsgLen = msgs.length;
                  _endsFirst = _rowKey(msgs.first);
                  _endsLast = _rowKey(msgs.last);
                  final idToIndex = <String, int>{};
                  if (cache != null) {
                    final pending = cache.keys.whereType<String>().toSet();
                    for (
                      var i = 0;
                      i < msgs.length && pending.isNotEmpty;
                      i++
                    ) {
                      final id = msgs[i].messageId;
                      if (id != null && pending.remove(id)) {
                        idToIndex[id] = i;
                      }
                    }
                  }
                  _idToIndex = idToIndex;
                }

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: FlutterListView(
                    key: ValueKey(widget.channel),
                    controller: widget.scrollController,
                    reverse: true,
                    physics: widget.physics,
                    keyboardDismissBehavior: widget.keyboardDismissBehavior,
                    delegate: _effectiveDelegate(msgs),
                  ),
                );
              },
            ),
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: widget.atBottomNotifier,
          builder: (_, atBottom, _) {
            return Positioned(
              right: 16,
              bottom: 16,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 100),
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: atBottom
                    ? const SizedBox.shrink()
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

  FlutterListViewDelegate _effectiveDelegate(List<TwitchMessage> msgs) {
    if (_delegate == null ||
        _delegateChannel != widget.channel ||
        _delegateLen != msgs.length) {
      _delegate = FlutterListViewDelegate(
        _buildTileAt,
        childCount: msgs.length,
        onItemKey: _itemKeyAt,
        keepPosition: true,
        keepPositionOffset: 0.5,
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: false,
      );
      _delegateChannel = widget.channel;
      _delegateLen = msgs.length;
    }
    return _delegate!;
  }

  Widget _buildTileAt(BuildContext ctx, int i) {
    final msgs = widget.messages;
    if (i < 0 || i >= msgs.length) return const SizedBox.shrink();
    final cache = widget.tileCache?.putIfAbsent(
      widget.channel,
      () => <String?, Widget>{},
    );
    return _buildTile(
      msgs,
      cache,
      _idToIndex,
      i,
      Theme.of(ctx).scaffoldBackgroundColor,
      widget.chatFontScale * _cachedSystemScale,
      ctx,
      widget.checkeredMessages,
    );
  }

  String _itemKeyAt(int i) {
    final msgs = widget.messages;
    if (i < 0 || i >= msgs.length) return 'oob-$i';
    return _rowKey(msgs[i]);
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
    if (cached != null) return _maybeDim(cached, msg);
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
      if (cache.length > ChatView._maxCachedTiles) {
        // Evict stale (truncated-out) entries first, then oldest.
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
