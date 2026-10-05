import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
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
import 'settings_search.dart';

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
    'fade' => context.l10n.sharedChatFade,
    'hide' => context.l10n.sharedChatHide,
    _ => context.l10n.sharedChatSpotlight,
  };

  Future<void> _pickSharedChatMode() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.sharedChatTitle),
        content: RadioGroup<String>(
          groupValue: _sharedChatMode,
          onChanged: (v) {
            if (v != null) Navigator.pop(ctx, v);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String>(
                value: 'spotlight',
                title: Text(ctx.l10n.sharedChatSpotlight),
                subtitle: Text(ctx.l10n.sharedChatSpotlightHint),
              ),
              RadioListTile<String>(
                value: 'fade',
                title: Text(ctx.l10n.sharedChatFade),
                subtitle: Text(ctx.l10n.sharedChatFadeHint),
              ),
              RadioListTile<String>(
                value: 'hide',
                title: Text(ctx.l10n.sharedChatHide),
                subtitle: Text(ctx.l10n.sharedChatHideHint),
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
      (true, true) => context.l10n.embedsGiphyImages,
      (true, false) => context.l10n.embedsGiphy,
      (false, true) => context.l10n.embedsImages,
      _ => context.l10n.off,
    };
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.pageChat),
      body: ListView(
        children: [
          SettingsSectionHeader(context.l10n.sectionMessages),
          SettingAnchor(
            Setting.maxMessages,
            child: PrefsSliderTile(
              label: (v) =>
                  '${Setting.maxMessages.titleOf(context.l10n)}: '
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
          ),
          SettingAnchor(
            Setting.sharedChat,
            child: SettingsNavTile(
              icon: Icons.merge_type,
              title: Setting.sharedChat.titleOf(context.l10n),
              subtitle: _sharedChatModeLabel,
              onTap: _pickSharedChatMode,
            ),
          ),
          SettingAnchor(
            Setting.inlineEmbeds,
            child: SettingsNavTile(
              icon: Icons.gif_box,
              title: Setting.inlineEmbeds.titleOf(context.l10n),
              subtitle: _inlineEmbedsSubtitle,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const InlineEmbedsScreen()),
                );
              },
            ),
          ),
          SettingAnchor(
            Setting.splitLinks,
            child: SettingsNavTile(
              icon: Icons.link,
              title: Setting.splitLinks.titleOf(context.l10n),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const LinkWhitelistSettingsScreen(),
                ),
              ),
            ),
          ),
          SettingsSectionHeader(context.l10n.sectionHistory),
          SettingAnchor(
            Setting.recentMessagesLimit,
            child: PrefsSliderTile(
              label: (v) =>
                  '${Setting.recentMessagesLimit.titleOf(context.l10n)}: ${v.round()}',
              sliderLabel: (v) => '${v.round()}',
              min: 0,
              max: 800,
              divisions: 8,
              defaultValue: kRecentMessagesLimitDefault.toDouble(),
              read: (p) => p.recentMessagesLimit.clamp(0, 800).toDouble(),
              write: (p, v) => p.setRecentMessagesLimit(v.round()),
            ),
          ),
          SettingAnchor(
            Setting.recentMessagesSource,
            child: SettingsNavTile(
              icon: Icons.history,
              title: Setting.recentMessagesSource.titleOf(context.l10n),
              subtitle: context.l10n.chooseProvider,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => RecentMessagesSettingsScreen(
                    onChanged: widget.onRecentMessagesModeChanged,
                  ),
                ),
              ),
            ),
          ),
          SettingsSectionHeader(context.l10n.sectionTyping),
          SettingAnchor(
            Setting.preferEmotes,
            child: PrefsSwitchTile(
              secondary: const Icon(Icons.sentiment_very_satisfied),
              title: Setting.preferEmotes.titleOf(context.l10n),
              defaultValue: false,
              read: (p) => p.preferEmotesFirst,
              write: (p, v) => p.setPreferEmotesFirst(v),
            ),
          ),
          const _MentionFormatTile(),
          SettingAnchor(
            Setting.replyThreadRoot,
            child: PrefsSwitchTile(
              secondary: const Icon(Icons.reply),
              title: Setting.replyThreadRoot.titleOf(context.l10n),
              defaultValue: false,
              read: (p) => p.replyToThreadRoot,
              write: (p, v) => p.setReplyToThreadRoot(v),
            ),
          ),
          if (widget.twitchAuth != null)
            SettingAnchor(
              Setting.macros,
              child: SettingsNavTile(
                icon: Icons.bolt,
                title: Setting.macros.titleOf(context.l10n),
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
            ),
          SettingsSectionHeader(context.l10n.sectionUsers),
          SettingAnchor(
            Setting.doubleTapCopy,
            child: PrefsSwitchTile(
              secondary: const Icon(Icons.content_copy),
              title: Setting.doubleTapCopy.titleOf(context.l10n),
              subtitle: context.l10n.delaysUserCard,
              defaultValue: false,
              read: (p) => p.doubleTapNameCopy,
              write: (p, v) => p.setDoubleTapNameCopy(v),
            ),
          ),
          SettingAnchor(
            Setting.namePaints,
            child: PrefsSwitchTile(
              secondary: const Icon(Icons.format_paint),
              title: Setting.namePaints.titleOf(context.l10n),
              defaultValue: false,
              read: (p) => p.seventvNamePaints,
              write: (p, v) => p.setSeventvNamePaints(v),
            ),
          ),
          SettingsSectionHeader(context.l10n.sectionConnection),
          // The foreground service behind this is Android-only.
          if (!kIsWeb && Platform.isAndroid)
            SettingAnchor(
              Setting.stayConnected,
              child: PrefsSwitchTile(
                secondary: const Icon(Icons.wifi_tethering),
                title: Setting.stayConnected.titleOf(context.l10n),
                subtitle: context.l10n.persistentNotification,
                defaultValue: false,
                read: (p) => p.backgroundService,
                write: (p, v) => p.setBackgroundService(v),
                onChanged: widget.onBackgroundServiceChanged,
              ),
            ),
          SettingAnchor(
            Setting.chatProxy,
            child: SettingsNavTile(
              icon: Icons.cloud,
              title: Setting.chatProxy.titleOf(context.l10n),
              subtitle: (_prefs?.proxyEnabled ?? false)
                  ? context.l10n.on
                  : context.l10n.off,
              // The proxy screen saves without announcing it; re-read on return.
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProxySettingsScreen()),
              ).then((_) => _loadPrefs()),
            ),
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
        title: Text(ctx.l10n.mentionFormatTitle),
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
    return SettingAnchor(
      Setting.mentionFormat,
      child: SettingsNavTile(
        icon: Icons.text_format,
        title: Setting.mentionFormat.titleOf(context.l10n),
        subtitle: formats[_format],
        onTap: _pick,
      ),
    );
  }
}
