import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/feature_providers.dart';
import '../../services/archive.dart';
import '../../services/recent_messages.dart';
import '../../util/constants.dart';
import '../../util/prefs.dart';
import '../../widgets/dialogs.dart';
import 'data_usage_screen.dart';
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
      body: SettingInfoScope(
        child: ListView(
          children: [
            SettingsPageIntro(context.l10n.historyPageIntro),
            RecentMessagesSourceTile(onChanged: onRecentMessagesModeChanged),
            const RecentMessagesLimitTile(),
            SettingsSectionHeader(context.l10n.sectionArchive),
            const ArchiveRetentionTile(),
          ],
        ),
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

/// How long the archive keeps chat, with its size on disk. Shortening it
/// asks first, since older chat is deleted at once.
class ArchiveRetentionTile extends ConsumerStatefulWidget {
  const ArchiveRetentionTile({super.key});

  /// The choices, in days.
  static const days = [1, 3, 7, 14, 30];

  @override
  ConsumerState<ArchiveRetentionTile> createState() =>
      _ArchiveRetentionTileState();
}

class _ArchiveRetentionTileState extends ConsumerState<ArchiveRetentionTile> {
  static const _days = ArchiveRetentionTile.days;
  int _index = _days.indexOf(30);
  int _saved = _days.indexOf(30);
  int? _sizeBytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await Prefs.load();
    final size = await Archive.defaultSizeBytes();
    if (!mounted) return;
    // A stored value off the list snaps down to the nearest choice.
    var index = 0;
    for (var i = 0; i < _days.length; i++) {
      if (_days[i] <= prefs.archiveRetentionDays) index = i;
    }
    setState(() {
      _index = index;
      _saved = index;
      _sizeBytes = size;
    });
  }

  Future<void> _commit(int index) async {
    if (index == _saved) return;
    final l = context.l10n;
    final days = _days[index];
    if (index < _saved) {
      final ok = await confirmDialog(
        context,
        title: l.archiveShortenTitle,
        message: l.archiveShortenMessage(l.archiveDays(days)),
        confirmLabel: l.archiveShortenConfirm,
        destructive: true,
      );
      if (!ok) {
        if (mounted) setState(() => _index = _saved);
        return;
      }
    }
    final archive = ref.read(archiveProvider);
    final prefs = await Prefs.load();
    await prefs.setArchiveRetentionDays(days);
    await archive?.setRetention(Duration(days: days));
    final size = await Archive.defaultSizeBytes();
    if (!mounted) return;
    setState(() {
      _saved = index;
      _sizeBytes = size;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final size = _sizeBytes;
    return SettingAnchor(
      Setting.archiveRetention,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextWithTrailing(
              '${Setting.archiveRetention.titleOf(l)}: '
              '${l.archiveDays(_days[_index])}',
              trailing: const SettingInfoButton(Setting.archiveRetention),
            ),
          ),
          Slider(
            value: _index.toDouble(),
            max: (_days.length - 1).toDouble(),
            divisions: _days.length - 1,
            label: l.archiveDays(_days[_index]),
            onChanged: (v) => setState(() => _index = v.round()),
            onChangeEnd: (v) => _commit(v.round()),
          ),
          if (size != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l.archiveSize(DataUsageScreen.format(size)),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
