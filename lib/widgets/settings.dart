import 'package:flutter/material.dart';
import '../screens/settings/settings_screen.dart';
import '../services/twitch_auth.dart';

class SettingsButton extends StatelessWidget {
  final TwitchAuth twitchAuth;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool>? onKeepScreenOnChanged;
  final ValueChanged<bool>? onBackgroundServiceChanged;
  final ValueChanged<bool>? onMentionPushChanged;
  final ValueNotifier<List<String>>? channelNotifier;
  final ValueChanged<String>? onLeaveChannel;
  final ValueChanged<String>? onAddChannel;
  final ValueChanged<List<String>>? onReorderChannels;
  final VoidCallback? onSettingsOpened;
  final VoidCallback? onSettingsClosed;

  const SettingsButton({
    super.key,
    required this.twitchAuth,
    required this.onThemeChanged,
    this.onKeepScreenOnChanged,
    this.onBackgroundServiceChanged,
    this.onMentionPushChanged,
    this.channelNotifier,
    this.onLeaveChannel,
    this.onAddChannel,
    this.onReorderChannels,
    this.onSettingsOpened,
    this.onSettingsClosed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.settings),
      onPressed: () {
        onSettingsOpened?.call();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SettingsScreen(
              twitchAuth: twitchAuth,
              onThemeChanged: onThemeChanged,
              onKeepScreenOnChanged: onKeepScreenOnChanged,
              onBackgroundServiceChanged: onBackgroundServiceChanged,
              onMentionPushChanged: onMentionPushChanged,
              channelNotifier: channelNotifier,
              onLeaveChannel: onLeaveChannel,
              onAddChannel: onAddChannel,
              onReorderChannels: onReorderChannels,
            ),
          ),
        ).then((_) => onSettingsClosed?.call());
      },
    );
  }
}
