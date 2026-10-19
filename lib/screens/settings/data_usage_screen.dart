import 'dart:async';

import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../util/data_usage.dart';
import 'settings_page.dart';

/// Bytes downloaded and sent since the app started, by source, largest
/// first. Refreshes every second while open.
class DataUsageScreen extends StatefulWidget {
  const DataUsageScreen({super.key});

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

  static String _format(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
    return SettingsPage(
      title: Text(l.settingDataUsage),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: false,
                  icon: const Icon(Icons.public),
                  label: Text(l.dataUsageAllNetworks),
                ),
                ButtonSegment(
                  value: true,
                  icon: const Icon(Icons.signal_cellular_alt),
                  label: Text(l.dataUsageMobileOnly),
                ),
              ],
              selected: {_mobileOnly},
              onSelectionChanged: (v) => setState(() => _mobileOnly = v.first),
            ),
          ),
          ListTile(
            title: Text(l.dataUsageTotal),
            trailing: Text(
              _format(total),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final (icon, label, bytes) in rows)
            ListTile(
              leading: Icon(icon),
              title: Text(label),
              trailing: Text(_format(bytes)),
              subtitle: LinearProgressIndicator(
                value: total == 0 ? 0 : bytes / total,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
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
