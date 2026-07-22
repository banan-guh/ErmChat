import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/twitch_message.dart';
import '../widgets/chat_message_tile.dart';

class ThreadPanelData {
  final TwitchMessage root;
  final List<TwitchMessage> messages;
  final String channel;
  ThreadPanelData({
    required this.root,
    required this.messages,
    required this.channel,
  });
}

class ThreadPanelWidget extends StatefulWidget {
  final ScrollController scrollController;
  final ValueListenable<ThreadPanelData?> data;
  final double uiScale;
  final VoidCallback onClose;
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

  const ThreadPanelWidget({
    required this.scrollController,
    required this.data,
    required this.uiScale,
    required this.onClose,
    required this.onLongPress,
    required this.buildBadgeSpans,
    required this.buildMessageSpans,
    super.key,
  });

  @override
  State<ThreadPanelWidget> createState() => ThreadPanelWidgetState();
}

class ThreadPanelWidgetState extends State<ThreadPanelWidget> {
  ThreadPanelData? _data;

  @override
  void initState() {
    super.initState();
    _data = widget.data.value;
    widget.data.addListener(_onDataChanged);
  }

  @override
  void didUpdateWidget(ThreadPanelWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data != oldWidget.data) {
      oldWidget.data.removeListener(_onDataChanged);
      widget.data.addListener(_onDataChanged);
      _data = widget.data.value;
    }
  }

  @override
  void dispose() {
    widget.data.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    setState(() {
      _data = widget.data.value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface;
    final systemScale = MediaQuery.textScalerOf(context).scale(1.0);
    final s = widget.uiScale * systemScale;

    if (_data == null) return const SizedBox.shrink();

    final threadMsgs = _data!.messages;

    return Material(
      color: theme.scaffoldBackgroundColor,
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close reply thread',
                    onPressed: widget.onClose,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Reply Thread',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: theme.dividerColor),
          Expanded(
            child: threadMsgs.isEmpty
                ? ListView(
                    controller: widget.scrollController,
                    padding: const EdgeInsets.only(bottom: 8),
                    children: const [
                      Center(child: Text('No messages found')),
                    ],
                  )
                : ListView.builder(
                    controller: widget.scrollController,
                    physics: const ClampingScrollPhysics(),
                    reverse: true,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: threadMsgs.length,
                    itemBuilder: (_, i) {
                      final msg = threadMsgs[threadMsgs.length - 1 - i];

                      if (msg.isSystem) {
                        return ChatMessageTile(
                          message: msg,
                          channel: _data!.channel,
                          surface: surface,
                          textScale: s,
                          buildBadgeSpans: widget.buildBadgeSpans,
                          buildMessageSpans: widget.buildMessageSpans,
                        );
                      }

                      return ChatMessageTile(
                        message: msg,
                        channel: _data!.channel,
                        surface: surface,
                        textScale: s,
                        buildBadgeSpans: widget.buildBadgeSpans,
                        buildMessageSpans: widget.buildMessageSpans,
                        onLongPress: () => widget.onLongPress(msg),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
