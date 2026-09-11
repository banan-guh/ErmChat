import 'package:flutter/material.dart';
import '../../util/constants.dart';
import '../../util/prefs.dart';
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
  bool _showGifs = kGiphyInlineEnabledDefault;
  double _gifHeight = kGiphyInlineHeightDefault;
  bool _showImages = kImageEmbedEnabledDefault;
  double _imageHeight = kImageEmbedHeightDefault;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await Prefs.load();
    if (mounted) {
      setState(() {
        _showGifs = prefs.giphyInlineEnabled;
        _gifHeight = prefs.giphyInlineHeight.clamp(
          kGiphyInlineHeightMin,
          kGiphyInlineHeightMax,
        );
        _showImages = prefs.imageEmbedEnabled;
        _imageHeight = prefs.imageEmbedHeight.clamp(
          kImageEmbedHeightMin,
          kImageEmbedHeightMax,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: const Text('Inline embeds'),
      body: ListView(
        children: [
          const SettingsSectionHeader('Giphy'),
          SwitchListTile(
            secondary: const Icon(Icons.gif_box),
            title: const Text('Show Giphy inline'),
            subtitle: const Text('Render Giphy attachments as images in chat'),
            value: _showGifs,
            onChanged: (value) async {
              final prefs = await Prefs.load();
              await prefs.setGiphyInlineEnabled(value);
              if (mounted) setState(() => _showGifs = value);
              widget.onShowGifsChanged?.call(value);
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Giphy height: ${_gifHeight.round()}dp',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: _showGifs
                    ? null
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Slider(
            value: _gifHeight.clamp(
              kGiphyInlineHeightMin,
              kGiphyInlineHeightMax,
            ),
            min: kGiphyInlineHeightMin,
            max: kGiphyInlineHeightMax,
            divisions: 12,
            label: '${_gifHeight.round()}dp',
            onChanged: _showGifs
                ? (value) {
                    setState(() => _gifHeight = value);
                    widget.onGifHeightChanged?.call(value);
                  }
                : null,
            onChangeEnd: _showGifs
                ? (value) {
                    Prefs.load().then(
                      (prefs) => prefs.setGiphyInlineHeight(value),
                    );
                  }
                : null,
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
          SwitchListTile(
            secondary: const Icon(Icons.image_outlined),
            title: const Text('Show images inline'),
            subtitle: const Text(
              'Image links get an icon; tap to expand the preview',
            ),
            value: _showImages,
            onChanged: (value) async {
              final prefs = await Prefs.load();
              await prefs.setImageEmbedEnabled(value);
              if (mounted) setState(() => _showImages = value);
              widget.onShowImagesChanged?.call(value);
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Image height: ${_imageHeight.round()}dp',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: _showImages
                    ? null
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Slider(
            value: _imageHeight.clamp(
              kImageEmbedHeightMin,
              kImageEmbedHeightMax,
            ),
            min: kImageEmbedHeightMin,
            max: kImageEmbedHeightMax,
            divisions: 12,
            label: '${_imageHeight.round()}dp',
            onChanged: _showImages
                ? (value) {
                    setState(() => _imageHeight = value);
                    widget.onImageHeightChanged?.call(value);
                  }
                : null,
            onChangeEnd: _showImages
                ? (value) {
                    Prefs.load().then(
                      (prefs) => prefs.setImageEmbedHeight(value),
                    );
                  }
                : null,
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
