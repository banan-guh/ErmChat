import 'package:flutter/foundation.dart' show ValueListenable;
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
          _HeightSliderTile(
            setting: Settings.giphyInlineHeight,
            enabledPref: Settings.giphyInlineEnabled,
            min: kGiphyInlineHeightMin,
            max: kGiphyInlineHeightMax,
            defaultValue: kGiphyInlineHeightDefault,
            read: () => Settings.giphyInlineHeight.value,
            write: (v) => Settings.giphyInlineHeight.set(v),
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
          _HeightSliderTile(
            setting: Settings.imageEmbedHeight,
            enabledPref: Settings.imageEmbedEnabled,
            min: kImageEmbedHeightMin,
            max: kImageEmbedHeightMax,
            defaultValue: kImageEmbedHeightDefault,
            read: () => Settings.imageEmbedHeight.value,
            write: (v) => Settings.imageEmbedHeight.set(v),
          ),
        ],
      ),
    );
  }
}

/// One embed type's height slider, inert while that type is off.
class _HeightSliderTile extends StatelessWidget {
  const _HeightSliderTile({
    required this.setting,
    required this.enabledPref,
    required this.min,
    required this.max,
    required this.defaultValue,
    required this.read,
    required this.write,
  });

  /// The height setting: its title and its search anchor.
  final Setting<double> setting;

  /// Whether the embed type shows at all.
  final ValueListenable<bool> enabledPref;
  final double min;
  final double max;
  final double defaultValue;
  final double Function() read;
  final Future<void> Function(double value) write;

  @override
  Widget build(BuildContext context) {
    return SettingAnchor(
      setting,
      child: ValueListenableBuilder<bool>(
        valueListenable: enabledPref,
        builder: (context, enabled, _) => PrefsSliderTile(
          label: (v) => '${setting.titleOf(context.l10n)}: ${v.round()}dp',
          sliderLabel: (v) => '${v.round()}dp',
          enabled: enabled,
          min: min,
          max: max,
          divisions: 12,
          defaultValue: defaultValue,
          read: () => read().clamp(min, max),
          write: write,
        ),
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
