import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
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
    final provider = switch (emote.type) {
      EmoteType.twitch => 'Twitch',
      EmoteType.bttv => 'BTTV',
      EmoteType.ffz => 'FFZ',
      EmoteType.sevenTv => '7TV',
    };
    if (emote.type == EmoteType.twitch) {
      return emote.isZeroWidth ? 'Twitch Emote (Zero Width)' : 'Twitch Emote';
    }
    final scope = emote.scope == EmoteScope.global ? 'Global' : 'Channel';
    var label = '$provider $scope Emote';
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

  String _providerUrl(GenericEmote emote) {
    return switch (emote.type) {
      EmoteType.sevenTv => 'https://7tv.app/emotes/${emote.id}',
      EmoteType.bttv => 'https://betterttv.com/emotes/${emote.id}',
      EmoteType.ffz =>
        'https://www.frankerfacez.com/emoticon/${emote.id}-${emote.code}',
      EmoteType.twitch => 'https://chatvau.lt/emote/twitch/${emote.id}',
    };
  }

  Future<void> _openUrl(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  Widget _buildEmotePage(GenericEmote emote) {
    final theme = Theme.of(context);
    final owner = _ownerLabel(emote);

    final subtitleStyle = TextStyle(
      fontSize: 16,
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.2,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 128x128 emote preview.
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 128,
                    height: 128,
                    child: CachedNetworkImage(
                      imageUrl: emote.url,
                      fit: BoxFit.contain,
                      fadeInDuration: Duration.zero,
                      placeholder: (_, _) => const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                      errorWidget: (_, _, _) => Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.image,
                          size: 32,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8, right: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        emote.code,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w400,
                          height: 1.3,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _typeLabel(emote),
                        textAlign: TextAlign.center,
                        style: subtitleStyle,
                      ),
                      if (emote.baseName != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Alias of ${emote.baseName}',
                          textAlign: TextAlign.center,
                          style: subtitleStyle,
                        ),
                      ],
                      if (owner != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          owner,
                          textAlign: TextAlign.center,
                          style: subtitleStyle,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.send),
            title: const Text('Use emote'),
            onTap: () {
              widget.onClose();
              final text = widget.messageController.text;
              final suffix = text.isEmpty ? emote.code : ' ${emote.code}';
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
            onTap: () => _openUrl(_providerUrl(emote)),
          ),
        ],
      ),
    );
  }

  // Uniform height for the swipeable TabBarView: the tallest page across all
  // emotes (image block vs. scaled text column, plus the three action rows).
  double _pageHeight() {
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    var subRows = 0;
    for (final e in widget.emotes) {
      final rows =
          (e.baseName != null ? 1 : 0) + (_ownerLabel(e) != null ? 1 : 0);
      if (rows > subRows) subRows = rows;
    }
    final nameH = 22.0 * 1.3 * scale;
    final rowH = 16.0 * 1.2 * scale;
    final textColumn = 8 + nameH + 8 + rowH * (1 + subRows) + 8 * subRows;
    final imageBlock = 128.0 + 16;
    final header = textColumn > imageBlock ? textColumn : imageBlock;
    final tiles = 3 * 48.0 * scale;
    return header + tiles + 16;
  }

  Widget _buildEmotePages() {
    if (widget.emotes.length <= 1) {
      return _buildEmotePage(widget.emotes.first);
    }
    return SizedBox(
      height: _pageHeight(),
      child: TabBarView(
        controller: _tabCtrl,
        physics: const PageScrollPhysics(),
        children: [for (final e in widget.emotes) _buildEmotePage(e)],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasMultiple = widget.emotes.length > 1;

    return Padding(
      padding: const EdgeInsets.all(8),
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
            const SizedBox(height: 8),
            TabBar(
              controller: _tabCtrl,
              isScrollable: true,
              tabAlignment: TabAlignment.center,
              labelStyle: const TextStyle(fontSize: 14),
              tabs: widget.emotes.map((e) => Tab(text: e.code)).toList(),
            ),
          ],
          _buildEmotePages(),
        ],
      ),
    );
  }
}
