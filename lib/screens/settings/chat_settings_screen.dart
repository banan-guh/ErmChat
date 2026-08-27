import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/twitch_auth.dart';
import '../../util/constants.dart';
import '../../util/timestamp_formatter.dart';
import 'macros_screen.dart';
import 'pings_screen.dart';
import 'ignores_screen.dart';

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
  });

  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  int _maxMessagesPerChannel = kMaxMessagesPerChannelDefault;
  int _recentMessagesCount = kRecentMessagesLimitDefault;
  bool _replyToRoot = false;
  bool _backgroundService = false;
  bool _mentionPush = false;
  bool _whisperNotify = false;
  bool _preferEmotesFirst = false;
  bool _showTimestamps = true;
  String _timestampFormat = kDefaultTimestampFormat;
  String _sharedChatMode = 'spotlight';
  bool _namePaints = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _maxMessagesPerChannel = snapToMaxMessagesStep(
          prefs.getInt('max_messages_per_channel') ??
              kMaxMessagesPerChannelDefault,
        );
        _recentMessagesCount =
            prefs.getInt('recent_messages_limit') ??
            kRecentMessagesLimitDefault;
        _replyToRoot = prefs.getBool('reply_to_thread_root') ?? false;
        _backgroundService = prefs.getBool('background_service') ?? false;
        _mentionPush = prefs.getBool('mention_push') ?? false;
        _whisperNotify = prefs.getBool('whisper_notifications') ?? false;
        _preferEmotesFirst = prefs.getBool('prefer_emotes_first') ?? false;
        _showTimestamps = prefs.getBool(kShowTimestampsPrefKey) ?? true;
        _timestampFormat =
            prefs.getString(kTimestampFormatPrefKey) ?? kDefaultTimestampFormat;
        _sharedChatMode = prefs.getString('shared_chat_mode') ?? 'spotlight';
        _namePaints = prefs.getBool('seventv_name_paints') ?? false;
      });
    }
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

  Future<void> _pickTimestampFormat() async {
    final now = DateTime.now();
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Timestamp format'),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: SizedBox(
          width: 360,
          height: 420,
          child: RadioGroup<String>(
            groupValue: _timestampFormat,
            onChanged: (v) {
              if (v != null) Navigator.pop(ctx, v);
            },
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final fmt in kTimestampFormats)
                  RadioListTile<String>(
                    value: fmt,
                    title: Text(fmt),
                    subtitle: Text('e.g. ${formatTimestamp(now, fmt)}'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected == null || selected == _timestampFormat) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kTimestampFormatPrefKey, selected);
    if (mounted) setState(() => _timestampFormat = selected);
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('shared_chat_mode', selected);
    if (mounted) setState(() => _sharedChatMode = selected);
    widget.onSharedChatModeChanged?.call(selected);
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chat')),
      body: ListView(
        children: [
          _sectionHeader('Messages'),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  'Max messages per channel: $_maxMessagesPerChannel',
                ),
              ),
              Slider(
                value: _stepIndexFor(_maxMessagesPerChannel).toDouble(),
                min: 0,
                max: (kMaxMessagesPerChannelValues.length - 1).toDouble(),
                divisions: kMaxMessagesPerChannelValues.length - 1,
                label: '$_maxMessagesPerChannel',
                onChanged: (value) {
                  final v = kMaxMessagesPerChannelValues[value.round()];
                  setState(() => _maxMessagesPerChannel = v);
                  widget.onMaxMessagesPerChannelChanged?.call(v);
                },
                onChangeEnd: (value) {
                  final v = kMaxMessagesPerChannelValues[value.round()];
                  SharedPreferences.getInstance().then(
                    (prefs) => prefs.setInt('max_messages_per_channel', v),
                  );
                },
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text('Recent messages to load: $_recentMessagesCount'),
              ),
              Slider(
                value: _recentMessagesCount.toDouble(),
                min: 0,
                max: 800,
                divisions: 10,
                label: '$_recentMessagesCount',
                onChanged: (value) {
                  final v = value.toInt();
                  setState(() => _recentMessagesCount = v);
                  widget.onRecentMessagesChanged?.call(v);
                },
                onChangeEnd: (value) {
                  final v = value.toInt();
                  SharedPreferences.getInstance().then(
                    (prefs) => prefs.setInt('recent_messages_limit', v),
                  );
                },
              ),
            ],
          ),
          SwitchListTile(
            secondary: const Icon(Icons.reply),
            title: const Text('Reply to thread root'),
            subtitle: const Text(
              'Always reply to the first message in a thread instead of the latest',
            ),
            value: _replyToRoot,
            onChanged: (value) async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('reply_to_thread_root', value);
              if (mounted) setState(() => _replyToRoot = value);
              widget.onReplyToRootChanged?.call(value);
            },
          ),
          ListTile(
            leading: const Icon(Icons.merge_type),
            title: const Text('Shared chat messages'),
            subtitle: Text(_sharedChatModeLabel),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickSharedChatMode,
          ),
          ListTile(
            leading: const Icon(Icons.visibility_off),
            title: const Text('Ignores'),
            subtitle: const Text('Hide users or rewrite keywords locally'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const IgnoresScreen()),
              );
            },
          ),
          const _MentionFormatTile(),
          if (widget.twitchAuth != null)
            ListTile(
              leading: const Icon(Icons.bolt),
              title: const Text('Command macros'),
              subtitle: const Text(
                'Custom triggers like "!so" that expand on send',
              ),
              trailing: const Icon(Icons.chevron_right),
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
          _sectionHeader('UI'),
          SwitchListTile(
            secondary: const Icon(Icons.schedule),
            title: const Text('Show timestamps'),
            subtitle: const Text('Display a timestamp before every message'),
            value: _showTimestamps,
            onChanged: (value) async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool(kShowTimestampsPrefKey, value);
              if (mounted) setState(() => _showTimestamps = value);
              widget.onShowTimestampsChanged?.call(value);
            },
          ),
          ListTile(
            leading: const Icon(Icons.access_time),
            title: const Text('Timestamp format'),
            subtitle: Text(_timestampFormat),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickTimestampFormat,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.format_paint),
            title: const Text('7TV name paints'),
            subtitle: const Text(
              'Gradient username colors for 7TV subscribers',
            ),
            value: _namePaints,
            onChanged: (value) async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('seventv_name_paints', value);
              if (mounted) setState(() => _namePaints = value);
              widget.onNamePaintsChanged?.call(value);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.sentiment_very_satisfied),
            title: const Text('Prefer emote suggestions'),
            subtitle: const Text('Show emotes above usernames in autocomplete'),
            value: _preferEmotesFirst,
            onChanged: (value) async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('prefer_emotes_first', value);
              if (mounted) setState(() => _preferEmotesFirst = value);
              widget.onPreferEmotesFirstChanged?.call(value);
            },
          ),
          _sectionHeader('Notifications'),
          ListTile(
            leading: const Icon(Icons.notifications),
            title: const Text('Pings'),
            trailing: const Icon(Icons.chevron_right),
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
            SwitchListTile(
              secondary: const Icon(Icons.notifications_active),
              title: const Text('Mention notifications'),
              subtitle: const Text(
                'Get a notification when someone mentions you in chat',
              ),
              value: _mentionPush,
              onChanged: (value) async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('mention_push', value);
                if (mounted) setState(() => _mentionPush = value);
                widget.onMentionPushChanged?.call(value);
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.chat_bubble),
              title: const Text('Whisper notifications'),
              subtitle: const Text('Notify when someone whispers you'),
              value: _whisperNotify,
              onChanged: (value) async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('whisper_notifications', value);
                if (mounted) setState(() => _whisperNotify = value);
                widget.onWhisperNotifyChanged?.call(value);
              },
            ),
          ],
          _sectionHeader('Connection'),
          SwitchListTile(
            secondary: const Icon(Icons.wifi_tethering),
            title: const Text('Keep chat alive in background'),
            subtitle: const Text(
              'Stays connected while the app is in the background',
            ),
            value: _backgroundService,
            onChanged: (value) async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('background_service', value);
              if (mounted) setState(() => _backgroundService = value);
              widget.onBackgroundServiceChanged?.call(value);
            },
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
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() => _format = prefs.getString('mention_format') ?? '@name');
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mention_format', selected);
    if (mounted) setState(() => _format = selected);
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.text_format),
      title: const Text('Mention format'),
      subtitle: Text(
        'How tapping "Mention user" inserts the name: ${formats[_format]}',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: _pick,
    );
  }
}
