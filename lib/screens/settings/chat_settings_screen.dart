import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../../services/twitch_auth.dart';
import '../../util/constants.dart';
import '../../util/prefs.dart';
import '../../util/timestamp_formatter.dart';
import '../../widgets/dialogs.dart';
import 'macros_screen.dart';
import 'pings_screen.dart';
import 'ignores_screen.dart';
import 'inline_embeds_screen.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';

class ChatSettingsScreen extends StatefulWidget {
  final TwitchAuth? twitchAuth;
  final ValueChanged<bool>? onBackgroundServiceChanged;
  final ValueChanged<bool>? onMentionPushChanged;
  final ValueChanged<bool>? onWhisperNotifyChanged;
  final ValueChanged<int>? onMaxMessagesPerChannelChanged;
  final ValueChanged<int>? onRecentMessagesChanged;
  final ValueChanged<bool>? onReplyToRootChanged;
  final ValueChanged<bool>? onPreferEmotesFirstChanged;
  final ValueChanged<bool>? onShowTimestampsChanged;
  final ValueChanged<String>? onTimestampFormatChanged;
  final ValueChanged<String>? onSharedChatModeChanged;
  final ValueChanged<bool>? onNamePaintsChanged;
  final ValueChanged<bool>? onShowGifsChanged;
  final ValueChanged<double>? onGifHeightChanged;
  final ValueChanged<bool>? onShowImagesChanged;
  final ValueChanged<double>? onImageHeightChanged;

  const ChatSettingsScreen({
    super.key,
    this.twitchAuth,
    this.onBackgroundServiceChanged,
    this.onMentionPushChanged,
    this.onWhisperNotifyChanged,
    this.onMaxMessagesPerChannelChanged,
    this.onRecentMessagesChanged,
    this.onReplyToRootChanged,
    this.onPreferEmotesFirstChanged,
    this.onShowTimestampsChanged,
    this.onTimestampFormatChanged,
    this.onSharedChatModeChanged,
    this.onNamePaintsChanged,
    this.onShowGifsChanged,
    this.onGifHeightChanged,
    this.onShowImagesChanged,
    this.onImageHeightChanged,
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

  String get _timestampFormat =>
      _prefs?.timestampFormat ?? kDefaultTimestampFormat;

  String get _sharedChatMode => _prefs?.sharedChatMode ?? 'spotlight';

  bool get _showGifs =>
      _prefs?.giphyInlineEnabled ?? kGiphyInlineEnabledDefault;

  bool get _showImages =>
      _prefs?.imageEmbedEnabled ?? kImageEmbedEnabledDefault;

  Future<void> _pickTimestampFormat() async {
    final now = DateTime.now();
    final selected = await showChoiceDialog<String>(
      context,
      title: 'Timestamp format',
      value: _timestampFormat,
      height: 420,
      options: [
        for (final fmt in kTimestampFormats)
          (fmt, fmt, 'e.g. ${formatTimestamp(now, fmt)}'),
      ],
    );
    if (selected == null || selected == _timestampFormat) return;
    final prefs = _prefs ?? await Prefs.load();
    await prefs.setTimestampFormat(selected);
    if (!mounted) return;
    setState(() {});
    widget.onTimestampFormatChanged?.call(selected);
  }

  String get _sharedChatModeLabel => switch (_sharedChatMode) {
    'fade' => 'Fade (dim foreign messages)',
    'hide' => 'Hide (drop foreign messages)',
    _ => 'Spotlight (show all)',
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
                subtitle: Text('Show all messages with attribution'),
              ),
              RadioListTile<String>(
                value: 'fade',
                title: Text('Fade'),
                subtitle: Text('Dim foreign messages'),
              ),
              RadioListTile<String>(
                value: 'hide',
                title: Text('Hide'),
                subtitle: Text('Drop foreign messages entirely'),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || selected == _sharedChatMode) return;
    final prefs = _prefs ?? await Prefs.load();
    await prefs.setSharedChatMode(selected);
    if (!mounted) return;
    setState(() {});
    widget.onSharedChatModeChanged?.call(selected);
  }

  String get _inlineEmbedsSubtitle {
    final parts = <String>[];
    if (_showGifs) {
      parts.add('Giphy on (${(_prefs?.giphyInlineHeight ?? 0).round()}dp)');
    }
    if (_showImages) {
      parts.add('Images on (${(_prefs?.imageEmbedHeight ?? 0).round()}dp)');
    }
    if (parts.isEmpty) return 'Off';
    return parts.join(', ');
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
            onChanged: (v) => widget.onMaxMessagesPerChannelChanged?.call(
              kMaxMessagesPerChannelValues[v.round()],
            ),
          ),
          PrefsSliderTile(
            label: (v) => 'Recent messages to load: ${v.round()}',
            sliderLabel: (v) => '${v.round()}',
            min: 0,
            max: 800,
            divisions: 8,
            defaultValue: kRecentMessagesLimitDefault.toDouble(),
            read: (p) => p.recentMessagesLimit.clamp(0, 800).toDouble(),
            write: (p, v) => p.setRecentMessagesLimit(v.round()),
            onChanged: (v) => widget.onRecentMessagesChanged?.call(v.round()),
          ),
          PrefsSwitchTile(
            secondary: const Icon(Icons.reply),
            title: 'Reply to thread root',
            subtitle:
                'Always reply to the first message in a thread instead of the latest',
            defaultValue: false,
            read: (p) => p.replyToThreadRoot,
            write: (p, v) => p.setReplyToThreadRoot(v),
            onChanged: widget.onReplyToRootChanged,
          ),
          SettingsNavTile(
            icon: Icons.merge_type,
            title: 'Shared chat messages',
            subtitle: _sharedChatModeLabel,
            onTap: _pickSharedChatMode,
          ),
          SettingsNavTile(
            icon: Icons.visibility_off,
            title: 'Ignores',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const IgnoresScreen()),
              );
            },
          ),
          SettingsNavTile(
            icon: Icons.gif_box,
            title: 'Inline embeds',
            subtitle: _inlineEmbedsSubtitle,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => InlineEmbedsScreen(
                    onShowGifsChanged: (v) {
                      if (mounted) setState(() {});
                      widget.onShowGifsChanged?.call(v);
                    },
                    onGifHeightChanged: (v) {
                      if (mounted) setState(() {});
                      widget.onGifHeightChanged?.call(v);
                    },
                    onShowImagesChanged: (v) {
                      if (mounted) setState(() {});
                      widget.onShowImagesChanged?.call(v);
                    },
                    onImageHeightChanged: (v) {
                      if (mounted) setState(() {});
                      widget.onImageHeightChanged?.call(v);
                    },
                  ),
                ),
              );
            },
          ),
          const _MentionFormatTile(),
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
          const SettingsSectionHeader('UI'),
          PrefsSwitchTile(
            secondary: const Icon(Icons.schedule),
            title: 'Show timestamps',
            defaultValue: true,
            read: (p) => p.showTimestamps,
            write: (p, v) => p.setShowTimestamps(v),
            onChanged: widget.onShowTimestampsChanged,
          ),
          SettingsNavTile(
            icon: Icons.access_time,
            title: 'Timestamp format',
            subtitle: _timestampFormat,
            onTap: _pickTimestampFormat,
          ),
          PrefsSwitchTile(
            secondary: const Icon(Icons.format_paint),
            title: '7TV name paints',
            subtitle: 'Gradient username colors for 7TV subscribers',
            defaultValue: false,
            read: (p) => p.seventvNamePaints,
            write: (p, v) => p.setSeventvNamePaints(v),
            onChanged: widget.onNamePaintsChanged,
          ),
          PrefsSwitchTile(
            secondary: const Icon(Icons.sentiment_very_satisfied),
            title: 'Prefer emote suggestions',
            subtitle: 'Emote priority over usernames in autocomplete',
            defaultValue: false,
            read: (p) => p.preferEmotesFirst,
            write: (p, v) => p.setPreferEmotesFirst(v),
            onChanged: widget.onPreferEmotesFirstChanged,
          ),
          const SettingsSectionHeader('Notifications'),
          SettingsNavTile(
            icon: Icons.notifications,
            title: 'Pings',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PingsScreen()),
              );
            },
          ),
          // Mention push is Android-only (the foreground service path); the
          // iOS toggle would silently do nothing, so hide it there.
          if (!kIsWeb && !Platform.isIOS) ...[
            PrefsSwitchTile(
              secondary: const Icon(Icons.notifications_active),
              title: 'Mention notifications',
              defaultValue: false,
              read: (p) => p.mentionPush,
              write: (p, v) => p.setMentionPush(v),
              onChanged: widget.onMentionPushChanged,
            ),
            PrefsSwitchTile(
              secondary: const Icon(Icons.chat_bubble),
              title: 'Whisper notifications',
              defaultValue: false,
              read: (p) => p.whisperNotifications,
              write: (p, v) => p.setWhisperNotifications(v),
              onChanged: widget.onWhisperNotifyChanged,
            ),
          ],
          const SettingsSectionHeader('Connection'),
          PrefsSwitchTile(
            secondary: const Icon(Icons.wifi_tethering),
            title: 'Keep chat alive in background',
            subtitle: 'Foreground notification to not reconnect every time',
            defaultValue: false,
            read: (p) => p.backgroundService,
            write: (p, v) => p.setBackgroundService(v),
            onChanged: widget.onBackgroundServiceChanged,
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
      subtitle:
          'How tapping "Mention user" inserts the name: ${formats[_format]}',
      onTap: _pick,
    );
  }
}
