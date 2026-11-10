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
import 'battery_settings_screen.dart';
import 'chat_settings_screen.dart';
import 'data_settings_screen.dart';
import 'history_settings_screen.dart';
import 'custom_layout_screen.dart';
import 'customization_screen.dart';
import 'emotes_settings_screen.dart';
import 'inline_embeds_screen.dart';
import 'language_screen.dart';
import 'pings_screen.dart';
import 'settings_page.dart';
import 'settings_search.dart';
import 'tools_settings_screen.dart';
import 'tts_settings_screen.dart';
import 'uploader_settings_screen.dart';
import '../../services/recent_messages.dart';
import '../../widgets/update_banner.dart';

/// One settings page: how to build it, and how the root list shows it.
typedef _PageEntry = ({
  Widget Function() build,
  // Tile icon, drawn only when the page is [listed].
  IconData icon,
  // The tile's title in the app language.
  String Function(AppLocalizations) title,
  // Whether the root list has a tile; the rest open from search only.
  bool listed,
  // Whether a divider closes this tile's group in the root list.
  bool endsGroup,
});

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

  /// Closes settings and puts the home screen into layout edit mode.
  final VoidCallback? onEditLayout;
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

  /// Runs after the shared WebView session changed, so a live player can
  /// pick it up.
  final VoidCallback? onWebSessionChanged;

  /// Live hook for the dev-only test-widgets toggle (About > 7 taps).
  final ValueChanged<bool>? onTestWidgetsChanged;

  /// Dev-only synthetic chat load and the fill size (message limit).
  final FakeChatFeed? fakeChat;

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
    this.onEditLayout,
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
    this.onWebSessionChanged,
    this.onTestWidgetsChanged,
    this.fakeChat,
  });

  // Every page in one table: adding a page is one entry here, not a builder,
  // a switch case and a tile.
  //
  // Insertion order is enum order, so the root list, which draws the [listed]
  // entries in this order, keeps its sections (divider after the last tile of
  // each group). Pages searched to instead of listed keep an icon and title so
  // every entry is shaped the same.
  Map<SettingsPageId, _PageEntry> get _pages => {
    SettingsPageId.channels: (
      build: () => ChannelSettingsScreen(
        channelNotifier: channelNotifier!,
        onAddChannel: onAddChannel,
        onLeaveChannel: onLeaveChannel,
        onReorderChannels: onReorderChannels,
        onRenameChannel: onRenameChannel,
      ),
      icon: Icons.tag,
      title: (l) => l.pageChannels,
      listed: true,
      endsGroup: false,
    ),
    SettingsPageId.appearance: (
      build: () => CustomizationScreen(onEditLayout: onEditLayout),
      icon: Icons.palette,
      title: (l) => l.pageAppearance,
      listed: true,
      endsGroup: false,
    ),
    SettingsPageId.customLayout: (
      build: () => const CustomLayoutScreen(),
      icon: Icons.dashboard_customize,
      title: (l) => l.pageCustomLayout,
      listed: false,
      endsGroup: false,
    ),
    SettingsPageId.chat: (
      build: () => ChatSettingsScreen(
        twitchAuth: twitchAuth,
        onBackgroundServiceChanged: onBackgroundServiceChanged,
      ),
      icon: Icons.chat_bubble,
      title: (l) => l.pageChat,
      listed: true,
      endsGroup: false,
    ),
    SettingsPageId.inlineEmbeds: (
      build: () => const InlineEmbedsScreen(),
      icon: Icons.image,
      title: (l) => l.pageInlineEmbeds,
      listed: false,
      endsGroup: false,
    ),
    SettingsPageId.highlights: (
      build: () => PingsScreen(
        onMentionPushChanged: onMentionPushChanged,
        onWhisperNotifyChanged: onWhisperNotifyChanged,
        onBackgroundServiceChanged: onBackgroundServiceChanged,
      ),
      icon: Icons.notifications,
      title: (l) => l.pageHighlights,
      listed: true,
      endsGroup: false,
    ),
    SettingsPageId.emotes: (
      build: () => EmotesSettingsScreen(
        onEmoteTierChanged: onEmoteTierChanged,
        onEmoteCacheMaxChanged: onEmoteCacheMaxChanged,
        onEmoteAutoModeChanged: onEmoteAutoModeChanged,
        onNukeEmotes: onNukeEmotes,
        mobileNotifier: mobileNotifier,
        emoteManager: emoteManager,
      ),
      icon: Icons.emoji_emotions,
      title: (l) => l.pageEmotes,
      listed: true,
      endsGroup: true,
    ),
    SettingsPageId.data: (
      build: () => DataSettingsScreen(
        mobileNotifier: mobileNotifier,
        onEmoteTierChanged: onEmoteTierChanged,
        onEmoteAutoModeChanged: onEmoteAutoModeChanged,
        onEmoteCacheMaxChanged: onEmoteCacheMaxChanged,
        onNukeEmotes: onNukeEmotes,
        images: emoteManager?.images,
      ),
      icon: Icons.data_usage,
      title: (l) => l.pageData,
      listed: true,
      endsGroup: false,
    ),
    SettingsPageId.history: (
      build: () => HistorySettingsScreen(
        onRecentMessagesModeChanged: onRecentMessagesModeChanged,
      ),
      icon: Icons.history,
      title: (l) => l.pageHistory,
      listed: true,
      endsGroup: false,
    ),
    SettingsPageId.battery: (
      build: () => BatterySettingsScreen(
        onBackgroundServiceChanged: onBackgroundServiceChanged,
      ),
      icon: Icons.battery_saver,
      title: (l) => l.pageBattery,
      listed: true,
      endsGroup: true,
    ),
    SettingsPageId.tools: (
      build: () => ToolsSettingsScreen(
        analyticsService: analyticsService,
        channels: channels,
        ttsController: ttsController,
        images: emoteManager?.images,
        onPipEnabledChanged: onPipEnabledChanged,
        showFeedback: twitchAuth.isConfigured,
      ),
      icon: Icons.handyman,
      title: (l) => l.pageTools,
      listed: true,
      endsGroup: false,
    ),
    SettingsPageId.tts: (
      build: () => TtsSettingsScreen(ttsController: ttsController),
      icon: Icons.record_voice_over,
      title: (l) => l.pageTts,
      listed: false,
      endsGroup: false,
    ),
    SettingsPageId.uploader: (
      build: () => const UploaderSettingsScreen(),
      icon: Icons.upload,
      title: (l) => l.pageUploader,
      listed: false,
      endsGroup: false,
    ),
    SettingsPageId.account: (
      build: () => AccountScreen(
        twitchAuth: twitchAuth,
        oAuthStarter: oAuthStarter,
        onWebSessionChanged: onWebSessionChanged,
      ),
      icon: Icons.person,
      title: (l) => l.pageAccount,
      listed: true,
      endsGroup: false,
    ),
    SettingsPageId.about: (
      build: () => AboutScreen(
        onTestWidgetsChanged: onTestWidgetsChanged,
        fakeChat: fakeChat,
      ),
      icon: Icons.info,
      title: (l) => l.pageAbout,
      listed: true,
      endsGroup: false,
    ),
    SettingsPageId.language: (
      build: () => const LanguageScreen(),
      icon: Icons.translate,
      title: (l) => l.settingLanguage,
      listed: false,
      endsGroup: false,
    ),
  };

  /// Builds [page], for the root list and for search.
  Widget _page(SettingsPageId page) => _pages[page]!.build();

  void _go(BuildContext context, SettingsPageId page) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => _page(page)));

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.settingsTitle),
      // A symbol, so anyone stuck in a language they cannot read finds it.
      floatingActionButton: IconButton(
        icon: const Icon(Icons.translate),
        tooltip: context.l10n.settingLanguage,
        onPressed: () => _go(context, SettingsPageId.language),
      ),
      actions: [
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
          for (final MapEntry(key: page, value: entry) in _pages.entries)
            if (entry.listed) ...[
              SettingsNavTile(
                icon: entry.icon,
                title: entry.title(context.l10n),
                onTap: () => _go(context, page),
              ),
              if (entry.endsGroup) const Divider(),
            ],
          const UpdateBanner(),
        ],
      ),
    );
  }
}
