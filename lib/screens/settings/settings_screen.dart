import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../models/emote_fetch_tier.dart';
import '../../services/analytics_service.dart';
import '../../services/emote_manager.dart';
import '../../services/twitch_auth.dart';
import '../../services/twitch_oauth.dart';
import '../../services/tts_controller.dart';
import '../../services/fake_chat_feed.dart';
import 'about_screen.dart';
import 'account_screen.dart';
import 'channel_settings_screen.dart';
import 'chat_settings_screen.dart';
import 'custom_layout_screen.dart';
import 'customization_screen.dart';
import 'emotes_settings_screen.dart';
import 'inline_embeds_screen.dart';
import 'language_screen.dart';
import 'pings_screen.dart';
import 'report_bug_screen.dart';
import 'settings_page.dart';
import 'settings_search.dart';
import 'tools_settings_screen.dart';
import 'tts_settings_screen.dart';
import 'uploader_settings_screen.dart';
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
  final void Function(String from, String to)? onRenameChannel;
  final AnalyticsService? analyticsService;
  final List<String>? channels;
  final OAuthStarter? oAuthStarter;
  final TtsController? ttsController;
  final EmoteManager? emoteManager;
  final ValueChanged<bool>? onPipEnabledChanged;

  /// Live hook for the dev-only test-widgets toggle (About > 7 taps).
  final ValueChanged<bool>? onTestWidgetsChanged;

  /// Dev-only synthetic chat load and the fill size (message limit).
  final FakeChatFeed? fakeChat;
  final int Function()? fakeFillCount;

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
    this.onRenameChannel,
    this.analyticsService,
    this.channels,
    this.oAuthStarter,
    this.ttsController,
    this.emoteManager,
    this.onPipEnabledChanged,
    this.onTestWidgetsChanged,
    this.fakeChat,
    this.fakeFillCount,
  });

  // One builder per destination, shared by the tiles and the search index.
  Widget _channels() => ChannelSettingsScreen(
    channelNotifier: channelNotifier!,
    onAddChannel: onAddChannel,
    onLeaveChannel: onLeaveChannel,
    onReorderChannels: onReorderChannels,
    onRenameChannel: onRenameChannel,
  );

  Widget _appearance() => const CustomizationScreen();

  Widget _chat() => ChatSettingsScreen(
    twitchAuth: twitchAuth,
    onBackgroundServiceChanged: onBackgroundServiceChanged,
    onRecentMessagesModeChanged: onRecentMessagesModeChanged,
  );

  Widget _highlights() => PingsScreen(
    onMentionPushChanged: onMentionPushChanged,
    onWhisperNotifyChanged: onWhisperNotifyChanged,
    onBackgroundServiceChanged: onBackgroundServiceChanged,
  );

  Widget _emotes() => EmotesSettingsScreen(
    onEmoteTierChanged: onEmoteTierChanged,
    onEmoteCacheMaxChanged: onEmoteCacheMaxChanged,
    onEmoteAutoModeChanged: onEmoteAutoModeChanged,
    onNukeEmotes: onNukeEmotes,
    mobileNotifier: mobileNotifier,
    emoteManager: emoteManager,
  );

  Widget _tools() => ToolsSettingsScreen(
    analyticsService: analyticsService,
    channels: channels,
    ttsController: ttsController,
    images: emoteManager?.images,
    onPipEnabledChanged: onPipEnabledChanged,
  );

  Widget _account() =>
      AccountScreen(twitchAuth: twitchAuth, oAuthStarter: oAuthStarter);

  Widget _about() => AboutScreen(
    onTestWidgetsChanged: onTestWidgetsChanged,
    fakeChat: fakeChat,
    fakeFillCount: fakeFillCount,
  );

  Widget _tts() => TtsSettingsScreen(ttsController: ttsController);

  static void _go(BuildContext context, Widget Function() screen) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => screen()));

  Widget _page(SettingsPageId page) => switch (page) {
    SettingsPageId.channels => _channels(),
    SettingsPageId.appearance => _appearance(),
    SettingsPageId.customLayout => const CustomLayoutScreen(),
    SettingsPageId.chat => _chat(),
    SettingsPageId.inlineEmbeds => const InlineEmbedsScreen(),
    SettingsPageId.highlights => _highlights(),
    SettingsPageId.emotes => _emotes(),
    SettingsPageId.tools => _tools(),
    SettingsPageId.tts => _tts(),
    SettingsPageId.uploader => const UploaderSettingsScreen(),
    SettingsPageId.account => _account(),
    SettingsPageId.about => _about(),
    SettingsPageId.language => const LanguageScreen(),
  };

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.settingsTitle),
      actions: [
        // A symbol, so anyone stuck in a language they cannot read finds it.
        IconButton(
          icon: const Icon(Icons.translate),
          tooltip: context.l10n.settingLanguage,
          onPressed: () => _go(context, () => const LanguageScreen()),
        ),
        const SizedBox(width: 12),
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: context.l10n.searchSettings,
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SettingsSearchPage(openPage: _page),
            ),
          ),
        ),
      ],
      body: ListView(
        children: [
          SettingsNavTile(
            icon: Icons.tag,
            title: Setting.channels.titleOf(context.l10n),
            onTap: () => _go(context, _channels),
          ),
          SettingsNavTile(
            icon: Icons.palette,
            title: context.l10n.pageAppearance,
            onTap: () => _go(context, _appearance),
          ),
          SettingsNavTile(
            icon: Icons.chat_bubble,
            title: context.l10n.pageChat,
            onTap: () => _go(context, _chat),
          ),
          SettingsNavTile(
            icon: Icons.notifications,
            title: context.l10n.pageHighlights,
            onTap: () => _go(context, _highlights),
          ),
          SettingsNavTile(
            icon: Icons.emoji_emotions,
            title: context.l10n.pageEmotes,
            onTap: () => _go(context, _emotes),
          ),
          const Divider(),
          SettingsNavTile(
            icon: Icons.handyman,
            title: context.l10n.pageTools,
            onTap: () => _go(context, _tools),
          ),
          SettingsNavTile(
            icon: Icons.person,
            title: Setting.account.titleOf(context.l10n),
            onTap: () => _go(context, _account),
          ),
          // Reports carry the signed-in Twitch identity, so the entry only
          // shows for a real account.
          if (twitchAuth.isConfigured)
            SettingsNavTile(
              icon: Icons.bug_report,
              title: context.l10n.sendFeedback,
              onTap: () => _go(context, ReportBugScreen.new),
            ),
          SettingsNavTile(
            icon: Icons.info,
            title: Setting.about.titleOf(context.l10n),
            onTap: () => _go(context, _about),
          ),
        ],
      ),
    );
  }
}
