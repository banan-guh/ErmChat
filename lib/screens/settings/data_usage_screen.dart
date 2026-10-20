import 'dart:async';

import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../util/data_usage.dart';
import 'settings_page.dart';

/// Bytes downloaded and sent since the app started, by source, largest
/// first. Refreshes every second while open.
class DataUsageScreen extends StatefulWidget {
  const DataUsageScreen({super.key});

  static String format(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  State<DataUsageScreen> createState() => _DataUsageScreenState();
}

class _DataUsageScreenState extends State<DataUsageScreen> {
  late final Timer _tick;

  // Kept across visits for the app session.
  static bool _mobileOnly = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final s = DataUsageStats.I;
    int bytes(DataSource source) => s.bytesFor(source, mobileOnly: _mobileOnly);
    final rows = [
      (Icons.chat_bubble_outline, l.dataUsageChat, bytes(DataSource.chat)),
      (Icons.send_outlined, l.dataUsageSent, bytes(DataSource.sent)),
      (Icons.history, l.dataUsageHistory, bytes(DataSource.history)),
      (Icons.api_outlined, l.dataUsageTwitchApi, bytes(DataSource.twitchApi)),
      (Icons.bolt_outlined, l.dataUsageEvents, bytes(DataSource.events)),
      (Icons.list_alt, l.dataUsageEmoteLists, bytes(DataSource.emoteLists)),
      (
        Icons.image_outlined,
        l.dataUsageEmoteImages,
        bytes(DataSource.emoteImages),
      ),
    ]..sort((a, b) => b.$3.compareTo(a.$3));
    final total = s.totalFor(mobileOnly: _mobileOnly);
    final scheme = Theme.of(context).colorScheme;
    final scope = _mobileOnly ? l.dataUsageMobileOnly : l.dataUsageAllNetworks;
    return SettingsPage(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.settingDataUsage),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              scope,
              key: ValueKey(_mobileOnly),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
      actions: [
        _NetworkToggle(
          mobileOnly: _mobileOnly,
          onChanged: (v) => setState(() => _mobileOnly = v),
        ),
        const SizedBox(width: 12),
      ],
      body: ListView(
        children: [
          ListTile(
            title: Text(l.dataUsageTotal),
            trailing: Text(
              DataUsageScreen.format(total),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final (icon, label, bytes) in rows)
            ListTile(
              leading: Icon(icon),
              title: Text(label),
              trailing: Text(DataUsageScreen.format(bytes)),
              subtitle: LinearProgressIndicator(
                value: total == 0 ? 0 : bytes / total,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          SettingsSectionHeader(l.dataSavedSection),
          ..._saved(context, s, _mobileOnly),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l.dataUsageFooter,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// What each data saver served without a download, against what it fetched.
List<Widget> _saved(BuildContext context, DataUsageStats s, bool mobileOnly) {
  final l = context.l10n;
  int n(SessionCount c) => c.of(mobileOnly: mobileOnly);
  final fromDisk = n(s.imagesFromDisk);
  final images = fromDisk + n(s.imagesDownloaded);
  final lists = n(s.listsFromDisk) + n(s.listsFetched);
  final gaps = n(s.gapFetches);
  Widget tile(
    IconData icon,
    String title,
    int total,
    String value,
    String hint,
  ) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: total == 0 ? null : Text(hint),
    trailing: Text(total == 0 ? l.dataSavedNone : value),
  );
  return [
    tile(
      Icons.image_outlined,
      l.dataUsageEmoteImages,
      images,
      DataUsageScreen.format(n(s.imageBytesFromDisk)),
      l.dataSavedFromDisk(images == 0 ? 0 : (100 * fromDisk / images).round()),
    ),
    tile(
      Icons.list_alt,
      l.dataUsageEmoteLists,
      lists,
      l.dataSavedOf(n(s.listsFromDisk), lists),
      l.dataSavedListsHint,
    ),
    tile(
      Icons.history,
      l.settingGapFill,
      gaps,
      l.dataSavedOf(n(s.gapsFilled), gaps),
      l.dataSavedGapsHint,
    ),
  ];
}

/// Two-icon switch between all networks (globe) and mobile data (bars).
class _NetworkToggle extends StatelessWidget {
  const _NetworkToggle({required this.mobileOnly, required this.onChanged});

  final bool mobileOnly;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    Widget option(bool value, IconData icon, String label) {
      final selected = mobileOnly == value;
      return Tooltip(
        message: label,
        child: Semantics(
          button: true,
          selected: selected,
          label: label,
          child: GestureDetector(
            onTap: () => onChanged(value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              width: 36,
              height: 28,
              decoration: BoxDecoration(
                color: selected ? scheme.primaryContainer : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                icon,
                size: 18,
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          option(false, Icons.public, l.dataUsageAllNetworks),
          option(true, Icons.signal_cellular_alt, l.dataUsageMobileOnly),
        ],
      ),
    );
  }
}
