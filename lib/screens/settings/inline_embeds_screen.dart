import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../util/constants.dart';
import '../../util/prefs.dart';
import '../../util/prefs_store.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';
import 'setting_info.dart';
import 'settings_search.dart';
import '../../util/settings.dart';

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
      title: Text(context.l10n.inlineEmbedsTitle),
      body: ListView(
        children: [
          SettingsSectionHeader(context.l10n.sectionGiphy),
          const ShowGiphyTile(),
          SettingAnchor(
            Setting.giphyHeight,
            child: PrefsSliderTile(
              label: (v) =>
                  '${Setting.giphyHeight.titleOf(context.l10n)}: ${v.round()}dp',
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
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              context.l10n.giphyAnimationNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          SettingsSectionHeader(context.l10n.sectionImages),
          const ShowImagesTile(),
          SettingAnchor(
            Setting.imageHeight,
            child: PrefsSliderTile(
              label: (v) =>
                  '${Setting.imageHeight.titleOf(context.l10n)}: ${v.round()}dp',
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
          ),
        ],
      ),
    );
  }
}

/// Inline Giphy playback. Shown on Inline embeds and mirrored on Data.
class ShowGiphyTile extends StatelessWidget {
  const ShowGiphyTile({super.key});

  @override
  Widget build(BuildContext context) => SettingAnchor(
    Setting.showGiphy,
    child: PrefsSwitchTile(
      secondary: const Icon(Icons.gif_box),
      title: Setting.showGiphy.titleOf(context.l10n),
      info: const SettingInfoButton(Setting.showGiphy),
      pref: Settings.giphyInlineEnabled,
    ),
  );
}

/// Inline image previews. Shown on Inline embeds and mirrored on Data.
class ShowImagesTile extends StatelessWidget {
  const ShowImagesTile({super.key});

  @override
  Widget build(BuildContext context) => SettingAnchor(
    Setting.showImages,
    child: PrefsSwitchTile(
      secondary: const Icon(Icons.image_outlined),
      title: Setting.showImages.titleOf(context.l10n),
      subtitle: context.l10n.imagePreviewHint,
      info: const SettingInfoButton(Setting.showImages),
      pref: Settings.imageEmbedEnabled,
    ),
  );
}
