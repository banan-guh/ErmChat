import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../util/log.dart';
import '../../util/prefs.dart';
import '../../models/emote_fetch_tier.dart';
import '../../services/fake_chat_feed.dart';
import '../../util/data_usage.dart';
import '../../widgets/app_snack.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';

class DevSettingsScreen extends StatefulWidget {
  final ValueChanged<bool>? onTestWidgetsChanged;

  /// Synthetic chat load for the selected channel; null hides its controls.
  final FakeChatFeed? fakeChat;
  final int Function()? fakeFillCount;

  const DevSettingsScreen({
    super.key,
    this.onTestWidgetsChanged,
    this.fakeChat,
    this.fakeFillCount,
  });

  @override
  State<DevSettingsScreen> createState() => _DevSettingsScreenState();
}

class _DevSettingsScreenState extends State<DevSettingsScreen> {
  Future<void> _replayIntro(BuildContext context) async {
    final prefs = await Prefs.load();
    await prefs.setWelcomeSeen(false);
    if (!context.mounted) return;
    AppSnack.show(context, 'The introduction shows on next launch');
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: const Text('Dev settings'),
      body: ListView(
        children: [
          PrefsSwitchTile(
            secondary: const Icon(Icons.bug_report_outlined),
            title: 'Test chat widgets',
            subtitle:
                'Show poll, prediction and hype train cards with updating fake data',
            defaultValue: false,
            read: (p) => p.testChatWidgets,
            write: (p, v) => p.setTestChatWidgets(v),
            onChanged: widget.onTestWidgetsChanged,
          ),
          PrefsSwitchTile(
            secondary: const Icon(Icons.how_to_vote_outlined),
            title: 'Live chat widgets',
            subtitle:
                'Real polls, predictions and hype trains. Pins always show',
            defaultValue: true,
            read: (p) => p.liveChatWidgets,
            write: (p, v) => p.setLiveChatWidgets(v),
          ),
          if (widget.fakeChat case final fake?) ...[
            const Divider(),
            ListTile(
              leading: const Icon(Icons.forum_outlined),
              title: const Text('Fake chat'),
              subtitle: Slider(
                value: fake.rate.clamp(0, 50).toDouble(),
                max: 50,
                divisions: 50,
                label: '${fake.rate} msgs/s',
                onChanged: (v) => setState(() => fake.setRate(v.round())),
              ),
              trailing: Text(
                fake.rate == 0 ? 'Off' : '${fake.rate}/s',
                textAlign: TextAlign.end,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.vertical_align_top),
              title: const Text('Fill to message limit'),
              subtitle: const Text('Into the selected channel'),
              onTap: () => fake.fill(widget.fakeFillCount?.call() ?? 500),
            ),
          ],
          const Divider(),
          PrefsSwitchTile(
            secondary: const Icon(Icons.language),
            title: 'Use browser for OAuth',
            subtitle:
                'Opens Twitch login in external browser instead of in-app WebView',
            defaultValue: false,
            read: (p) => p.useBrowserOAuth,
            write: (p, v) => p.setUseBrowserOAuth(v),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.replay),
            title: const Text('Replay introduction'),
            subtitle: const Text('Shows it again on next launch'),
            onTap: () => _replayIntro(context),
          ),
          const Divider(),
          PrefsSwitchTile(
            secondary: const Icon(Icons.new_releases_outlined),
            title: "Arm What's new",
            subtitle: 'Next launch shows it as if you just updated',
            defaultValue: false,
            read: (p) => p.armWhatsNew,
            write: (p, v) => p.setArmWhatsNew(v),
          ),
          PrefsSwitchTile(
            secondary: const Icon(Icons.system_update),
            title: 'Arm update available',
            subtitle:
                'Next launch fakes a newer version: snackbar, sheet, Settings banner',
            defaultValue: false,
            read: (p) => p.armUpdate,
            write: (p, v) => p.setArmUpdate(v),
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
