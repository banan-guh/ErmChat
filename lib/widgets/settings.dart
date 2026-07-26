import 'package:flutter/material.dart';
import '../screens/settings/settings_screen.dart';
import '../services/twitch_auth.dart';

class SettingsButton extends StatelessWidget {
  final TwitchAuth twitchAuth;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueNotifier<List<String>>? channelNotifier;
  final ValueChanged<String>? onLeaveChannel;
  final ValueChanged<String>? onAddChannel;
  final ValueChanged<List<String>>? onReorderChannels;
  final VoidCallback? onSettingsClosed;

  const SettingsButton({
    super.key,
    required this.twitchAuth,
    required this.onThemeChanged,
    this.channelNotifier,
    this.onLeaveChannel,
    this.onAddChannel,
    this.onReorderChannels,
    this.onSettingsClosed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.settings),
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SettingsScreen(
            twitchAuth: twitchAuth,
            onThemeChanged: onThemeChanged,
            channelNotifier: channelNotifier,
            onLeaveChannel: onLeaveChannel,
            onAddChannel: onAddChannel,
            onReorderChannels: onReorderChannels,
          ),
        ),
      ).then((_) => onSettingsClosed?.call()),
    );
  }
}
