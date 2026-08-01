import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/generic_emote.dart';

class EmoteSheet extends StatefulWidget {
  final List<GenericEmote> emotes;
  final TextEditingController messageController;
  final FocusNode focusNode;
  final VoidCallback onClose;

  const EmoteSheet({
    super.key,
    required this.emotes,
    required this.messageController,
    required this.focusNode,
    required this.onClose,
  });

  @override
  State<EmoteSheet> createState() => _EmoteSheetState();
}

class _EmoteSheetState extends State<EmoteSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: widget.emotes.length, vsync: this);
    _tabCtrl.addListener(() {
      if (!_tabCtrl.indexIsChanging) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  String _typeLabel(GenericEmote emote) {
    if (emote.type == EmoteType.twitch) {
      var label = 'Twitch emote';
      if (emote.isZeroWidth) {
        label = '$label (Zero Width)';
      }
      return label;
    }
    final scope = switch (emote.scope) {
      EmoteScope.global => 'Global',
      EmoteScope.channel => 'Channel',
    };
    final provider = switch (emote.type) {
      EmoteType.bttv => 'BTTV',
      EmoteType.ffz => 'FFZ',
      EmoteType.sevenTv => '7TV',
      EmoteType.twitch => 'Twitch',
    };
    var label = '$scope $provider emote';
    if (emote.isZeroWidth) {
      label = '$label (Zero Width)';
    }
    return label;
  }

  String? _ownerLabel(GenericEmote emote) {
    final owner = emote.ownerChannel;
    if (owner == null) return null;
    return 'Created by $owner';
  }

  Widget _buildEmotePage(GenericEmote emote) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: emote.url,
                  width: 64,
                  height: 64,
                  //memCacheWidth: 64,
                  //memCacheHeight: 64,
                  fit: BoxFit.contain,
                  fadeInDuration: Duration.zero,
                  placeholder: (_, _) => Container(
                    width: 64,
                    height: 64,
                    color: theme.colorScheme.surfaceContainerHighest,
                  ),
                  errorWidget: (_, _, _) => Container(
                    width: 64,
                    height: 64,
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.image,
                      size: 32,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      emote.code,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _typeLabel(emote),
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (_ownerLabel(emote) != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        _ownerLabel(emote)!,
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ListTile(
            dense: true,
            leading: const Icon(Icons.send),
            title: const Text('Use emote'),
            onTap: () {
              widget.onClose();
              final text = widget.messageController.text;
              final suffix = text.isEmpty ? emote.code : ' $emote.code';
              widget.messageController.text = '$text$suffix';
              widget.messageController.selection = TextSelection.fromPosition(
                TextPosition(offset: widget.messageController.text.length),
              );
              widget.focusNode.requestFocus();
            },
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.copy),
            title: const Text('Copy'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: emote.code));
              widget.onClose();
            },
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.open_in_new),
            title: const Text('Open emote link'),
            onTap: () {
              widget.onClose();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Emote link not yet available')),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasMultiple = widget.emotes.length > 1;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (hasMultiple) ...[
            const SizedBox(height: 10),
            TabBar(
              controller: _tabCtrl,
              isScrollable: true,
              tabAlignment: TabAlignment.center,
              labelStyle: const TextStyle(fontSize: 13),
              tabs: widget.emotes.map((e) => Tab(text: e.code)).toList(),
            ),
          ],
          _buildEmotePage(
            hasMultiple ? widget.emotes[_tabCtrl.index] : widget.emotes.first,
          ),
        ],
      ),
    );
  }
}
