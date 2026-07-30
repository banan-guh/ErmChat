import 'package:flutter/material.dart';
import '../../services/twitch_auth.dart';
import 'about_screen.dart';
import 'account_screen.dart';
import 'channel_settings_screen.dart';
import 'chat_settings_screen.dart';
import 'customization_screen.dart';

typedef OAuthStarter = Future<String?> Function(BuildContext context);

class SettingsScreen extends StatelessWidget {
  final TwitchAuth twitchAuth;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueNotifier<List<String>>? channelNotifier;
  final ValueChanged<String>? onLeaveChannel;
  final ValueChanged<String>? onAddChannel;
  final ValueChanged<List<String>>? onReorderChannels;
  final OAuthStarter? oAuthStarter;

  const SettingsScreen({
    super.key,
    required this.twitchAuth,
    required this.onThemeChanged,
    this.channelNotifier,
    this.onLeaveChannel,
    this.onAddChannel,
    this.onReorderChannels,
    this.oAuthStarter,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _buildTile(
            context,
            icon: Icons.tag,
            title: 'Channels',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChannelSettingsScreen(
                  channelNotifier: channelNotifier!,
                  onAddChannel: onAddChannel,
                  onLeaveChannel: onLeaveChannel,
                  onReorderChannels: onReorderChannels,
                ),
              ),
            ),
          ),
          _buildTile(
            context,
            icon: Icons.palette,
            title: 'Customization',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    CustomizationScreen(onThemeChanged: onThemeChanged),
              ),
            ),
          ),
          _buildTile(
            context,
            icon: Icons.chat_bubble,
            title: 'Chat',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ChatSettingsScreen()),
            ),
          ),
          _buildTile(
            context,
            icon: Icons.person,
            title: 'Account',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AccountScreen(
                  twitchAuth: twitchAuth,
                  oAuthStarter: oAuthStarter,
                ),
              ),
            ),
          ),
          _buildTile(
            context,
            icon: Icons.info,
            title: 'About',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AboutScreen()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
