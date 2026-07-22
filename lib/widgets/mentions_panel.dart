import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/twitch_message.dart';
import '../widgets/chat_message_tile.dart';

class MentionsPanelWidget extends StatefulWidget {
  final ScrollController scrollController;
  final ValueListenable<List<TwitchMessage>?> messages;
  final double uiScale;
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

  const MentionsPanelWidget({
    required this.scrollController,
    required this.messages,
    required this.uiScale,
    required this.buildBadgeSpans,
    required this.buildMessageSpans,
    super.key,
  });

  @override
  State<MentionsPanelWidget> createState() => MentionsPanelWidgetState();
}

class MentionsPanelWidgetState extends State<MentionsPanelWidget> {
  List<TwitchMessage>? _messages;

  @override
  void initState() {
    super.initState();
    _messages = widget.messages.value;
    widget.messages.addListener(_onDataChanged);
  }

  @override
  void didUpdateWidget(MentionsPanelWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.messages != oldWidget.messages) {
      oldWidget.messages.removeListener(_onDataChanged);
      widget.messages.addListener(_onDataChanged);
      _messages = widget.messages.value;
    }
  }

  @override
  void dispose() {
    widget.messages.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    setState(() {
      _messages = widget.messages.value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface;
    final systemScale = MediaQuery.textScalerOf(context).scale(1.0);
    final s = widget.uiScale * systemScale;

    final messageList = _messages ?? [];

    if (_messages == null) return const SizedBox.shrink();

    if (messageList.isEmpty) {
      return CustomScrollView(
        controller: widget.scrollController,
        physics: const BouncingScrollPhysics(),
        slivers: const [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('No mentions or whispers')),
          ),
        ],
      );
    }

    return ListView.builder(
      controller: widget.scrollController,
      physics: const BouncingScrollPhysics(),
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
            buildBadgeSpans: widget.buildBadgeSpans,
            buildMessageSpans: widget.buildMessageSpans,
          );
        }

        return ChatMessageTile(
          message: msg,
          channel: channel,
          surface: surface,
          textScale: s,
          buildBadgeSpans: widget.buildBadgeSpans,
          buildMessageSpans: widget.buildMessageSpans,
        );
      },
    );
  }
}
