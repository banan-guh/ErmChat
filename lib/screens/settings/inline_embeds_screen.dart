import 'package:flutter/material.dart';
import '../../util/constants.dart';
import '../../util/prefs.dart';
import '../../util/prefs_store.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';

class InlineEmbedsScreen extends StatefulWidget {
  const InlineEmbedsScreen({super.key});

  @override
  State<InlineEmbedsScreen> createState() => _InlineEmbedsScreenState();
}

class _InlineEmbedsScreenState extends State<InlineEmbedsScreen> {
  Prefs? _prefs;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    // Re-reads prefs so the height sliders enable/disable with the toggles.
    PrefsStore.instance.addListener(_loadPrefs);
  }

  @override
  void dispose() {
    PrefsStore.instance.removeListener(_loadPrefs);
    super.dispose();
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
            defaultValue: kGiphyInlineEnabledDefault,
            read: (p) => p.giphyInlineEnabled,
            write: (p, v) => p.setGiphyInlineEnabled(v),
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
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Animation follows Emotes > Animate emotes.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SettingsSectionHeader('Images'),
          PrefsSwitchTile(
            secondary: const Icon(Icons.image_outlined),
            title: 'Show images inline',
            subtitle: "Tap a link's icon to preview",
            defaultValue: kImageEmbedEnabledDefault,
            read: (p) => p.imageEmbedEnabled,
            write: (p, v) => p.setImageEmbedEnabled(v),
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
          ),
        ],
      ),
    );
  }
}
