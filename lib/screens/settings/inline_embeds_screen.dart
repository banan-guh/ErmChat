import 'package:flutter/material.dart';
import '../../util/constants.dart';
import '../../util/prefs.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';

class InlineEmbedsScreen extends StatefulWidget {
  final ValueChanged<bool>? onShowGifsChanged;
  final ValueChanged<double>? onGifHeightChanged;
  final ValueChanged<bool>? onShowImagesChanged;
  final ValueChanged<double>? onImageHeightChanged;

  const InlineEmbedsScreen({
    super.key,
    this.onShowGifsChanged,
    this.onGifHeightChanged,
    this.onShowImagesChanged,
    this.onImageHeightChanged,
  });

  @override
  State<InlineEmbedsScreen> createState() => _InlineEmbedsScreenState();
}

class _InlineEmbedsScreenState extends State<InlineEmbedsScreen> {
  Prefs? _prefs;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await Prefs.load();
    if (mounted) setState(() => _prefs = prefs);
  }

  bool get _showGifs =>
      _prefs?.giphyInlineEnabled ?? kGiphyInlineEnabledDefault;

  bool get _showImages =>
      _prefs?.imageEmbedEnabled ?? kImageEmbedEnabledDefault;

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: const Text('Inline embeds'),
      body: ListView(
        children: [
          const SettingsSectionHeader('Giphy'),
          PrefsSwitchTile(
            secondary: const Icon(Icons.gif_box),
            title: 'Show Giphy inline',
            subtitle: 'Render Giphy attachments as images in chat',
            defaultValue: kGiphyInlineEnabledDefault,
            read: (p) => p.giphyInlineEnabled,
            write: (p, v) => p.setGiphyInlineEnabled(v),
            onChanged: (v) {
              setState(() {});
              widget.onShowGifsChanged?.call(v);
            },
          ),
          PrefsSliderTile(
            label: (v) => 'Giphy height: ${v.round()}dp',
            sliderLabel: (v) => '${v.round()}dp',
            enabled: _showGifs,
            min: kGiphyInlineHeightMin,
            max: kGiphyInlineHeightMax,
            divisions: 12,
            defaultValue: kGiphyInlineHeightDefault,
            read: (p) => p.giphyInlineHeight.clamp(
              kGiphyInlineHeightMin,
              kGiphyInlineHeightMax,
            ),
            write: (p, v) => p.setGiphyInlineHeight(v),
            onChanged: widget.onGifHeightChanged,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Animation follows Emotes > Animate GIFs.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SettingsSectionHeader('Images'),
          PrefsSwitchTile(
            secondary: const Icon(Icons.image_outlined),
            title: 'Show images inline',
            subtitle: 'Image links get an icon; tap to expand the preview',
            defaultValue: kImageEmbedEnabledDefault,
            read: (p) => p.imageEmbedEnabled,
            write: (p, v) => p.setImageEmbedEnabled(v),
            onChanged: (v) {
              setState(() {});
              widget.onShowImagesChanged?.call(v);
            },
          ),
          PrefsSliderTile(
            label: (v) => 'Image height: ${v.round()}dp',
            sliderLabel: (v) => '${v.round()}dp',
            enabled: _showImages,
            min: kImageEmbedHeightMin,
            max: kImageEmbedHeightMax,
            divisions: 12,
            defaultValue: kImageEmbedHeightDefault,
            read: (p) => p.imageEmbedHeight.clamp(
              kImageEmbedHeightMin,
              kImageEmbedHeightMax,
            ),
            write: (p, v) => p.setImageEmbedHeight(v),
            onChanged: widget.onImageHeightChanged,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Previews load only when expanded, directly from the host, '
              'which sees your IP. Off by default.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
