import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/feature_providers.dart';
import '../../services/archive.dart';
import '../../services/gap_fill.dart';
import '../../services/recent_messages.dart';
import '../../util/constants.dart';
import '../../util/prefs.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/level_switch.dart';
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
            const GapFillTile(),
            SettingsSectionHeader(context.l10n.sectionArchive),
            const ArchiveLimitsTile(),
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

/// How hard history fills the gap since the last message seen. Shown on
/// History and mirrored on Data.
class GapFillTile extends StatefulWidget {
  const GapFillTile({super.key});

  @override
  State<GapFillTile> createState() => _GapFillTileState();
}

class _GapFillTileState extends State<GapFillTile> {
  GapFill _mode = GapFill.low;

  @override
  void initState() {
    super.initState();
    Prefs.load().then((p) {
      if (mounted) setState(() => _mode = GapFill.fromIndex(p.historyGapFill));
    });
  }

  Future<void> _set(int index) async {
    setState(() => _mode = GapFill.fromIndex(index));
    await (await Prefs.load()).setHistoryGapFill(index);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return SettingAnchor(
      Setting.gapFill,
      child: ListTile(
        title: TitleWithInfo(Setting.gapFill.titleOf(l), Setting.gapFill),
        subtitle: Text(switch (_mode) {
          GapFill.off => l.gapFillOffSubtitle,
          GapFill.low => l.gapFillLowSubtitle,
          GapFill.high => l.gapFillHighSubtitle,
        }),
        trailing: LevelSwitch(
          level: _mode.index,
          names: [l.gapFillOff, l.gapFillLow, l.gapFillHigh],
          color: Theme.of(context).colorScheme.primary,
          onChanged: _set,
        ),
      ),
    );
  }
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

/// How long and how much chat the archive keeps, with its size on disk.
/// Tightening a limit asks first, since older chat is deleted at once.
class ArchiveLimitsTile extends ConsumerStatefulWidget {
  const ArchiveLimitsTile({super.key});

  /// The retention choices, in days.
  static const days = [1, 3, 7, 14, 30];

  /// The per-channel choices, in MB. 0 is no cap, so it comes last.
  static const megabytes = [10, 25, 50, 100, 250, 0];

  @override
  ConsumerState<ArchiveLimitsTile> createState() => _ArchiveLimitsTileState();
}

class _ArchiveLimitsTileState extends ConsumerState<ArchiveLimitsTile> {
  static const _days = ArchiveLimitsTile.days;
  static const _mb = ArchiveLimitsTile.megabytes;
  final _index = [_days.length - 1, _mb.length - 1];
  final _saved = [_days.length - 1, _mb.length - 1];
  int? _sizeBytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The largest choice at or below [value], so a stored value off the list
  /// snaps down. 0 (no cap) ranks above every size.
  static int _snap(List<int> choices, int value) {
    int rank(int v) => v == 0 ? 1 << 30 : v;
    var index = 0;
    for (var i = 0; i < choices.length; i++) {
      if (rank(choices[i]) <= rank(value)) index = i;
    }
    return index;
  }

  Future<void> _load() async {
    final prefs = await Prefs.load();
    if (!mounted) return;
    setState(() {
      _index[0] = _saved[0] = _snap(_days, prefs.archiveRetentionDays);
      _index[1] = _saved[1] = _snap(_mb, prefs.archiveChannelCapMb);
    });
    final size = await Archive.defaultSizeBytes();
    if (mounted) setState(() => _sizeBytes = size);
  }

  String _label(AppLocalizations l, int slider, int index) => slider == 0
      ? l.archiveDays(_days[index])
      : _mb[index] == 0
      ? l.archiveNoCap
      : l.archiveMegabytes(_mb[index]);

  Future<void> _commit(int slider, int index) async {
    if (index == _saved[slider]) return;
    final l = context.l10n;
    if (index < _saved[slider]) {
      final value = _label(l, slider, index);
      final ok = await confirmDialog(
        context,
        title: l.archiveShortenTitle,
        message: slider == 0
            ? l.archiveShortenMessage(value)
            : l.archiveCapMessage(value),
        confirmLabel: l.archiveShortenConfirm,
        destructive: true,
      );
      if (!ok) {
        if (mounted) setState(() => _index[slider] = _saved[slider]);
        return;
      }
    }
    final archive = ref.read(archiveProvider);
    final prefs = await Prefs.load();
    if (slider == 0) {
      await prefs.setArchiveRetentionDays(_days[index]);
      await archive?.setRetention(Duration(days: _days[index]));
    } else {
      await prefs.setArchiveChannelCapMb(_mb[index]);
      await archive?.setChannelCap(Archive.capBytes(_mb[index]));
    }
    final size = await Archive.defaultSizeBytes();
    if (!mounted) return;
    setState(() {
      _saved[slider] = index;
      _sizeBytes = size;
    });
  }

  Widget _slider(Setting setting, int slider, int choices) {
    final l = context.l10n;
    final label = _label(l, slider, _index[slider]);
    return SettingAnchor(
      setting,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextWithTrailing(
              '${setting.titleOf(l)}: $label',
              trailing: SettingInfoButton(setting),
            ),
          ),
          Slider(
            value: _index[slider].toDouble(),
            max: (choices - 1).toDouble(),
            divisions: choices - 1,
            label: label,
            onChanged: (v) => setState(() => _index[slider] = v.round()),
            onChangeEnd: (v) => _commit(slider, v.round()),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final size = _sizeBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _slider(Setting.archiveRetention, 0, _days.length),
        _slider(Setting.archiveChannelCap, 1, _mb.length),
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
    );
  }
}
