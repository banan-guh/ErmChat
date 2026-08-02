import 'package:flutter/material.dart';
import '../models/twitch_message.dart';
import '../widgets/chat_message_tile.dart';
import '../widgets/emote_text.dart';
import '../widgets/message_builder.dart';

class ChatView extends StatelessWidget {
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

                return ListView.builder(
                  key: ValueKey(channel),
                  controller: scrollController,
                  reverse: true,
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final msg = msgs[i];

                    final cached = cache[msg.messageId];
                    if (cached != null) return cached;

                    final Widget body;
                    if (msg.isSystem) {
                      body = ChatMessageTile(
                        key: ValueKey(msg.messageId),
                        message: msg,
                        channel: channel,
                        surface: surface,
                        textScale: s,
                        buildBadgeSpans: messageBuilder.buildBadgeSpans,
                        buildMessageSpans: messageBuilder.buildMessageSpans,
                        systemBodyBuilder: (msg, scale) {
                          final accent = msg.systemAccent;
                          if (accent == null) {
                            return parseTextWithLinks(msg.text);
                          }
                          return <InlineSpan>[
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: accent,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  msg.text,
                                  style: TextStyle(
                                    fontSize: 13 * scale,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                              ),
                            ),
                          ];
                        },
                      );
                    } else {
                      body = ChatMessageTile(
                        key: ValueKey(msg.messageId),
                        message: msg,
                        channel: channel,
                        surface: surface,
                        textScale: s,
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

                    if (msg.messageId != null) {
                      cache[msg.messageId!] = body;
                    }
                    return RepaintBoundary(child: body);
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

  Widget _buildReplyIndicator(BuildContext context, TwitchMessage msg) {
    final replyPreview = msg.replyToText ?? '';
    final preview = replyPreview.length > 60
        ? '${replyPreview.substring(0, 60)}…'
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
