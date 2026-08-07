import 'package:flutter/material.dart';
import '../screens/settings/settings_screen.dart';
import '../services/analytics_service.dart';
import '../services/twitch_auth.dart';

class SettingsButton extends StatelessWidget {
  final TwitchAuth twitchAuth;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool>? onKeepScreenOnChanged;
  final ValueChanged<bool>? onTrueDarkChanged;
  final ValueChanged<bool>? onBackgroundServiceChanged;
  final ValueChanged<bool>? onMentionPushChanged;
  final ValueNotifier<List<String>>? channelNotifier;
  final ValueChanged<String>? onLeaveChannel;
  final ValueChanged<String>? onAddChannel;
  final ValueChanged<List<String>>? onReorderChannels;
  final AnalyticsService? analyticsService;
  final List<String>? channels;
  final VoidCallback? onSettingsOpened;
  final VoidCallback? onSettingsClosed;

  const SettingsButton({
    super.key,
    required this.twitchAuth,
    required this.onThemeChanged,
    this.onKeepScreenOnChanged,
    this.onTrueDarkChanged,
    this.onBackgroundServiceChanged,
    this.onMentionPushChanged,
    this.channelNotifier,
    this.onLeaveChannel,
    this.onAddChannel,
    this.onReorderChannels,
    this.analyticsService,
    this.channels,
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
              onTrueDarkChanged: onTrueDarkChanged,
              onBackgroundServiceChanged: onBackgroundServiceChanged,
              onMentionPushChanged: onMentionPushChanged,
              channelNotifier: channelNotifier,
              onLeaveChannel: onLeaveChannel,
              onAddChannel: onAddChannel,
              onReorderChannels: onReorderChannels,
              analyticsService: analyticsService,
              channels: channels,
            ),
          ),
        ).then((_) => onSettingsClosed?.call());
      },
    );
  }
}
