import 'package:flutter/material.dart';

import '../../util/prefs.dart';
import '../../services/fake_chat_feed.dart';
import '../../widgets/app_snack.dart';
import 'app_log_screen.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';
import '../../util/settings.dart';

class DevSettingsScreen extends StatefulWidget {
  final ValueChanged<bool>? onTestWidgetsChanged;

  /// Synthetic chat load for the selected channel; null hides its controls.
  final FakeChatFeed? fakeChat;

  const DevSettingsScreen({
    super.key,
    this.onTestWidgetsChanged,
    this.fakeChat,
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
          PrefsSwitchTile(
            secondary: const Icon(Icons.live_tv_outlined),
            title: 'Show stream on offline channels',
            subtitle:
                'Adds Show stream to the view menu when the channel is not live',
            pref: Settings.devShowOfflineStream,
          ),
          PrefsSwitchTile(
            secondary: const Icon(Icons.shield_outlined),
            title: 'Always show mod tools',
            subtitle:
                'Mod view and message actions stay available on channels you own or moderate, without waiting for EventSub',
            pref: Settings.devForceModTools,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.receipt_long),
            title: const Text('App log'),
            subtitle: const Text('Recent sessions, newest first'),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AppLogScreen()),
              );
            },
          ),
        ],
      ),
    );
  }
}
