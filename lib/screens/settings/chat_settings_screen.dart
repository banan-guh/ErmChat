import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../../services/recent_messages.dart';
import '../../services/twitch_auth.dart';
import '../../util/constants.dart';
import '../../util/prefs.dart';
import '../../util/prefs_store.dart';
import 'link_whitelist_screen.dart';
import 'macros_screen.dart';
import 'inline_embeds_screen.dart';
import 'prefs_tiles.dart';
import 'proxy_settings_screen.dart';
import 'recent_messages_settings_screen.dart';
import 'settings_page.dart';

class ChatSettingsScreen extends StatefulWidget {
  final TwitchAuth? twitchAuth;

  /// Foreground-service side effect: starting/stopping the service cannot be
  /// re-applied from a prefs re-read, so it stays a callback.
  final ValueChanged<bool>? onBackgroundServiceChanged;

  final ValueChanged<RecentMessagesConfig>? onRecentMessagesModeChanged;

  const ChatSettingsScreen({
    super.key,
    this.twitchAuth,
    this.onBackgroundServiceChanged,
    this.onRecentMessagesModeChanged,
  });

  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  Prefs? _prefs;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    PrefsStore.instance.addListener(_loadPrefs);
  }

  @override
  void dispose() {
    PrefsStore.instance.removeListener(_loadPrefs);
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await Prefs.load();
    if (mounted) setState(() => _prefs = prefs);
  }

  int _stepIndexFor(int value) {
    var best = 0;
    var bestDistance = (value - kMaxMessagesPerChannelValues[0]).abs();
    for (var i = 1; i < kMaxMessagesPerChannelValues.length; i++) {
      final distance = (value - kMaxMessagesPerChannelValues[i]).abs();
      if (distance < bestDistance) {
        best = i;
        bestDistance = distance;
      }
    }
    return best;
  }

  String get _sharedChatMode => _prefs?.sharedChatMode ?? 'spotlight';

  bool get _showGifs =>
      _prefs?.giphyInlineEnabled ?? kGiphyInlineEnabledDefault;

  bool get _showImages =>
      _prefs?.imageEmbedEnabled ?? kImageEmbedEnabledDefault;

  String get _sharedChatModeLabel => switch (_sharedChatMode) {
    'fade' => 'Fade',
    'hide' => 'Hide',
    _ => 'Spotlight',
  };

  Future<void> _pickSharedChatMode() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Shared chat messages'),
        content: RadioGroup<String>(
          groupValue: _sharedChatMode,
          onChanged: (v) {
            if (v != null) Navigator.pop(ctx, v);
          },
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String>(
                value: 'spotlight',
                title: Text('Spotlight'),
                subtitle: Text('Labeled by channel'),
              ),
              RadioListTile<String>(
                value: 'fade',
                title: Text('Fade'),
                subtitle: Text('Dimmed'),
              ),
              RadioListTile<String>(
                value: 'hide',
                title: Text('Hide'),
                subtitle: Text('Hidden'),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || selected == _sharedChatMode) return;
    final prefs = _prefs ?? await Prefs.load();
    await prefs.setSharedChatMode(selected);
    PrefsStore.instance.notifyChanged();
    if (!mounted) return;
    setState(() {});
  }

  String get _inlineEmbedsSubtitle {
    return switch ((_showGifs, _showImages)) {
      (true, true) => 'Giphy, images',
      (true, false) => 'Giphy',
      (false, true) => 'Images',
      _ => 'Off',
    };
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: const Text('Chat'),
      body: ListView(
        children: [
          const SettingsSectionHeader('Messages'),
          PrefsSliderTile(
            label: (v) =>
                'Max messages per channel: '
                '${kMaxMessagesPerChannelValues[v.round()]}',
            sliderLabel: (v) => '${kMaxMessagesPerChannelValues[v.round()]}',
            min: 0,
            max: (kMaxMessagesPerChannelValues.length - 1).toDouble(),
            divisions: kMaxMessagesPerChannelValues.length - 1,
            defaultValue: _stepIndexFor(
              kMaxMessagesPerChannelDefault,
            ).toDouble(),
            read: (p) => _stepIndexFor(p.maxMessagesPerChannel).toDouble(),
            write: (p, v) => p.setMaxMessagesPerChannel(
              kMaxMessagesPerChannelValues[v.round()],
            ),
          ),
          SettingsNavTile(
            icon: Icons.merge_type,
            title: 'Shared chat messages',
            subtitle: _sharedChatModeLabel,
            onTap: _pickSharedChatMode,
          ),
          SettingsNavTile(
            icon: Icons.gif_box,
            title: 'Inline embeds',
            subtitle: _inlineEmbedsSubtitle,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const InlineEmbedsScreen()),
              );
            },
          ),
          SettingsNavTile(
            icon: Icons.link,
            title: 'Split links',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const LinkWhitelistSettingsScreen(),
              ),
            ),
          ),
          const SettingsSectionHeader('History'),
          PrefsSliderTile(
            label: (v) => 'Recent messages to load: ${v.round()}',
            sliderLabel: (v) => '${v.round()}',
            min: 0,
            max: 800,
            divisions: 8,
            defaultValue: kRecentMessagesLimitDefault.toDouble(),
            read: (p) => p.recentMessagesLimit.clamp(0, 800).toDouble(),
            write: (p, v) => p.setRecentMessagesLimit(v.round()),
          ),
          SettingsNavTile(
            icon: Icons.history,
            title: 'Recent messages',
            subtitle: 'Choose provider',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RecentMessagesSettingsScreen(
                  onChanged: widget.onRecentMessagesModeChanged,
                ),
              ),
            ),
          ),
          const SettingsSectionHeader('Typing'),
          PrefsSwitchTile(
            secondary: const Icon(Icons.sentiment_very_satisfied),
            title: 'Prefer emote suggestions (autocomplete)',
            defaultValue: false,
            read: (p) => p.preferEmotesFirst,
            write: (p, v) => p.setPreferEmotesFirst(v),
          ),
          const _MentionFormatTile(),
          PrefsSwitchTile(
            secondary: const Icon(Icons.reply),
            title: 'Reply to thread first message',
            defaultValue: false,
            read: (p) => p.replyToThreadRoot,
            write: (p, v) => p.setReplyToThreadRoot(v),
          ),
          if (widget.twitchAuth != null)
            SettingsNavTile(
              icon: Icons.bolt,
              title: 'Command macros',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        MacrosScreen(twitchAuth: widget.twitchAuth!),
                  ),
                );
              },
            ),
          const SettingsSectionHeader('Users'),
          PrefsSwitchTile(
            secondary: const Icon(Icons.content_copy),
            title: 'Double-tap name to copy',
            subtitle: 'Delays opening the user card',
            defaultValue: false,
            read: (p) => p.doubleTapNameCopy,
            write: (p, v) => p.setDoubleTapNameCopy(v),
          ),
          PrefsSwitchTile(
            secondary: const Icon(Icons.format_paint),
            title: '7TV name paints',
            defaultValue: false,
            read: (p) => p.seventvNamePaints,
            write: (p, v) => p.setSeventvNamePaints(v),
          ),
          const SettingsSectionHeader('Connection'),
          // The foreground service behind this is Android-only.
          if (!kIsWeb && Platform.isAndroid)
            PrefsSwitchTile(
              secondary: const Icon(Icons.wifi_tethering),
              title: 'Stay connected in background',
              subtitle: 'Shows a persistent notification',
              defaultValue: false,
              read: (p) => p.backgroundService,
              write: (p, v) => p.setBackgroundService(v),
              onChanged: widget.onBackgroundServiceChanged,
            ),
          SettingsNavTile(
            icon: Icons.cloud,
            title: 'Chat proxy',
            subtitle: (_prefs?.proxyEnabled ?? false) ? 'On' : 'Off',
            // The proxy screen saves without announcing it; re-read on return.
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProxySettingsScreen()),
            ).then((_) => _loadPrefs()),
          ),
        ],
      ),
    );
  }
}

class _MentionFormatTile extends StatefulWidget {
  const _MentionFormatTile();

  @override
  State<_MentionFormatTile> createState() => _MentionFormatTileState();
}

class _MentionFormatTileState extends State<_MentionFormatTile> {
  static const formats = <String, String>{
    '@name': '@name',
    '@name,': '@name,',
    'name': 'name',
    'name,': 'name,',
  };
  String _format = '@name';

  @override
  void initState() {
    super.initState();
    Prefs.load().then((prefs) {
      if (mounted) {
        setState(() => _format = prefs.mentionFormat);
      }
    });
  }

  Future<void> _pick() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Mention format'),
        children: [
          RadioGroup<String>(
            groupValue: _format,
            onChanged: (v) {
              if (v != null) Navigator.pop(ctx, v);
            },
            child: Column(
              children: [
                for (final entry in formats.entries)
                  RadioListTile<String>(
                    value: entry.key,
                    title: Text(entry.value),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null || selected == _format) return;
    final prefs = await Prefs.load();
    await prefs.setMentionFormat(selected);
    if (mounted) setState(() => _format = selected);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsNavTile(
      icon: Icons.text_format,
      title: 'Mention format',
      subtitle: formats[_format],
      onTap: _pick,
    );
  }
}
