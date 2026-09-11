import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../util/log.dart';
import '../../util/prefs.dart';
import '../../models/emote_fetch_tier.dart';
import '../../util/data_usage.dart';
import '../../widgets/app_snack.dart';
import '../../widgets/welcome_dialog.dart';
import 'settings_page.dart';

class DevSettingsScreen extends StatefulWidget {
  final ValueChanged<bool>? onTestWidgetsChanged;

  const DevSettingsScreen({super.key, this.onTestWidgetsChanged});

  @override
  State<DevSettingsScreen> createState() => _DevSettingsScreenState();
}

class _DevSettingsScreenState extends State<DevSettingsScreen> {
  bool _testWidgets = false;
  bool _useBrowserOAuth = false;

  @override
  void initState() {
    super.initState();
    _loadTestWidgetsPref();
    _loadOAuthMode();
  }

  Future<void> _loadTestWidgetsPref() async {
    final prefs = await Prefs.load();
    if (!mounted) return;
    setState(() => _testWidgets = prefs.testChatWidgets);
  }

  Future<void> _setTestWidgets(bool value) async {
    final prefs = await Prefs.load();
    await prefs.setTestChatWidgets(value);
    if (mounted) setState(() => _testWidgets = value);
    widget.onTestWidgetsChanged?.call(value);
  }

  Future<void> _loadOAuthMode() async {
    final prefs = await Prefs.load();
    if (!mounted) return;
    setState(() => _useBrowserOAuth = prefs.useBrowserOAuth);
  }

  Future<void> _setOAuthMode(bool value) async {
    final prefs = await Prefs.load();
    await prefs.setUseBrowserOAuth(value);
    if (mounted) setState(() => _useBrowserOAuth = value);
  }

  Future<void> _replayWelcomeScreen(BuildContext context) async {
    if (kIsWeb) return;
    final prefs = await Prefs.load();
    await prefs.setWelcomeSeen(false);
    if (!context.mounted) return;
    showWelcomeDialog(context);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: const Text('Dev settings'),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.bug_report_outlined),
            title: const Text('Test chat widgets'),
            subtitle: const Text(
              'Show poll, prediction and hype train cards with updating fake data',
            ),
            value: _testWidgets,
            onChanged: _setTestWidgets,
          ),
          const Divider(),
          SwitchListTile(
            secondary: const Icon(Icons.language),
            title: const Text('Use browser for OAuth'),
            subtitle: const Text(
              'Opens Twitch login in external browser instead of in-app WebView',
            ),
            value: _useBrowserOAuth,
            onChanged: _setOAuthMode,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.replay),
            title: const Text('Replay welcome screen'),
            subtitle: const Text('Show the first-launch popup again'),
            onTap: () => _replayWelcomeScreen(context),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.receipt_long),
            title: const Text('Performance log'),
            subtitle: const Text(
              'Freeze diagnostics: lifecycle, truncation, sheet animations',
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const _PerfLogScreen()),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PerfLogScreen extends StatefulWidget {
  const _PerfLogScreen();

  @override
  State<_PerfLogScreen> createState() => _PerfLogScreenState();
}

class _PerfLogScreenState extends State<_PerfLogScreen> {
  List<String>? _previousSession;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreviousSession());
  }

  Future<void> _loadPreviousSession() async {
    final text = await PerfLog.I.readPreviousSession();
    if (!mounted) return;
    setState(() {
      _previousSession = text?.split('\n').where((l) => l.isNotEmpty).toList();
    });
  }

  void _copyAll() {
    final buffer = StringBuffer();
    if (_previousSession != null) {
      buffer
        ..writeln('=== previous session ===')
        ..writeAll(_previousSession!, '\n')
        ..writeln();
    }
    buffer
      ..writeln('=== current session ===')
      ..writeAll(PerfLog.I.entries(), '\n')
      ..writeln();
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    AppSnack.show(context, 'Copied ${PerfLog.I.entries().length} entries');
  }

  @override
  Widget build(BuildContext context) {
    final current = PerfLog.I.entries().reversed.toList();
    return SettingsPage(
      title: const Text('Performance log'),
      actions: [
        IconButton(
          icon: const Icon(Icons.copy),
          tooltip: 'Copy all',
          onPressed: _copyAll,
        ),
      ],
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Current session: ${current.length} entries',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (_previousSession != null)
                  Text(
                    'Previous: ${_previousSession!.length} entries',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Data usage (since launch)',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'total ${DataUsageStats.I.totalBytes}B\n'
                      'IRC read ${DataUsageStats.I.ircReadBytes}B  '
                      'write ${DataUsageStats.I.ircWriteBytes}B\n'
                      'emote images ${DataUsageStats.I.emoteDownloadBytes}B  '
                      'JSON ${DataUsageStats.I.jsonBytes}B\n'
                      'cache evictions ${DataUsageStats.I.evictions}  '
                      'tier ${DataUsageStats.I.appliedTier?.label ?? '?'}  '
                      'mobile ${DataUsageStats.I.mobile}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: current.length + (_previousSession?.length ?? 0),
              itemBuilder: (context, i) {
                final isPrev = i >= current.length;
                final line = isPrev
                    ? _previousSession![i - current.length]
                    : current[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 1,
                  ),
                  child: SelectableText(
                    line,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: isPrev
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
