import 'package:flutter/material.dart';
import '../../models/emote_fetch_tier.dart';
import '../../services/analytics_service.dart';
import '../../services/twitch_auth.dart';
import '../../services/twitch_oauth.dart';
import '../../services/tts_controller.dart';
import 'about_screen.dart';
import 'account_screen.dart';
import 'channel_settings_screen.dart';
import 'chat_settings_screen.dart';
import 'customization_screen.dart';
import 'emotes_settings_screen.dart';
import 'tools_settings_screen.dart';

class SettingsScreen extends StatelessWidget {
  final TwitchAuth twitchAuth;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool>? onKeepScreenOnChanged;
  final ValueChanged<bool>? onTrueDarkChanged;
  final ValueChanged<String>? onAccentColorChanged;
  final ValueChanged<bool>? onBackgroundServiceChanged;
  final ValueChanged<bool>? onMentionPushChanged;
  final ValueChanged<int>? onMaxMessagesPerChannelChanged;
  final ValueChanged<int>? onRecentMessagesChanged;
  final ValueChanged<bool>? onReplyToRootChanged;
  final ValueChanged<bool>? onPreferEmotesFirstChanged;
  final ValueChanged<bool>? onShowTimestampsChanged;
  final ValueChanged<String>? onTimestampFormatChanged;
  final ValueChanged<double>? onChatFontScaleChanged;
  final ValueChanged<bool>? onAnimateGifsChanged;
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
  final OAuthStarter? oAuthStarter;
  final TtsController? ttsController;

  const SettingsScreen({
    super.key,
    required this.twitchAuth,
    required this.onThemeChanged,
    this.onKeepScreenOnChanged,
    this.onTrueDarkChanged,
    this.onAccentColorChanged,
    this.onBackgroundServiceChanged,
    this.onMentionPushChanged,
    this.onMaxMessagesPerChannelChanged,
    this.onRecentMessagesChanged,
    this.onReplyToRootChanged,
    this.onPreferEmotesFirstChanged,
    this.onShowTimestampsChanged,
    this.onTimestampFormatChanged,
    this.onChatFontScaleChanged,
    this.onAnimateGifsChanged,
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
    this.oAuthStarter,
    this.ttsController,
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
                builder: (_) => CustomizationScreen(
                  onThemeChanged: onThemeChanged,
                  onKeepScreenOnChanged: onKeepScreenOnChanged,
                  onTrueDarkChanged: onTrueDarkChanged,
                  onAccentColorChanged: onAccentColorChanged,
                  onChatFontScaleChanged: onChatFontScaleChanged,
                  onAnimateGifsChanged: onAnimateGifsChanged,
                ),
              ),
            ),
          ),
          _buildTile(
            context,
            icon: Icons.chat_bubble,
            title: 'Chat',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatSettingsScreen(
                  onBackgroundServiceChanged: onBackgroundServiceChanged,
                  onMentionPushChanged: onMentionPushChanged,
                  onMaxMessagesPerChannelChanged:
                      onMaxMessagesPerChannelChanged,
                  onRecentMessagesChanged: onRecentMessagesChanged,
                  onReplyToRootChanged: onReplyToRootChanged,
                  onPreferEmotesFirstChanged: onPreferEmotesFirstChanged,
                  onShowTimestampsChanged: onShowTimestampsChanged,
                  onTimestampFormatChanged: onTimestampFormatChanged,
                ),
              ),
            ),
          ),
          _buildTile(
            context,
            icon: Icons.emoji_emotions,
            title: 'Emotes',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => EmotesSettingsScreen(
                  onEmoteTierChanged: onEmoteTierChanged,
                  onEmoteCacheMaxChanged: onEmoteCacheMaxChanged,
                  onEmoteAutoModeChanged: onEmoteAutoModeChanged,
                  mobileNotifier: mobileNotifier,
                ),
              ),
            ),
          ),
          if (analyticsService != null && channels != null)
            _buildTile(
              context,
              icon: Icons.handyman,
              title: 'Tools',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ToolsSettingsScreen(
                    analyticsService: analyticsService,
                    channels: channels,
                    ttsController: ttsController,
                  ),
                ),
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
