import 'dart:async';
import 'package:flutter/material.dart';
import '../models/twitch_message.dart';
import '../screens/settings_screen.dart';
import '../services/twitch_auth.dart';

class SettingsButton extends StatelessWidget {
  final TwitchAuth twitchAuth;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueNotifier<List<String>>? channelNotifier;
  final ValueChanged<String>? onLeaveChannel;
  final ValueChanged<String>? onAddChannel;
  final ValueChanged<List<String>>? onReorderChannels;
  final VoidCallback? onSettingsClosed;
  final Stream<TwitchMessage>? eventSubMessageStream;

  const SettingsButton({
    super.key,
    required this.twitchAuth,
    required this.onThemeChanged,
    this.channelNotifier,
    this.onLeaveChannel,
    this.onAddChannel,
    this.onReorderChannels,
    this.onSettingsClosed,
    this.eventSubMessageStream,
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
            eventSubMessageStream: eventSubMessageStream,
          ),
        ),
      ).then((_) => onSettingsClosed?.call()),
    );
  }
}
