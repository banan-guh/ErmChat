import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../util/constants.dart';
import '../../util/timestamp_formatter.dart';
import 'pings_screen.dart';

class ChatSettingsScreen extends StatefulWidget {
  final ValueChanged<bool>? onBackgroundServiceChanged;
  final ValueChanged<bool>? onMentionPushChanged;

  const ChatSettingsScreen({
    super.key,
    this.onBackgroundServiceChanged,
    this.onMentionPushChanged,
  });

  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  int _maxMessagesPerChannel = 1000;
  int _recentMessagesCount = 200;
  bool _replyToRoot = false;
  bool _backgroundService = false;
  bool _mentionPush = false;
  bool _preferEmotesFirst = false;
  bool _showTimestamps = true;
  String _timestampFormat = kDefaultTimestampFormat;

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
          prefs.getInt('max_messages_per_channel') ?? 1000,
        );
        _recentMessagesCount = prefs.getInt('recent_messages_limit') ?? 200;
        _replyToRoot = prefs.getBool('reply_to_thread_root') ?? false;
        _backgroundService = prefs.getBool('background_service') ?? true;
        _mentionPush = prefs.getBool('mention_push') ?? false;
        _preferEmotesFirst = prefs.getBool('prefer_emotes_first') ?? false;
        _showTimestamps = prefs.getBool(kShowTimestampsPrefKey) ?? true;
        _timestampFormat =
            prefs.getString(kTimestampFormatPrefKey) ?? kDefaultTimestampFormat;
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chat')),
      body: ListView(
        children: [
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
                onChanged: (value) async {
                  final v = kMaxMessagesPerChannelValues[value.round()];
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setInt('max_messages_per_channel', v);
                  if (mounted) setState(() => _maxMessagesPerChannel = v);
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
                max: 500,
                divisions: 10,
                label: '$_recentMessagesCount',
                onChanged: (value) async {
                  final v = value.toInt();
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setInt('recent_messages_limit', v);
                  if (mounted) setState(() => _recentMessagesCount = v);
                },
              ),
            ],
          ),
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
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.schedule),
            title: const Text('Show timestamps'),
            subtitle: const Text('Display a timestamp before every message'),
            value: _showTimestamps,
            onChanged: (value) async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool(kShowTimestampsPrefKey, value);
              if (mounted) setState(() => _showTimestamps = value);
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
        ],
      ),
    );
  }
}
