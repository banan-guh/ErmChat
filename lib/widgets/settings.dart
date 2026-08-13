import 'package:flutter/material.dart';
import '../models/emote_fetch_tier.dart';
import '../screens/settings/settings_screen.dart';
import '../services/analytics_service.dart';
import '../services/twitch_auth.dart';

class SettingsButton extends StatelessWidget {
  final TwitchAuth twitchAuth;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool>? onKeepScreenOnChanged;
  final ValueChanged<bool>? onTrueDarkChanged;
  final ValueChanged<String>? onAccentColorChanged;
  final ValueChanged<bool>? onTintedTabBarChanged;
  final ValueChanged<bool>? onBackgroundServiceChanged;
  final ValueChanged<bool>? onMentionPushChanged;
  final ValueChanged<int>? onEmoteTierChanged;
  final ValueChanged<int>? onEmoteCacheMaxChanged;
  final ValueChanged<EmoteFetchAutoMode>? onEmoteAutoModeChanged;
  final ValueNotifier<bool>? mobileNotifier;
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
    this.onAccentColorChanged,
    this.onTintedTabBarChanged,
    this.onBackgroundServiceChanged,
    this.onMentionPushChanged,
    this.onEmoteTierChanged,
    this.onEmoteCacheMaxChanged,
    this.onEmoteAutoModeChanged,
    this.mobileNotifier,
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
              onAccentColorChanged: onAccentColorChanged,
              onTintedTabBarChanged: onTintedTabBarChanged,
              onBackgroundServiceChanged: onBackgroundServiceChanged,
              onMentionPushChanged: onMentionPushChanged,
              onEmoteTierChanged: onEmoteTierChanged,
              onEmoteCacheMaxChanged: onEmoteCacheMaxChanged,
              onEmoteAutoModeChanged: onEmoteAutoModeChanged,
              mobileNotifier: mobileNotifier,
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
