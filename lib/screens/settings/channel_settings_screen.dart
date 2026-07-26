import 'package:flutter/material.dart';

class ChannelSettingsScreen extends StatefulWidget {
  final ValueNotifier<List<String>> channelNotifier;
  final ValueChanged<String>? onAddChannel;
  final ValueChanged<String>? onLeaveChannel;
  final ValueChanged<List<String>>? onReorderChannels;

  const ChannelSettingsScreen({
    super.key,
    required this.channelNotifier,
    this.onAddChannel,
    this.onLeaveChannel,
    this.onReorderChannels,
  });

  @override
  State<ChannelSettingsScreen> createState() => _ChannelSettingsScreenState();
}

class _ChannelSettingsScreenState extends State<ChannelSettingsScreen> {
  @override
  void initState() {
    super.initState();
    widget.channelNotifier.addListener(_onChannelsChanged);
  }

  @override
  void dispose() {
    widget.channelNotifier.removeListener(_onChannelsChanged);
    super.dispose();
  }

  void _onChannelsChanged() {
    if (mounted) setState(() {});
  }

  void _addChannelDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join channel'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'channel name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (_) {
            final text = controller.text;
            Navigator.pop(ctx);
            widget.onAddChannel?.call(text);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text;
              Navigator.pop(ctx);
              widget.onAddChannel?.call(text);
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final channels = widget.channelNotifier.value;

    return Scaffold(
      appBar: AppBar(title: const Text('Channels')),
      body: ListView(
        children: [
          if (channels.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              child: Text(
                'No channels joined',
                style: TextStyle(color: Colors.grey),
              ),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: channels.length,
              onReorderItem: (oldIndex, newIndex) {
                final reordered = List.of(channels);
                final item = reordered.removeAt(oldIndex);
                reordered.insert(newIndex, item);
                widget.onReorderChannels?.call(reordered);
              },
              itemBuilder: (_, i) => ListTile(
                key: ValueKey(channels[i]),
                leading: const Icon(Icons.drag_handle),
                title: Text(channels[i]),
                trailing: IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => widget.onLeaveChannel?.call(channels[i]),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: OutlinedButton.icon(
              onPressed: _addChannelDialog,
              icon: const Icon(Icons.add),
              label: const Text('Join channel'),
            ),
          ),
        ],
      ),
    );
  }
}
