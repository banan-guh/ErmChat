import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import '../third_party/flutter_list_view/flutter_list_view.dart';
import '../models/twitch_message.dart';
import '../services/seven_tv_paint_service.dart';
import '../util/timestamp_formatter.dart';
import '../util/haptics.dart';
import '../widgets/chat_message_tile.dart';
import '../widgets/emote_text.dart';
import '../widgets/message_builder.dart';

class ChatView extends StatefulWidget {
  // Per-channel tile cache bound, well above the visible viewport so tiles
  // stay cached across message insertions while truncated messages evict.
  static const int _maxCachedTiles = 300;

  /// Global arrival counter for checkered mode: each newly built message
  /// takes the next parity so stripes alternate per message and stay glued
  /// to it instead of re-flowing with index shifts.
  static int _checkerSeq = 0;

  final String channel;
  final List<TwitchMessage> messages;

  /// Per-channel tile cache driving rebuild short-circuits and key-based
  /// reconciliation. Null (panels) builds tiles fresh per notification tick.
  final Map<String, Map<String?, Widget>>? tileCache;
  final ValueNotifier<bool> atBottomNotifier;
  final ValueNotifier<int> messageNotifier;
  final FlutterListViewController scrollController;
  final MessageBuilder messageBuilder;

  /// Opens the profile sheet from a user-name tap.
  final void Function(String login, String? userId, {String? displayName})
  onShowUserProfile;

  /// Null disables the long-press message menu.
  final void Function(TwitchMessage)? onShowMessageMenu;

  /// Notified on scroll-state flips (main chat unread/jump bookkeeping).
  final void Function(String)? onNewMessage;
  final TwitchMessage? Function(TwitchMessage)? onFindThreadRoot;
  final void Function(TwitchMessage)? onShowThreadView;

  /// Reply indicators need both thread callbacks to be tappable; off for
  /// surfaces where every row is a reply (thread panel) or parity demands
  /// the old look.
  final bool showReplyIndicators;
  final String emptyText;
  final ScrollPhysics? physics;

  /// Whether deleted messages render as faded tombstones. Off in the
  /// mentions tab so removed rows stay readable there.
  final bool fadeDeleted;

  /// Disambiguates the scroll-down FAB's hero tag when several views exist
  /// for overlapping channels. Defaults to a [channel]-keyed tag.
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
    this.onNewMessage,
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
    this.highlightOpacity = 1.0,
    this.lineSeparator = false,
    this.sharedChatMode = 'spotlight',
    this.paintService,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  double _cachedSystemScale = 1.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newScale = MediaQuery.textScalerOf(context).scale(1.0);
    if (newScale != _cachedSystemScale) {
      _cachedSystemScale = newScale;
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
                widget.onNewMessage?.call(widget.channel);
              } else if (!scrolledUp && !atBottom) {
                widget.atBottomNotifier.value = true;
                widget.onNewMessage?.call(widget.channel);
              }
            } else if (notification is ScrollEndNotification) {
              if (notification.metrics.pixels <= 0.5 &&
                  !widget.atBottomNotifier.value) {
                widget.atBottomNotifier.value = true;
                widget.onNewMessage?.call(widget.channel);
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
                  return Center(child: Text(widget.emptyText));
                }

                final cache = widget.tileCache?.putIfAbsent(
                  widget.channel,
                  () => <String?, Widget>{},
                );

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

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: FlutterListView(
                    key: ValueKey(widget.channel),
                    controller: widget.scrollController,
                    reverse: true,
                    physics: widget.physics,
                    keyboardDismissBehavior: widget.keyboardDismissBehavior,
                    delegate: FlutterListViewDelegate(
                      (_, i) => _buildTile(
                        msgs,
                        cache,
                        idToIndex,
                        i,
                        surface,
                        s,
                        context,
                        widget.checkeredMessages,
                      ),
                      childCount: msgs.length,
                      onItemKey: (i) {
                        final id = msgs[i].messageId;
                        if (id != null) return 'msg-$id';
                        final m = msgs[i];
                        return 'anon-${m.timestamp.microsecondsSinceEpoch}-${m.login}-${m.text.hashCode}';
                      },
                      keepPosition: true,
                      keepPositionOffset: 0.5,
                      addAutomaticKeepAlives: false,
                      addRepaintBoundaries: false,
                    ),
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
                          widget.onNewMessage?.call(widget.channel);
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
    // Mentions/whisper rows can come from several channels; badges and
    // emotes resolve against the row's own channel when it has one.
    final tileChannel = msg.channel ?? widget.channel;

    // Checkered stripes are assigned once per message and stay glued to it
    // (DankChat's approach): position-based parity re-flows on every
    // arrival, which crawls the pattern with each message. The cache is the
    // "already assigned" record; a global counter guarantees alternation.
    final cached = cache?[msg.messageId];
    if (cached != null) return cached;
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
        systemBodyBuilder: (msg, scale) => parseTextWithLinks(msg.text),
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
        onTapUser: (login, userId) => widget.onShowUserProfile(
          login,
          userId,
          displayName: msg.displayName,
        ),
        onLongPress: widget.onShowMessageMenu == null
            ? null
            : () => widget.onShowMessageMenu!(msg),
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
      );
    }

    // Key the RepaintBoundary (the list's direct child) so elements can be
    // rematched by messageId on index shifts; the cached identical tile
    // then short-circuits instead of recreating its state.
    final tile = RepaintBoundary(key: _messageKey(msg), child: body);
    if (cache != null && msg.messageId != null) {
      cache[msg.messageId!] = tile;
      if (cache.length > ChatView._maxCachedTiles) {
        // Prefer evicting entries for messages that are no longer in the
        // list (truncated out), falling back to the oldest built entry.
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
    return tile;
  }

  // Stable per-message key for tile reconciliation. Real messages key on
  // their messageId; messageId-less messages fall back to an identity key
  // derived from their (immutable) fields.
  Key _messageKey(TwitchMessage msg) {
    final id = msg.messageId;
    if (id != null) return ValueKey<String>(id);
    return ValueKey<String>(
      'anon-${msg.timestamp.microsecondsSinceEpoch}-${msg.login}-${msg.text.hashCode}',
    );
  }

  Widget _buildReplyIndicator(BuildContext context, TwitchMessage msg) {
    final replyPreview = (msg.replyToText ?? '').trimLeft();
    final preview = replyPreview.length > 60
        ? '${replyPreview.substring(0, 60)}...'
        : replyPreview;
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
