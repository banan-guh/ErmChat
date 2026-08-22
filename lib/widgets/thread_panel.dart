import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/twitch_message.dart';
import '../util/timestamp_formatter.dart';
import '../widgets/chat_message_tile.dart';

class ThreadPanelData {
  final List<TwitchMessage> messages;
  final String channel;
  ThreadPanelData({required this.messages, required this.channel});
}

class ThreadPanelWidget extends StatefulWidget {
  final ScrollController scrollController;
  final ValueListenable<ThreadPanelData?> data;
  final double chatFontScale;
  final void Function(TwitchMessage) onLongPress;
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
  final bool showTimestamp;
  final String timestampFormat;
  final bool checkeredMessages;
  final bool lineSeparator;

  const ThreadPanelWidget({
    required this.scrollController,
    required this.data,
    required this.chatFontScale,
    required this.onLongPress,
    required this.buildBadgeSpans,
    required this.buildMessageSpans,
    this.showTimestamp = true,
    this.timestampFormat = kDefaultTimestampFormat,
    this.checkeredMessages = false,
    this.lineSeparator = false,
    super.key,
  });

  @override
  State<ThreadPanelWidget> createState() => ThreadPanelWidgetState();
}

class ThreadPanelWidgetState extends State<ThreadPanelWidget> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface;
    final systemScale = MediaQuery.textScalerOf(context).scale(1.0);
    final s = widget.chatFontScale * systemScale;

    return ValueListenableBuilder<ThreadPanelData?>(
      valueListenable: widget.data,
      builder: (_, data, _) {
        if (data == null) return const SizedBox.shrink();

        final threadMsgs = data.messages;
        if (threadMsgs.isEmpty) {
          return ListView(
            controller: widget.scrollController,
            padding: const EdgeInsets.only(bottom: 8),
            children: const [Center(child: Text('No messages found'))],
          );
        }

        return ListView.builder(
          controller: widget.scrollController,
          reverse: true,
          padding: const EdgeInsets.only(bottom: 8),
          itemCount: threadMsgs.length,
          itemBuilder: (_, i) {
            final msg = threadMsgs[threadMsgs.length - 1 - i];

            if (msg.isSystem) {
              return ChatMessageTile(
                message: msg,
                channel: data.channel,
                surface: surface,
                textScale: s,
                showTimestamp: widget.showTimestamp,
                timestampFormat: widget.timestampFormat,
                buildBadgeSpans: widget.buildBadgeSpans,
                buildMessageSpans: widget.buildMessageSpans,
                checkeredMessages: widget.checkeredMessages,
                lineSeparator: widget.lineSeparator,
                isAlternateBackground: (threadMsgs.length - 1 - i).isEven,
              );
            }

            return ChatMessageTile(
              message: msg,
              channel: data.channel,
              surface: surface,
              textScale: s,
              showTimestamp: widget.showTimestamp,
              timestampFormat: widget.timestampFormat,
              buildBadgeSpans: widget.buildBadgeSpans,
              buildMessageSpans: widget.buildMessageSpans,
              onLongPress: () => widget.onLongPress(msg),
              checkeredMessages: widget.checkeredMessages,
              lineSeparator: widget.lineSeparator,
              isAlternateBackground: (threadMsgs.length - 1 - i).isEven,
            );
          },
        );
      },
    );
  }
}
