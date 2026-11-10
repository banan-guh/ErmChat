import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../util/constants.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';
import 'setting_info.dart';
import 'settings_search.dart';
import '../../util/settings.dart';

class InlineEmbedsScreen extends StatelessWidget {
  const InlineEmbedsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.inlineEmbedsTitle),
      body: ListView(
        children: [
          SettingsSectionHeader(context.l10n.sectionGiphy),
          const ShowGiphyTile(),
          SettingAnchor(
            Settings.giphyInlineHeight,
            child: ValueListenableBuilder<bool>(
              valueListenable: Settings.giphyInlineEnabled,
              builder: (context, showGifs, _) => PrefsSliderTile(
                label: (v) =>
                    '${Settings.giphyInlineHeight.titleOf(context.l10n)}: ${v.round()}dp',
                sliderLabel: (v) => '${v.round()}dp',
                enabled: showGifs,
                min: kGiphyInlineHeightMin,
                max: kGiphyInlineHeightMax,
                divisions: 12,
                defaultValue: kGiphyInlineHeightDefault,
                read: () => Settings.giphyInlineHeight.value.clamp(
                  kGiphyInlineHeightMin,
                  kGiphyInlineHeightMax,
                ),
                write: (v) => Settings.giphyInlineHeight.set(v),
              ),
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
            Settings.imageEmbedHeight,
            child: ValueListenableBuilder<bool>(
              valueListenable: Settings.imageEmbedEnabled,
              builder: (context, showImages, _) => PrefsSliderTile(
                label: (v) =>
                    '${Settings.imageEmbedHeight.titleOf(context.l10n)}: ${v.round()}dp',
                sliderLabel: (v) => '${v.round()}dp',
                enabled: showImages,
                min: kImageEmbedHeightMin,
                max: kImageEmbedHeightMax,
                divisions: 12,
                defaultValue: kImageEmbedHeightDefault,
                read: () => Settings.imageEmbedHeight.value.clamp(
                  kImageEmbedHeightMin,
                  kImageEmbedHeightMax,
                ),
                write: (v) => Settings.imageEmbedHeight.set(v),
              ),
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
  Widget build(BuildContext context) => SettingSwitch(
    Settings.giphyInlineEnabled,
    secondary: const Icon(Icons.gif_box),
    info: SettingInfoButton(Settings.giphyInlineEnabled),
  );
}

/// Inline image previews. Shown on Inline embeds and mirrored on Data.
class ShowImagesTile extends StatelessWidget {
  const ShowImagesTile({super.key});

  @override
  Widget build(BuildContext context) => SettingSwitch(
    Settings.imageEmbedEnabled,
    secondary: const Icon(Icons.image_outlined),
    subtitle: context.l10n.imagePreviewHint,
    info: SettingInfoButton(Settings.imageEmbedEnabled),
  );
}
