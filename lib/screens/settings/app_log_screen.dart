import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../util/log.dart';
import '../../widgets/app_snack.dart';
import 'settings_page.dart';

class AppLogScreen extends StatefulWidget {
  const AppLogScreen({super.key});

  @override
  State<AppLogScreen> createState() => _AppLogScreenState();
}

class _AppLogScreenState extends State<AppLogScreen> {
  List<String>? _entries;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final entries = await AppLog.I.read();
    if (mounted) setState(() => _entries = entries);
  }

  void _copy() {
    final entries = _entries;
    if (entries == null) return;
    final (text, copied) = AppLog.copyText(entries);
    Clipboard.setData(ClipboardData(text: text));
    AppSnack.show(
      context,
      copied < entries.length
          ? 'Copied the newest $copied of ${entries.length} entries'
          : 'Copied $copied entries',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entries;
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 11);
    final session = mono.copyWith(color: theme.colorScheme.primary);
    return SettingsPage(
      title: const Text('App log'),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Reload',
          onPressed: _load,
        ),
        IconButton(
          icon: const Icon(Icons.copy),
          tooltip: 'Copy newest first',
          onPressed: _copy,
        ),
      ],
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                entries == null
                    ? 'Loading'
                    : '${entries.length} entries, newest first',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          // One selection area over the whole list, so a drag selects
          // across entries.
          Expanded(
            child: entries == null
                ? const SizedBox.shrink()
                : SelectionArea(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: entries.length,
                      itemBuilder: (_, i) {
                        final entry = entries[i];
                        return Text(
                          entry,
                          style: entry.endsWith('[LOG] session start')
                              ? session
                              : mono,
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
