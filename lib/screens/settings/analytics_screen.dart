import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../widgets/emote_image.dart';
import '../../models/generic_emote.dart';
import '../../services/analytics_service.dart';

class AnalyticsScreen extends StatefulWidget {
  final AnalyticsService analyticsService;
  final List<String> channels;

  const AnalyticsScreen({
    super.key,
    required this.analyticsService,
    required this.channels,
  });

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  static const _stopwordsPrefKey = 'analytics_filter_stopwords';

  String? _selectedChannel;
  bool _useStopwords = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _useStopwords = prefs.getBool(_stopwordsPrefKey) ?? false);
  }

  Future<void> _setStopwords(bool value) async {
    setState(() => _useStopwords = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_stopwordsPrefKey, value);
  }

  String? get _channel {
    if (widget.channels.isEmpty) return null;
    final selected = _selectedChannel;
    if (selected != null && widget.channels.contains(selected)) {
      return selected;
    }
    return widget.channels.first;
  }

  String _formatElapsed(DateTime start) {
    final elapsed = DateTime.now().difference(start);
    final hours = elapsed.inHours;
    final minutes = elapsed.inMinutes % 60;
    final seconds = elapsed.inSeconds % 60;
    if (hours > 0) return '${hours}h ${minutes}m';
    if (minutes > 0) return '${minutes}m ${seconds}s';
    return '${seconds}s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics'),
        actions: [
          if (_channel != null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reset stats',
              onSelected: (value) {
                final service = widget.analyticsService;
                if (value == 'channel') {
                  service.resetChannel(_channel!);
                } else if (value == 'all') {
                  service.resetAll();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'channel',
                  child: Text('Reset this channel'),
                ),
                PopupMenuItem(value: 'all', child: Text('Reset all channels')),
              ],
            ),
        ],
      ),
      body: widget.channels.isEmpty
          ? const Center(child: Text('Join a channel to start tracking stats'))
          : Column(
              children: [
                SizedBox(
                  height: 48,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final channel in widget.channels)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(channel),
                            selected: channel == _channel,
                            onSelected: (_) {
                              setState(() => _selectedChannel = channel);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: widget.analyticsService,
                    builder: (context, _) => _buildStats(context),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildStats(BuildContext context) {
    final service = widget.analyticsService;
    final channel = _channel;
    if (channel == null) {
      return const Center(
        child: Text('Join a channel to start tracking stats'),
      );
    }
    final theme = Theme.of(context);
    final startedAt = service.trackingStartedAt(channel);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(channel, style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                _summaryRow(
                  'Total messages',
                  '${service.totalMessages(channel)}',
                ),
                _summaryRow(
                  'Unique chatters',
                  '${service.uniqueChatters(channel)}',
                ),
                _summaryRow(
                  'Messages per minute',
                  service.messagesPerMinute(channel).toStringAsFixed(1),
                ),
                _summaryRow(
                  'Tracking for',
                  startedAt == null ? '0s' : _formatElapsed(startedAt),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (service.banCount(channel) > 0 ||
            service.timeoutCount(channel) > 0) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Moderation', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  _summaryRow('Bans', '${service.banCount(channel)}'),
                  _summaryRow('Timeouts', '${service.timeoutCount(channel)}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        _sectionHeader(context, 'Top chatters'),
        ..._buildChatterRows(service.topChatters(channel, 10)),
        const SizedBox(height: 16),
        _sectionHeader(context, 'Top emotes'),
        ..._buildEmoteRows(service.topEmotes(channel, 10)),
        const SizedBox(height: 16),
        _sectionHeader(context, 'Top words'),
        SwitchListTile(
          secondary: const Icon(Icons.filter_alt),
          title: const Text('Filter common words'),
          value: _useStopwords,
          onChanged: _setStopwords,
        ),
        ..._buildWordRows(
          service.topWords(channel, 15, useStopwords: _useStopwords),
        ),
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  Widget _summaryRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  List<Widget> _buildChatterRows(List<({String name, int count})> chatters) {
    if (chatters.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('No messages yet'),
        ),
      ];
    }
    return [
      for (final entry in chatters)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(entry.name),
          trailing: Text('${entry.count}'),
        ),
    ];
  }

  List<Widget> _buildEmoteRows(List<({GenericEmote emote, int count})> emotes) {
    if (emotes.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('No emotes yet'),
        ),
      ];
    }
    return [
      for (final entry in emotes)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: EmoteImage(
            url: entry.emote.url,
            width: 28,
            height: 28,
            fit: BoxFit.contain,
            placeholder: const ShimmerEmotePlaceholder(width: 28, height: 28),
            errorWidget: const SizedBox(width: 28, height: 28),
          ),
          title: Text(entry.emote.code),
          trailing: Text('${entry.count}'),
        ),
    ];
  }

  List<Widget> _buildWordRows(List<({String word, int count})> words) {
    if (words.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('No words yet'),
        ),
      ];
    }
    return [
      for (final entry in words)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(entry.word),
          trailing: Text('${entry.count}'),
        ),
    ];
  }
}
