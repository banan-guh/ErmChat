import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/recent_messages.dart';
import '../../util/constants.dart';
import 'prefs_tiles.dart';
import 'recent_messages_settings_screen.dart';
import 'setting_info.dart';
import 'settings_page.dart';
import 'settings_search.dart';

/// Where past messages come from and how many load.
class HistorySettingsScreen extends StatelessWidget {
  const HistorySettingsScreen({super.key, this.onRecentMessagesModeChanged});

  final ValueChanged<RecentMessagesConfig>? onRecentMessagesModeChanged;

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.pageHistory),
      body: ListView(
        children: [
          SettingsPageIntro(context.l10n.historyPageIntro),
          RecentMessagesSourceTile(onChanged: onRecentMessagesModeChanged),
          const RecentMessagesLimitTile(),
        ],
      ),
    );
  }
}

/// How many past messages load on join and reconnect. Shown on History and
/// mirrored on Data.
class RecentMessagesLimitTile extends StatelessWidget {
  const RecentMessagesLimitTile({super.key});

  @override
  Widget build(BuildContext context) => SettingAnchor(
    Setting.recentMessagesLimit,
    child: PrefsSliderTile(
      label: (v) =>
          '${Setting.recentMessagesLimit.titleOf(context.l10n)}: ${v.round()}',
      labelTrailing: const SettingInfoButton(Setting.recentMessagesLimit),
      sliderLabel: (v) => '${v.round()}',
      min: 0,
      max: 800,
      divisions: 8,
      defaultValue: kRecentMessagesLimitDefault.toDouble(),
      read: (p) => p.recentMessagesLimit.clamp(0, 800).toDouble(),
      write: (p, v) => p.setRecentMessagesLimit(v.round()),
    ),
  );
}

/// Opens the history provider picker.
class RecentMessagesSourceTile extends StatelessWidget {
  const RecentMessagesSourceTile({super.key, this.onChanged});

  final ValueChanged<RecentMessagesConfig>? onChanged;

  @override
  Widget build(BuildContext context) => SettingAnchor(
    Setting.recentMessagesSource,
    child: SettingsNavTile(
      icon: Icons.history,
      title: Setting.recentMessagesSource.titleOf(context.l10n),
      titleTrailing: const SettingInfoButton(Setting.recentMessagesSource),
      subtitle: context.l10n.chooseProvider,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RecentMessagesSettingsScreen(onChanged: onChanged),
        ),
      ),
    ),
  );
}
