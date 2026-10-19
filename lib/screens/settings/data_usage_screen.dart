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
    final rows = [
      (Icons.chat_bubble_outline, l.dataUsageChat, s.ircReadBytes),
      (Icons.send_outlined, l.dataUsageSent, s.ircWriteBytes),
      (Icons.history, l.dataUsageHistory, s.historyBytes),
      (Icons.api_outlined, l.dataUsageTwitchApi, s.helixBytes),
      (Icons.bolt_outlined, l.dataUsageEvents, s.eventBytes),
      (Icons.list_alt, l.dataUsageEmoteLists, s.jsonBytes),
      (Icons.image_outlined, l.dataUsageEmoteImages, s.emoteDownloadBytes),
    ]..sort((a, b) => b.$3.compareTo(a.$3));
    final total = s.totalBytes;
    final scheme = Theme.of(context).colorScheme;
    return SettingsPage(
      title: Text(l.settingDataUsage),
      body: ListView(
        children: [
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
