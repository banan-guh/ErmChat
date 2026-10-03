import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../../models/emote_fetch_tier.dart';
import '../../report_config.dart';
import '../../services/analytics_service.dart';
import '../../services/emote_manager.dart';
import '../../services/twitch_auth.dart';
import '../../services/twitch_oauth.dart';
import '../../services/tts_controller.dart';
import 'about_screen.dart';
import 'account_screen.dart';
import 'channel_settings_screen.dart';
import 'chat_settings_screen.dart';
import 'custom_layout_screen.dart';
import 'customization_screen.dart';
import 'emotes_settings_screen.dart';
import 'ignores_screen.dart';
import 'inline_embeds_screen.dart';
import 'link_whitelist_screen.dart';
import 'macros_screen.dart';
import 'pings_screen.dart';
import 'proxy_settings_screen.dart';
import 'recent_messages_settings_screen.dart';
import 'recent_uploads_screen.dart';
import 'report_bug_screen.dart';
import 'settings_page.dart';
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

  Widget _about() => AboutScreen(onTestWidgetsChanged: onTestWidgetsChanged);

  Widget _tts() => TtsSettingsScreen(ttsController: ttsController);

  static void _go(BuildContext context, Widget Function() screen) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => screen()));

  /// Every searchable setting: its label, where it lives, extra words people
  /// search by, and the screen that holds it.
  List<_Entry> _index() {
    final android = !kIsWeb && Platform.isAndroid;
    _Entry e(
      String title,
      String path,
      Widget Function() open, [
      String keywords = '',
    ]) => (title: title, path: path, open: open, keywords: keywords);
    return [
      e('Channels', 'Channels', _channels, 'join leave reorder rename'),
      e('Theme', 'Appearance › Theme', _appearance, 'dark light mode'),
      e('Accent color', 'Appearance › Theme', _appearance, 'colour'),
      e('True dark mode', 'Appearance › Theme', _appearance, 'black amoled'),
      e('Layout', 'Appearance › Layout', _appearance, 'compact full density'),
      e('Liquid glass', 'Appearance › Layout', _appearance, 'blur'),
      e('Chat font size', 'Appearance › Chat display', _appearance, 'text'),
      e('Show timestamps', 'Appearance › Chat display', _appearance, 'time'),
      e('Timestamp format', 'Appearance › Chat display', _appearance, 'time'),
      e(
        'Checkered messages',
        'Appearance › Chat display',
        _appearance,
        'alternate rows',
      ),
      e(
        'Separate messages with lines',
        'Appearance › Chat display',
        _appearance,
        'divider',
      ),
      e('Keep screen on', 'Appearance › Display', _appearance, 'sleep dim'),
      e('Fast channel swipe', 'Appearance › Navigation', _appearance),
      for (final title in const [
        'Merge app bar into tabs',
        'Fold panel titles into tabs',
        'Tighter composer',
        'Horizontal sheet actions',
        'Compact density',
        'Tighter chrome margins',
      ])
        e(title, 'Appearance › Layout › Custom', CustomLayoutScreen.new),
      e('Max messages per channel', 'Chat › Messages', _chat, 'buffer limit'),
      e('Shared chat messages', 'Chat › Messages', _chat, 'spotlight fade'),
      e('Inline embeds', 'Chat › Messages', _chat, 'giphy images gif'),
      e('Show Giphy inline', 'Chat › Inline embeds', InlineEmbedsScreen.new),
      e('Show images inline', 'Chat › Inline embeds', InlineEmbedsScreen.new),
      e('Split links', 'Chat › Messages', LinkWhitelistSettingsScreen.new),
      e('Recent messages to load', 'Chat › History', _chat, 'history'),
      e(
        'Recent messages',
        'Chat › History',
        () => RecentMessagesSettingsScreen(
          onChanged: onRecentMessagesModeChanged,
        ),
        'history provider robotty',
      ),
      e(
        'Prefer emote suggestions (autocomplete)',
        'Chat › Typing',
        _chat,
        'tab complete',
      ),
      e('Mention format', 'Chat › Typing', _chat, '@ name'),
      e('Reply to thread first message', 'Chat › Typing', _chat, 'root'),
      e(
        'Command macros',
        'Chat › Typing',
        () => MacrosScreen(twitchAuth: twitchAuth),
        'commands shortcuts',
      ),
      e('Double-tap name to copy', 'Chat › Users', _chat),
      e('7TV name paints', 'Chat › Users', _chat, 'gradient colors'),
      if (android)
        e(
          'Stay connected in background',
          'Chat › Connection',
          _chat,
          'keep alive service',
        ),
      e('Chat proxy', 'Chat › Connection', ProxySettingsScreen.new, 'server'),
      if (android) ...[
        e(
          'Mention notifications',
          'Highlights › Notifications',
          _highlights,
          'push ping alert',
        ),
        e('Whisper notifications', 'Highlights › Notifications', _highlights),
      ],
      e('My username', 'Highlights › Mentions', _highlights, 'ping'),
      e('Replies to me', 'Highlights › Mentions', _highlights),
      e("Threads I'm in", 'Highlights › Mentions', _highlights),
      e('Keywords', 'Highlights', _highlights, 'words ping alert'),
      e('Highlight users', 'Highlights › Users', _highlights),
      e('First messages', 'Highlights › Events', _highlights),
      e('Channel point redemptions', 'Highlights › Events', _highlights),
      e('Hype Chat', 'Highlights › Events', _highlights, 'paid'),
      e('Badges', 'Highlights › Events', _highlights, 'mod vip sub'),
      e("Don't highlight", 'Highlights', _highlights, 'blacklist'),
      e('Ignores', 'Highlights', IgnoresScreen.new, 'block mute hide'),
      e('Highlight strength', 'Highlights › Appearance', _highlights),
      e('Emote quality', 'Emotes › Emote fetching', _emotes, 'tier data'),
      e('Auto data saver mode', 'Emotes', _emotes, 'cellular wifi'),
      e('Emote image cache', 'Emotes', _emotes, 'storage nuke clear'),
      e('Animate emotes', 'Emotes › Animation', _emotes, 'gif'),
      e('Adaptive frame rate', 'Emotes › Animation', _emotes, 'fps battery'),
      e('Providers', 'Emotes', _emotes, 'bttv ffz 7tv'),
      e('Unlisted 7TV emotes', 'Emotes', _emotes),
      e('Text-to-speech', 'Tools', _tts, 'tts read aloud voice'),
      e('Ignored users', 'Tools › Text-to-speech', _tts, 'tts'),
      e('Image uploader', 'Tools', UploaderSettingsScreen.new, 'upload'),
      e('Recent uploads', 'Tools › Image uploader', RecentUploadsScreen.new),
      e('Analytics', 'Tools', _tools, 'stats'),
      if (android)
        e('Picture-in-picture', 'Tools › Livestreams', _tools, 'pip stream'),
      e('Account', 'Account', _account, 'login log out switch'),
      e('About', 'About', _about, 'version licenses'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: const Text('Settings'),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'Search settings',
          onPressed: () =>
              showSearch(context: context, delegate: _SettingsSearch(_index())),
        ),
      ],
      body: ListView(
        children: [
          SettingsNavTile(
            icon: Icons.tag,
            title: 'Channels',
            onTap: () => _go(context, _channels),
          ),
          SettingsNavTile(
            icon: Icons.palette,
            title: 'Appearance',
            onTap: () => _go(context, _appearance),
          ),
          SettingsNavTile(
            icon: Icons.chat_bubble,
            title: 'Chat',
            onTap: () => _go(context, _chat),
          ),
          SettingsNavTile(
            icon: Icons.notifications,
            title: 'Highlights',
            onTap: () => _go(context, _highlights),
          ),
          SettingsNavTile(
            icon: Icons.emoji_emotions,
            title: 'Emotes',
            onTap: () => _go(context, _emotes),
          ),
          const Divider(),
          SettingsNavTile(
            icon: Icons.handyman,
            title: 'Tools',
            onTap: () => _go(context, _tools),
          ),
          SettingsNavTile(
            icon: Icons.person,
            title: 'Account',
            onTap: () => _go(context, _account),
          ),
          // Reports carry the signed-in Twitch identity, so the entry only
          // shows for a real account with the report server configured.
          if (twitchAuth.isConfigured && ReportConfig.isConfigured)
            SettingsNavTile(
              icon: Icons.bug_report,
              title: 'Report a bug',
              onTap: () => _go(context, ReportBugScreen.new),
            ),
          SettingsNavTile(
            icon: Icons.info,
            title: 'About',
            onTap: () => _go(context, _about),
          ),
        ],
      ),
    );
  }
}

typedef _Entry = ({
  String title,
  String path,
  String keywords,
  Widget Function() open,
});

/// Matches every typed word against a setting's title, location and extra
/// keywords, so "dark" finds Theme and "ping" finds Highlights.
class _SettingsSearch extends SearchDelegate<void> {
  _SettingsSearch(this.entries) : super(searchFieldLabel: 'Search settings');

  final List<_Entry> entries;

  @override
  List<Widget> buildActions(BuildContext context) => [
    if (query.isNotEmpty)
      IconButton(
        icon: const Icon(Icons.clear),
        tooltip: 'Clear',
        onPressed: () => query = '',
      ),
  ];

  @override
  Widget buildLeading(BuildContext context) =>
      BackButton(onPressed: () => close(context, null));

  @override
  Widget buildResults(BuildContext context) => buildSuggestions(context);

  @override
  Widget buildSuggestions(BuildContext context) {
    final words = query.toLowerCase().split(' ').where((w) => w.isNotEmpty);
    if (words.isEmpty) return const SizedBox.shrink();
    final hits = entries.where((e) {
      final haystack = '${e.title} ${e.path} ${e.keywords}'.toLowerCase();
      return words.every(haystack.contains);
    }).toList();
    if (hits.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('No matching settings'),
      );
    }
    return ListView(
      children: [
        for (final hit in hits)
          ListTile(
            title: Text(hit.title),
            subtitle: Text(hit.path),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => hit.open()),
            ),
          ),
      ],
    );
  }
}
