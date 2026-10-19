import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
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
      _ => null,
    };

/// [title] followed by the setting's info button, for a tile's title slot.
class TitleWithInfo extends StatelessWidget {
  const TitleWithInfo(this.title, this.setting, {super.key});

  final String title;
  final Setting setting;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(child: Text(title)),
      SettingInfoButton(setting),
    ],
  );
}

/// A small info button that explains [setting] in an animated card.
class SettingInfoButton extends StatelessWidget {
  const SettingInfoButton(this.setting, {super.key});

  final Setting setting;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final help = settingHelp(setting, l);
    if (help == null) return const SizedBox.shrink();
    return IconButton(
      icon: const Icon(Icons.info_outline),
      iconSize: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      tooltip: l.settingInfoTooltip,
      onPressed: () => showSettingInfo(context, setting.titleOf(l), help),
    );
  }
}

/// Shows [help] in a card that scales in, with the trade-off rows
/// following a beat later.
Future<void> showSettingInfo(
  BuildContext context,
  String title,
  SettingHelp help,
) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  barrierColor: Colors.black54,
  transitionDuration: const Duration(milliseconds: 380),
  pageBuilder: (context, animation, _) =>
      _InfoCard(title: title, help: help, animation: animation),
  transitionBuilder: (context, animation, _, child) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeIn,
    );
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: ScaleTransition(
        scale: Tween(begin: 0.88, end: 1.0).animate(curved),
        child: child,
      ),
    );
  },
);

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.help,
    required this.animation,
  });

  final String title;
  final SettingHelp help;
  final Animation<double> animation;

  /// Fades and lifts [child] in over [start]..1 of the entrance.
  Widget _staged(double start, Widget child) {
    final t = CurvedAnimation(
      parent: animation,
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: t,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.25),
          end: Offset.zero,
        ).animate(t),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Material(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text(
                      help.why,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _staged(
                      0.35,
                      _TradeRow(
                        icon: Icons.add_circle_outline,
                        color: scheme.primary,
                        label: l.settingInfoGain,
                        text: help.gain,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _staged(
                      0.55,
                      _TradeRow(
                        icon: Icons.remove_circle_outline,
                        color: scheme.error,
                        label: l.settingInfoLose,
                        text: help.lose,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(l.settingInfoDone),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
