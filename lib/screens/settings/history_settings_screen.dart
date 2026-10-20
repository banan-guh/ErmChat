import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/feature_providers.dart';
import '../../services/archive.dart';
import '../../services/recent_messages.dart';
import '../../util/constants.dart';
import '../../util/prefs.dart';
import '../../util/prefs_store.dart';
import '../../widgets/dialogs.dart';
import 'data_usage_screen.dart';
import 'prefs_tiles.dart';
import 'recent_messages_settings_screen.dart';
import 'setting_info.dart';
import 'settings_page.dart';
import 'settings_search.dart';
import '../../widgets/app_snack.dart';
import '../../util/settings.dart';

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
            const HistoryFetchTiles(),
            SettingsSectionHeader(context.l10n.sectionArchive),
            const ArchiveLimitsTile(),
          ],
        ),
      ),
    );
  }
}

/// Dynamic history fetch, and below it the manual count it replaces while
/// on: greyed then, and a tap offers to turn dynamic fetch off. Shown on
/// History and mirrored on Data.
class HistoryFetchTiles extends StatefulWidget {
  const HistoryFetchTiles({super.key});

  @override
  State<HistoryFetchTiles> createState() => _HistoryFetchTilesState();
}

class _HistoryFetchTilesState extends State<HistoryFetchTiles> {
  Future<void> _turnOff() async {
    await Settings.historyDynamicFetch.set(false);
    PrefsStore.instance.notifyChanged();
  }

  void _blockedSnack() => AppSnack.show(
    context,
    context.l10n.historyLimitDynamic,
    actionLabel: context.l10n.turnOff,
    onAction: _turnOff,
  );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Column(
      children: [
        SettingAnchor(
          Setting.gapFill,
          child: PrefsSwitchTile(
            title: Setting.gapFill.titleOf(l),
            subtitle: l.gapFillSubtitle,
            info: const SettingInfoButton(Setting.gapFill),
            pref: Settings.historyDynamicFetch,
          ),
        ),
        SettingAnchor(
          Setting.recentMessagesLimit,
          child: ValueListenableBuilder(
            valueListenable: Settings.historyDynamicFetch,
            builder: (context, dynamicFetch, _) {
              final limit = PrefsSliderTile(
                label: (v) =>
                    '${Setting.recentMessagesLimit.titleOf(l)}: ${v.round()}',
                labelTrailing: const SettingInfoButton(
                  Setting.recentMessagesLimit,
                ),
                sliderLabel: (v) => '${v.round()}',
                min: 0,
                max: 800,
                divisions: 8,
                enabled: !dynamicFetch,
                defaultValue: kRecentMessagesLimitDefault.toDouble(),
                read: (p) => p.recentMessagesLimit.clamp(0, 800).toDouble(),
                write: (p, v) => p.setRecentMessagesLimit(v.round()),
              );
              if (!dynamicFetch) return limit;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _blockedSnack,
                child: limit,
              );
            },
          ),
        ),
      ],
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
  int? _keptBytes;

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
    await _readSizes();
  }

  Future<void> _readSizes() async {
    final size = await Archive.defaultSizeBytes();
    final kept = await ref.read(archiveProvider)?.keptBytes();
    if (!mounted) return;
    setState(() {
      _sizeBytes = size;
      _keptBytes = kept;
    });
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
    if (!mounted) return;
    setState(() => _saved[slider] = index);
    await _readSizes();
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
    final kept = _keptBytes ?? 0;
    final note = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _slider(Setting.archiveRetention, 0, _days.length),
        _slider(Setting.archiveChannelCap, 1, _mb.length),
        if (size != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              [
                l.archiveSize(DataUsageScreen.format(size)),
                if (kept > 0) l.archiveKeptSize(DataUsageScreen.format(kept)),
              ].join(', '),
              style: note,
            ),
          ),
      ],
    );
  }
}
