import 'package:flutter/material.dart';
import '../../models/emote_fetch_tier.dart';
import '../../services/analytics_service.dart';
import '../../services/emote_manager.dart';
import '../../services/twitch_auth.dart';
import '../../services/twitch_oauth.dart';
import '../../services/tts_controller.dart';
import 'about_screen.dart';
import 'account_screen.dart';
import 'channel_settings_screen.dart';
import 'chat_settings_screen.dart';
import 'customization_screen.dart';
import 'emotes_settings_screen.dart';
import 'settings_page.dart';
import 'stream_settings_screen.dart';
import 'tools_settings_screen.dart';
import '../../services/recent_messages.dart';

class SettingsScreen extends StatelessWidget {
  final TwitchAuth twitchAuth;
  final ValueChanged<bool>? onBackgroundServiceChanged;
  final ValueChanged<bool>? onMentionPushChanged;
  final ValueChanged<bool>? onWhisperNotifyChanged;
  final ValueChanged<RecentMessagesConfig>? onRecentMessagesModeChanged;
  final ValueChanged<int>? onEmoteTierChanged;
  final ValueChanged<int>? onEmoteCacheMaxChanged;
  final ValueChanged<EmoteFetchAutoMode>? onEmoteAutoModeChanged;
  final VoidCallback? onNukeEmotes;
  final ValueNotifier<bool>? mobileNotifier;
  final ValueNotifier<List<String>>? channelNotifier;
  final ValueChanged<String>? onLeaveChannel;
  final ValueChanged<String>? onAddChannel;
  final ValueChanged<List<String>>? onReorderChannels;
  final AnalyticsService? analyticsService;
  final List<String>? channels;
  final OAuthStarter? oAuthStarter;
  final TtsController? ttsController;
  final EmoteManager? emoteManager;
  final ValueChanged<bool>? onStreamExtensionsChanged;
  final ValueChanged<bool>? onRetainWebviewChanged;
  final ValueChanged<bool>? onPipEnabledChanged;

  /// Live hook for the dev-only test-widgets toggle (About > 7 taps).
  final ValueChanged<bool>? onTestWidgetsChanged;

  const SettingsScreen({
    super.key,
    required this.twitchAuth,
    this.onBackgroundServiceChanged,
    this.onMentionPushChanged,
    this.onWhisperNotifyChanged,
    this.onRecentMessagesModeChanged,
    this.onEmoteTierChanged,
    this.onEmoteCacheMaxChanged,
    this.onEmoteAutoModeChanged,
    this.onNukeEmotes,
    this.mobileNotifier,
    this.channelNotifier,
    this.onLeaveChannel,
    this.onAddChannel,
    this.onReorderChannels,
    this.analyticsService,
    this.channels,
    this.oAuthStarter,
    this.ttsController,
    this.emoteManager,
    this.onStreamExtensionsChanged,
    this.onRetainWebviewChanged,
    this.onPipEnabledChanged,
    this.onTestWidgetsChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: const Text('Settings'),
      body: ListView(
        children: [
          SettingsNavTile(
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
          SettingsNavTile(
            icon: Icons.palette,
            title: 'Customization',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CustomizationScreen()),
            ),
          ),
          SettingsNavTile(
            icon: Icons.chat_bubble,
            title: 'Chat',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatSettingsScreen(
                  twitchAuth: twitchAuth,
                  onBackgroundServiceChanged: onBackgroundServiceChanged,
                  onMentionPushChanged: onMentionPushChanged,
                  onWhisperNotifyChanged: onWhisperNotifyChanged,
                ),
              ),
            ),
          ),
          SettingsNavTile(
            icon: Icons.emoji_emotions,
            title: 'Emotes',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => EmotesSettingsScreen(
                  onEmoteTierChanged: onEmoteTierChanged,
                  onEmoteCacheMaxChanged: onEmoteCacheMaxChanged,
                  onEmoteAutoModeChanged: onEmoteAutoModeChanged,
                  onNukeEmotes: onNukeEmotes,
                  mobileNotifier: mobileNotifier,
                  emoteManager: emoteManager,
                ),
              ),
            ),
          ),
          SettingsNavTile(
            icon: Icons.play_arrow,
            title: 'Livestreams',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => StreamSettingsScreen(
                  onShowExtensionsChanged: onStreamExtensionsChanged,
                  onRetainWebviewChanged: onRetainWebviewChanged,
                  onPipEnabledChanged: onPipEnabledChanged,
                ),
              ),
            ),
          ),
          if (analyticsService != null && channels != null)
            SettingsNavTile(
              icon: Icons.handyman,
              title: 'Tools',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ToolsSettingsScreen(
                    analyticsService: analyticsService,
                    channels: channels,
                    ttsController: ttsController,
                    onRecentMessagesModeChanged: onRecentMessagesModeChanged,
                    images: emoteManager?.images,
                  ),
                ),
              ),
            ),
          SettingsNavTile(
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
          SettingsNavTile(
            icon: Icons.info,
            title: 'About',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    AboutScreen(onTestWidgetsChanged: onTestWidgetsChanged),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
