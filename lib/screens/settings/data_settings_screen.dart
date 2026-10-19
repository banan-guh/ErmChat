import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/emote_fetch_tier.dart';
import '../../services/emote_images.dart';
import '../../util/data_usage.dart';
import 'data_usage_screen.dart';
import 'emotes_settings_screen.dart';
import 'history_settings_screen.dart';
import 'inline_embeds_screen.dart';
import 'settings_page.dart';
import 'settings_search.dart';

/// Every setting that changes how much ermchat downloads, gathered from
/// their home pages, plus the usage counters.
class DataSettingsScreen extends StatelessWidget {
  const DataSettingsScreen({
    super.key,
    this.mobileNotifier,
    this.onEmoteTierChanged,
    this.onEmoteAutoModeChanged,
    this.onEmoteCacheMaxChanged,
    this.onNukeEmotes,
    this.images,
  });

  final ValueNotifier<bool>? mobileNotifier;
  final ValueChanged<int>? onEmoteTierChanged;
  final ValueChanged<EmoteFetchAutoMode>? onEmoteAutoModeChanged;
  final ValueChanged<int>? onEmoteCacheMaxChanged;
  final VoidCallback? onNukeEmotes;
  final EmoteImages? images;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final usage = DataUsageStats.I;
    return SettingsPage(
      title: Text(l.pageData),
      body: SettingInfoScope(
        child: ListView(
          children: [
            SettingsPageIntro(l.dataPageIntro),
            SettingAnchor(
              Setting.dataUsage,
              child: SettingsNavTile(
                icon: Icons.bar_chart,
                title: Setting.dataUsage.titleOf(l),
                subtitle: l.dataUsageSummary(
                  DataUsageScreen.format(usage.totalFor()),
                  DataUsageScreen.format(usage.totalFor(mobileOnly: true)),
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const DataUsageScreen()),
                ),
              ),
            ),
            EmoteQualitySection(
              mobileNotifier: mobileNotifier,
              onTierChanged: onEmoteTierChanged,
              onAutoModeChanged: onEmoteAutoModeChanged,
            ),
            EmoteCacheSection(
              images: images,
              onCacheMaxChanged: onEmoteCacheMaxChanged,
              onNuke: onNukeEmotes,
            ),
            SettingsSectionHeader(l.pageHistory),
            const RecentMessagesLimitTile(),
            SettingsSectionHeader(l.inlineEmbedsTitle),
            const ShowGiphyTile(),
            const ShowImagesTile(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
