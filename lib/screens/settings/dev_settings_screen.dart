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
import '../../util/settings.dart';

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
            pref: Settings.testChatWidgets,
            onChanged: widget.onTestWidgetsChanged,
          ),
          PrefsSwitchTile(
            secondary: const Icon(Icons.how_to_vote_outlined),
            title: 'Live chat widgets',
            subtitle:
                'Real polls, predictions and hype trains. Pins always show',
            pref: Settings.liveChatWidgets,
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
            pref: Settings.useBrowserOAuth,
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
            pref: Settings.armWhatsNew,
          ),
          PrefsSwitchTile(
            secondary: const Icon(Icons.system_update),
            title: 'Arm update available',
            subtitle:
                'Next launch fakes a newer version: snackbar, sheet, Settings banner',
            pref: Settings.armUpdate,
          ),
          PrefsSwitchTile(
            secondary: const Icon(Icons.gavel),
            title: 'Always show mod actions',
            subtitle:
                'User cards show timeout, ban and warn in any channel. Twitch still refuses them without mod',
            pref: Settings.forceModActions,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.receipt_long),
            title: const Text('App log'),
            subtitle: const Text('Recent sessions, newest first'),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const _AppLogScreen()),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AppLogScreen extends StatefulWidget {
  const _AppLogScreen();

  @override
  State<_AppLogScreen> createState() => _AppLogScreenState();
}

class _AppLogScreenState extends State<_AppLogScreen> {
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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Data usage (since launch)',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'total ${DataUsageStats.I.totalBytes}B\n'
                      'IRC read ${DataUsageStats.I.ircReadBytes}B  '
                      'write ${DataUsageStats.I.ircWriteBytes}B\n'
                      'emote images ${DataUsageStats.I.emoteDownloadBytes}B  '
                      'JSON ${DataUsageStats.I.jsonBytes}B\n'
                      'cache evictions ${DataUsageStats.I.evictions}  '
                      'refetched ${DataUsageStats.I.refetches}  '
                      'tier ${DataUsageStats.I.appliedTier?.label ?? '?'}  '
                      'mobile ${DataUsageStats.I.mobile}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
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
