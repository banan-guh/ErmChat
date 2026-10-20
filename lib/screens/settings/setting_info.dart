import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'settings_page.dart';
import 'settings_search.dart';

/// Why a setting exists and what it trades.
class SettingHelp {
  const SettingHelp({
    required this.why,
    required this.gain,
    required this.lose,
  });

  final String why;
  final String gain;
  final String lose;
}

/// The help for [setting], or null when it has none.
SettingHelp? settingHelp(Setting setting, AppLocalizations l) =>
    switch (setting.id) {
      'emote_fetching' => SettingHelp(
        why: l.helpEmoteFetchingWhy,
        gain: l.helpEmoteFetchingGain,
        lose: l.helpEmoteFetchingLose,
      ),
      'auto_data_saver' => SettingHelp(
        why: l.helpAutoDataSaverWhy,
        gain: l.helpAutoDataSaverGain,
        lose: l.helpAutoDataSaverLose,
      ),
      'emote_cache' => SettingHelp(
        why: l.helpEmoteCacheWhy,
        gain: l.helpEmoteCacheGain,
        lose: l.helpEmoteCacheLose,
      ),
      'animate_emotes' => SettingHelp(
        why: l.helpAnimateEmotesWhy,
        gain: l.helpAnimateEmotesGain,
        lose: l.helpAnimateEmotesLose,
      ),
      'adaptive_fps' => SettingHelp(
        why: l.helpAdaptiveFpsWhy,
        gain: l.helpAdaptiveFpsGain,
        lose: l.helpAdaptiveFpsLose,
      ),
      'idle_fps' => SettingHelp(
        why: l.helpIdleFpsWhy,
        gain: l.helpIdleFpsGain,
        lose: l.helpIdleFpsLose,
      ),
      'true_dark' => SettingHelp(
        why: l.helpTrueDarkWhy,
        gain: l.helpTrueDarkGain,
        lose: l.helpTrueDarkLose,
      ),
      'liquid_glass' => SettingHelp(
        why: l.helpLiquidGlassWhy,
        gain: l.helpLiquidGlassGain,
        lose: l.helpLiquidGlassLose,
      ),
      'keep_screen_on' => SettingHelp(
        why: l.helpKeepScreenOnWhy,
        gain: l.helpKeepScreenOnGain,
        lose: l.helpKeepScreenOnLose,
      ),
      'stay_connected' => SettingHelp(
        why: l.helpStayConnectedWhy,
        gain: l.helpStayConnectedGain,
        lose: l.helpStayConnectedLose,
      ),
      'show_giphy' => SettingHelp(
        why: l.helpShowGiphyWhy,
        gain: l.helpShowGiphyGain,
        lose: l.helpShowGiphyLose,
      ),
      'show_images' => SettingHelp(
        why: l.helpShowImagesWhy,
        gain: l.helpShowImagesGain,
        lose: l.helpShowImagesLose,
      ),
      'recent_messages_limit' => SettingHelp(
        why: l.helpRecentMessagesLimitWhy,
        gain: l.helpRecentMessagesLimitGain,
        lose: l.helpRecentMessagesLimitLose,
      ),
      'recent_messages_source' => SettingHelp(
        why: l.helpRecentMessagesSourceWhy,
        gain: l.helpRecentMessagesSourceGain,
        lose: l.helpRecentMessagesSourceLose,
      ),
      'gap_fill' => SettingHelp(
        why: l.helpGapFillWhy,
        gain: l.helpGapFillGain,
        lose: l.helpGapFillLose,
      ),
      'archive_retention' => SettingHelp(
        why: l.helpArchiveRetentionWhy,
        gain: l.helpArchiveRetentionGain,
        lose: l.helpArchiveRetentionLose,
      ),
      'archive_channel_cap' => SettingHelp(
        why: l.helpArchiveChannelCapWhy,
        gain: l.helpArchiveChannelCapGain,
        lose: l.helpArchiveChannelCapLose,
      ),
      _ => null,
    };

/// [title] followed by the setting's info button, for a tile's title slot.
class TitleWithInfo extends StatelessWidget {
  const TitleWithInfo(this.title, this.setting, {super.key});

  final String title;
  final Setting setting;

  @override
  Widget build(BuildContext context) =>
      TextWithTrailing(title, trailing: SettingInfoButton(setting));
}

/// A small info button that explains [setting] in a panel. Renders nothing
/// outside a [SettingInfoScope].
class SettingInfoButton extends StatelessWidget {
  const SettingInfoButton(this.setting, {super.key});

  final Setting setting;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final help = settingHelp(setting, l);
    if (help == null || !SettingInfoScope.of(context)) {
      return const SizedBox.shrink();
    }
    // Sized to a text line, so a title that wraps keeps an even line height.
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: IconButton(
        icon: const Icon(Icons.info_outline),
        iconSize: 18,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 24, height: 24),
        style: const ButtonStyle(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        tooltip: l.settingInfoTooltip,
        onPressed: () => showSettingInfo(context, setting.titleOf(l), help),
      ),
    );
  }
}

/// Shows [help] in a plain panel: what the setting does, then what it
/// gains and costs.
Future<void> showSettingInfo(
  BuildContext context,
  String title,
  SettingHelp help,
) => showDialog<void>(
  context: context,
  builder: (context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            help.why,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          _TradeRow(
            icon: Icons.add_circle_outline,
            color: scheme.primary,
            label: l.settingInfoGain,
            text: help.gain,
          ),
          const SizedBox(height: 12),
          _TradeRow(
            icon: Icons.remove_circle_outline,
            color: scheme.error,
            label: l.settingInfoLose,
            text: help.lose,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.settingInfoDone),
        ),
      ],
    );
  },
);

class _TradeRow extends StatelessWidget {
  const _TradeRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(color: color),
              ),
              const SizedBox(height: 2),
              Text(text, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ],
    );
  }
}
