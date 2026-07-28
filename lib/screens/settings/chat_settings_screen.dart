import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'pings_screen.dart';

class ChatSettingsScreen extends StatefulWidget {
  const ChatSettingsScreen({super.key});

  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  int _maxMessagesPerChannel = 200;
  bool _replyToRoot = false;

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
        _replyToRoot = prefs.getBool('reply_to_thread_root') ?? false;
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
          ListTile(
            leading: const Icon(Icons.notifications),
            title: const Text('Pings'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const PingsScreen(),
                ),
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
        ],
      ),
    );
  }
}
