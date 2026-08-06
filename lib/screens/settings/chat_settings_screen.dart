import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  int _maxMessagesPerChannel = 200;
  int _recentMessagesCount = 100;
  bool _replyToRoot = false;
  bool _backgroundService = true;
  bool _mentionPush = false;
  bool _preferEmotesFirst = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _maxMessagesPerChannel =
            prefs.getInt('max_messages_per_channel') ?? 200;
        _recentMessagesCount = prefs.getInt('recent_messages_limit') ?? 100;
        _replyToRoot = prefs.getBool('reply_to_thread_root') ?? false;
        _backgroundService = prefs.getBool('background_service') ?? true;
        _mentionPush = prefs.getBool('mention_push') ?? false;
        _preferEmotesFirst = prefs.getBool('prefer_emotes_first') ?? false;
      });
    }
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
                value: _maxMessagesPerChannel.toDouble(),
                min: 100,
                max: 1000,
                divisions: 9,
                label: '$_maxMessagesPerChannel',
                onChanged: (value) async {
                  final v = value.toInt();
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
                min: 10,
                max: 500,
                divisions: 49,
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
            subtitle: const Text(
              'Show emotes above usernames in autocomplete',
            ),
            value: _preferEmotesFirst,
            onChanged: (value) async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('prefer_emotes_first', value);
              if (mounted) setState(() => _preferEmotesFirst = value);
            },
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
