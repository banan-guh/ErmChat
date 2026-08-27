import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../../util/constants.dart';
import '../../widgets/join_channel_dialog.dart';

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
    showJoinChannelDialog(context, onJoin: (c) => widget.onAddChannel?.call(c));
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
              child: Text('No channels joined'),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: channels.length,
              onReorderItem: (oldIndex, newIndex) {
                final reordered = List.of(channels);
                final item = reordered.removeAt(oldIndex);
                reordered.insert(newIndex, item);
                widget.onReorderChannels?.call(reordered);
              },
              proxyDecorator: _proxyDecorator,
              itemBuilder: (_, i) => _ReorderableChannelTile(
                key: ValueKey(channels[i]),
                index: i,
                channel: channels[i],
                onLeave: (c) => widget.onLeaveChannel?.call(c),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: OutlinedButton.icon(
              onPressed: channels.length >= kMaxChannels
                  ? null
                  : _addChannelDialog,
              icon: const Icon(Icons.add),
              label: const Text('Join channel'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _proxyDecorator(Widget child, int index, Animation<double> animation) {
    final t = Curves.easeInOut.transform(animation.value);
    return Material(
      color: Color.lerp(
        Theme.of(context).colorScheme.surface,
        Theme.of(context).colorScheme.primary,
        0.08 * t,
      ),
      elevation: 4 + 6 * t,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Transform.scale(scale: 1.0 + 0.02 * t, child: child),
    );
  }
}

class _ReorderableChannelTile extends StatefulWidget {
  final int index;
  final String channel;
  final ValueChanged<String>? onLeave;

  const _ReorderableChannelTile({
    super.key,
    required this.index,
    required this.channel,
    this.onLeave,
  });

  @override
  State<_ReorderableChannelTile> createState() =>
      _ReorderableChannelTileState();
}

class _ReorderableChannelTileState extends State<_ReorderableChannelTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _charge = AnimationController(
    vsync: this,
    duration: kLongPressTimeout,
  );

  @override
  void dispose() {
    _charge.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details) {
    _charge.forward();
  }

  void _onTapEnd() {
    if (_charge.isAnimating || _charge.value > 0) {
      _charge.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ReorderableDelayedDragStartListener(
      index: widget.index,
      child: GestureDetector(
        onTapDown: _onTapDown,
        onTapUp: (_) => _onTapEnd(),
        onTapCancel: _onTapEnd,
        child: Stack(
          children: [
            ListTile(
              leading: const Icon(Icons.drag_handle),
              title: Text(widget.channel),
              onTap: () {},
              trailing: IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () => widget.onLeave?.call(widget.channel),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _charge,
                  builder: (context, _) => DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color.lerp(
                        Colors.transparent,
                        Colors.white,
                        Curves.easeOut.transform(_charge.value) * 0.35,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
