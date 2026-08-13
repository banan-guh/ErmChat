import 'package:flutter/material.dart';
import '../models/twitch_message.dart';
import '../util/timestamp_formatter.dart';
import '../widgets/chat_message_tile.dart';
import '../widgets/emote_text.dart';
import '../widgets/message_builder.dart';

class ChatView extends StatelessWidget {
  // Per-channel tile cache bound, well above the default max-messages-per-
  // channel (200) so visible tiles always stay cached while old truncated
  // messages evict.
  static const int _maxCachedTiles = 300;

  final String channel;
  final List<TwitchMessage> messages;
  final Map<String, List<TwitchMessage>> frozenSnapshot;
  final Map<String, Map<String?, Widget>> tileCache;
  final ValueNotifier<bool> atBottomNotifier;
  final ValueNotifier<int> messageNotifier;
  final ScrollController scrollController;
  final MessageBuilder messageBuilder;
  final void Function(String login, String? userId, {String? displayName})
  onShowUserProfile;
  final void Function(TwitchMessage) onShowMessageMenu;
  final void Function(String) onNewMessage;
  final TwitchMessage? Function(TwitchMessage) onFindThreadRoot;
  final void Function(TwitchMessage) onShowThreadView;
  final bool showTimestamp;
  final String timestampFormat;

  const ChatView({
    super.key,
    required this.channel,
    required this.messages,
    required this.frozenSnapshot,
    required this.tileCache,
    required this.atBottomNotifier,
    required this.messageNotifier,
    required this.scrollController,
    required this.messageBuilder,
    required this.onShowUserProfile,
    required this.onShowMessageMenu,
    required this.onNewMessage,
    required this.onFindThreadRoot,
    required this.onShowThreadView,
    this.showTimestamp = true,
    this.timestampFormat = kDefaultTimestampFormat,
  });

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final systemScale = MediaQuery.textScalerOf(context).scale(1.0);
    final s = 1.0 * systemScale;

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollUpdateNotification) {
              final scrolledUp = notification.metrics.pixels > 50.0;
              final atBottom = atBottomNotifier.value;
              if (scrolledUp && atBottom) {
                atBottomNotifier.value = false;
                frozenSnapshot[channel] = List.of(messages);
                onNewMessage(channel);
              } else if (!scrolledUp && !atBottom) {
                atBottomNotifier.value = true;
                frozenSnapshot.remove(channel);
                onNewMessage(channel);
              }
            }
            return false;
          },
          child: ScrollbarTheme(
            data: const ScrollbarThemeData(
              thickness: WidgetStatePropertyAll(0),
            ),
            child: ValueListenableBuilder<int>(
              valueListenable: messageNotifier,
              builder: (_, _, _) {
                final msgs = frozenSnapshot[channel] ?? messages;
                if (msgs.isEmpty) {
                  return const Center(child: Text('No messages yet'));
                }

                final cache = tileCache.putIfAbsent(
                  channel,
                  () => <String?, Widget>{},
                );

                final idToIndex = <String, int>{};
                for (var i = 0; i < msgs.length; i++) {
                  final id = msgs[i].messageId;
                  if (id != null) idToIndex[id] = i;
                }

                return ListView.builder(
                  key: ValueKey(channel),
                  controller: scrollController,
                  reverse: true,
                  // Reserve the nav-bar inset as a constant scroll padding so
                  // there is always a visible gap between the last message and
                  // the type bar. Using viewPadding (not the ShrinkWrap
                  // implicit padding) keeps the gap identical whether the
                  // keyboard is up or down.
                  padding: EdgeInsets.only(
                    bottom: 8, //MediaQuery.viewPaddingOf(context).bottom,
                  ),
                  itemCount: msgs.length,
                  // Key-based reconciliation: when a message is inserted at
                  // the top, existing elements are matched by their
                  // messageId key instead of by index, so the cached
                  // identical tile widgets short-circuit and only the new
                  // message's tile is built/layout/painted.
                  findChildIndexCallback: (key) {
                    if (key is ValueKey<String>) return idToIndex[key.value];
                    return null;
                  },
                  itemBuilder: (_, i) {
                    final msg = msgs[i];

                    final cached = cache[msg.messageId];
                    if (cached != null) return cached;

                    final Widget body;
                    if (msg.isSystem) {
                      body = ChatMessageTile(
                        key: _messageKey(msg),
                        message: msg,
                        channel: channel,
                        surface: surface,
                        textScale: s,
                        showTimestamp: showTimestamp,
                        timestampFormat: timestampFormat,
                        buildBadgeSpans: messageBuilder.buildBadgeSpans,
                        buildMessageSpans: messageBuilder.buildMessageSpans,
                        systemBodyBuilder: (msg, scale) =>
                            parseTextWithLinks(msg.text),
                      );
                    } else {
                      body = ChatMessageTile(
                        key: _messageKey(msg),
                        message: msg,
                        channel: channel,
                        surface: surface,
                        textScale: s,
                        showTimestamp: showTimestamp,
                        timestampFormat: timestampFormat,
                        buildBadgeSpans: messageBuilder.buildBadgeSpans,
                        buildMessageSpans: messageBuilder.buildMessageSpans,
                        onTapUser: (login, userId) => onShowUserProfile(
                          login,
                          userId,
                          displayName: msg.displayName,
                        ),
                        onLongPress: () => onShowMessageMenu(msg),
                        replyIndicator: msg.replyToUser != null
                            ? _buildReplyIndicator(context, msg)
                            : null,
                      );
                    }

                    // Cache the RepaintBoundary-wrapped tile so paint
                    // isolation survives across rebuilds and the identical
                    // instance short-circuits element updates.
                    final tile = RepaintBoundary(child: body);
                    if (msg.messageId != null) {
                      cache[msg.messageId!] = tile;
                      if (cache.length > _maxCachedTiles) {
                        // Prefer evicting entries for messages that are no
                        // longer in the list (truncated out), falling back
                        // to the oldest built entry.
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
                  },
                );
              },
            ),
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: atBottomNotifier,
          builder: (_, atBottom, _) {
            if (atBottom) return const SizedBox.shrink();
            return Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton(
                heroTag: 'scroll_down_$channel',
                onPressed: () {
                  atBottomNotifier.value = true;
                  frozenSnapshot.remove(channel);
                  scrollController.jumpTo(0);
                  onNewMessage(channel);
                },
                child: const Icon(Icons.keyboard_arrow_down),
              ),
            );
          },
        ),
      ],
    );
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
    final replyPreview = msg.replyToText ?? '';
    final preview = replyPreview.length > 60
        ? '${replyPreview.substring(0, 60)}...'
        : replyPreview;
    final variant = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 2),
      child: GestureDetector(
        onTap: () {
          final root = onFindThreadRoot(msg);
          if (root != null) onShowThreadView(root);
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
