import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/twitch_message.dart';
import '../util/timestamp_formatter.dart';
import '../widgets/chat_message_tile.dart';

class MentionsPanelWidget extends StatefulWidget {
  final ScrollController scrollController;
  final ValueListenable<List<TwitchMessage>?> messages;
  final double chatFontScale;
  final List<WidgetSpan> Function(String, TwitchMessage, {double badgeScale})
  buildBadgeSpans;
  final List<InlineSpan> Function(
    TwitchMessage,
    String,
    Color, {
    bool colored,
    double textScale,
  })
  buildMessageSpans;
  final String emptyText;
  final bool showTimestamp;
  final String timestampFormat;
  final bool checkeredMessages;
  final bool lineSeparator;
  final String sharedChatMode;

  const MentionsPanelWidget({
    required this.scrollController,
    required this.messages,
    required this.chatFontScale,
    required this.buildBadgeSpans,
    required this.buildMessageSpans,
    this.emptyText = 'No mentions or whispers',
    this.showTimestamp = true,
    this.timestampFormat = kDefaultTimestampFormat,
    this.checkeredMessages = false,
    this.lineSeparator = false,
    this.sharedChatMode = 'spotlight',
    super.key,
  });

  @override
  State<MentionsPanelWidget> createState() => MentionsPanelWidgetState();
}

class MentionsPanelWidgetState extends State<MentionsPanelWidget> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface;
    final systemScale = MediaQuery.textScalerOf(context).scale(1.0);
    final s = widget.chatFontScale * systemScale;

    return ValueListenableBuilder<List<TwitchMessage>?>(
      valueListenable: widget.messages,
      builder: (_, messages, _) {
        if (messages == null) return const SizedBox.shrink();
        final messageList = messages;

        if (messageList.isEmpty) {
          return CustomScrollView(
            controller: widget.scrollController,
            physics: const ClampingScrollPhysics(),
            slivers: [
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text(widget.emptyText)),
              ),
            ],
          );
        }

        return ListView.builder(
          controller: widget.scrollController,
          physics: const ClampingScrollPhysics(),
          reverse: true,
          padding: const EdgeInsets.only(bottom: 8),
          itemCount: messageList.length,
          itemBuilder: (_, i) {
            final msg = messageList[i];
            final channel = msg.channel ?? '';

            if (msg.isSystem) {
              return ChatMessageTile(
                message: msg,
                channel: channel,
                surface: surface,
                textScale: s,
                showTimestamp: widget.showTimestamp,
                timestampFormat: widget.timestampFormat,
                buildBadgeSpans: widget.buildBadgeSpans,
                buildMessageSpans: widget.buildMessageSpans,
                checkeredMessages: widget.checkeredMessages,
                lineSeparator: widget.lineSeparator,
                isAlternateBackground: i.isEven,
                sharedChatMode: widget.sharedChatMode,
              );
            }

            return ChatMessageTile(
              message: msg,
              channel: channel,
              surface: surface,
              textScale: s,
              showTimestamp: widget.showTimestamp,
              timestampFormat: widget.timestampFormat,
              buildBadgeSpans: widget.buildBadgeSpans,
              buildMessageSpans: widget.buildMessageSpans,
              checkeredMessages: widget.checkeredMessages,
              lineSeparator: widget.lineSeparator,
              isAlternateBackground: i.isEven,
              sharedChatMode: widget.sharedChatMode,
            );
          },
        );
      },
    );
  }
}
