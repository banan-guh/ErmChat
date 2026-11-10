import 'dart:async';
import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../widgets/emote_scale_resolver.dart';
import '../../emotes/emote_picker.dart';
import '../../widgets/tabbed_layout.dart';
import '../../services/analytics_service.dart';
import '../../services/emote_images.dart';
import '../../util/settings.dart';
import 'settings_page.dart';

/// Formats the elapsed tracking time (e.g. `1h 5m`, `3m 2s`, `12s`).
String formatAnalyticsElapsed(DateTime start) {
  final elapsed = DateTime.now().difference(start);
  final hours = elapsed.inHours;
  final minutes = elapsed.inMinutes % 60;
  final seconds = elapsed.inSeconds % 60;
  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m ${seconds}s';
  return '${seconds}s';
}

/// Self-contained one-second ticker for the "Tracking for" value. The
/// analytics screen used to run a screen-wide 1s `Timer.periodic` + `setState`
/// that rebuilt the whole `TabbedLayout` every second; when one of those
/// rebuilds landed mid-swipe/scroll the framework threw `child.hasSize` /
/// `RenderBox was not laid out` layout assertions. Ticking only this small
/// text in place never changes the list structure, so it can't trigger that.
class _ElapsedText extends StatefulWidget {
  const _ElapsedText({this.startedAt});

  final DateTime? startedAt;

  @override
  State<_ElapsedText> createState() => _ElapsedTextState();
}

class _ElapsedTextState extends State<_ElapsedText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(_ElapsedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer();
  }

  void _syncTimer() {
    final started = widget.startedAt;
    if (started == null) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final started = widget.startedAt;
    return Text(
      started == null ? '0s' : formatAnalyticsElapsed(started),
      style: const TextStyle(fontWeight: FontWeight.w600),
    );
  }
}

class AnalyticsScreen extends StatefulWidget {
  final AnalyticsService analyticsService;
  final List<String> channels;
  final EmoteImages images;

  const AnalyticsScreen({
    super.key,
    required this.analyticsService,
    required this.channels,
    required this.images,
  });

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  String? _selectedChannel;

  String? get _channel {
    if (widget.channels.isEmpty) return null;
    final selected = _selectedChannel;
    if (selected != null && widget.channels.contains(selected)) {
      return selected;
    }
    return widget.channels.first;
  }

  int get _channelIndex {
    final channels = widget.channels;
    if (channels.isEmpty) return 0;
    final selected = _selectedChannel;
    if (selected != null) {
      final idx = channels.indexOf(selected);
      if (idx != -1) return idx;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.analyticsTitle),
      actions: [
        if (_channel != null)
          PopupMenuButton<String>(
            icon: const Icon(Icons.refresh),
            tooltip: context.l10n.resetStats,
            onSelected: (value) {
              final service = widget.analyticsService;
              if (value == 'channel') {
                service.resetChannel(_channel!);
              } else if (value == 'all') {
                service.resetAll();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'channel',
                child: Text(context.l10n.resetThisChannel),
              ),
              PopupMenuItem(
                value: 'all',
                child: Text(context.l10n.resetAllChannels),
              ),
            ],
          ),
      ],
      body: Column(
        children: [
          SwitchListTile(
            title: Text(context.l10n.trackChatStats),
            subtitle: Text(context.l10n.trackChatStatsHint),
            value: widget.analyticsService.enabled,
            onChanged: _setEnabled,
          ),
          const Divider(height: 1),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Future<void> _setEnabled(bool value) async {
    await Settings.analyticsEnabled.set(value);
    await widget.analyticsService.setEnabled(value);
    if (mounted) setState(() {});
  }

  Widget _body(BuildContext context) {
    if (!widget.analyticsService.enabled) return const SizedBox.shrink();
    return widget.channels.isEmpty
        ? Center(child: Text(context.l10n.joinChannelForStats))
        : TabbedLayout(
            tabs: widget.channels,
            selectedIndex: _channelIndex,
            onSelectedIndexChanged: (i) {
              setState(() => _selectedChannel = widget.channels[i]);
            },
            tabBarColor: Theme.of(context).colorScheme.surface,
            // The ListenableBuilder is scoped to the page content rather
            // than the whole TabbedLayout so a live message never rebuilds
            // the tab bar / controller mid-swipe.
            pageBuilder: (context, i) => ListenableBuilder(
              listenable: widget.analyticsService,
              builder: (context, _) => _buildStats(context, widget.channels[i]),
            ),
          );
  }

  Widget _buildStats(BuildContext context, String channel) {
    final service = widget.analyticsService;

    return ValueListenableBuilder<bool>(
      valueListenable: Settings.analyticsFilterStopwords,
      builder: (context, useStopwords, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _summaryCard(context, channel),
          const SizedBox(height: 16),
          if (service.banCount(channel) > 0 ||
              service.timeoutCount(channel) > 0) ...[
            _moderationCard(context, channel),
            const SizedBox(height: 16),
          ],
          _sectionHeader(context, context.l10n.topChatters),
          ..._rankedRows(
            service.topChatters(channel, 10),
            label: (entry) => entry.name,
            count: (entry) => entry.count,
            emptyText: context.l10n.noMessagesYet,
          ),
          const SizedBox(height: 16),
          _sectionHeader(context, context.l10n.topEmotes),
          ..._rankedRows(
            service.topEmotes(channel, 10),
            label: (entry) => entry.emote.code,
            count: (entry) => entry.count,
            emptyText: context.l10n.noEmotesYet,
            leading: (entry) => EmoteScaleResolver(
              emote: entry.emote,
              surface: EmoteSurface.grid,
              images: widget.images,
              width: 28,
              height: 28,
              fit: BoxFit.contain,
              errorWidget: const SizedBox(width: 28, height: 28),
            ),
          ),
          const SizedBox(height: 16),
          _sectionHeader(context, context.l10n.topWords),
          SwitchListTile(
            secondary: const Icon(Icons.filter_alt),
            title: Text(context.l10n.filterCommonWords),
            value: useStopwords,
            onChanged: (value) => Settings.analyticsFilterStopwords.set(value),
          ),
          ..._rankedRows(
            service.topWords(channel, 15, useStopwords: useStopwords),
            label: (entry) => entry.word,
            count: (entry) => entry.count,
            emptyText: context.l10n.noWordsYet,
          ),
        ],
      ),
    );
  }

  /// The channel's totals, pace and tracking time.
  Widget _summaryCard(BuildContext context, String channel) {
    final service = widget.analyticsService;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(channel, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            _summaryRow(
              context.l10n.totalMessages,
              '${service.totalMessages(channel)}',
            ),
            _summaryRow(
              context.l10n.uniqueChatters,
              '${service.uniqueChatters(channel)}',
            ),
            _summaryRow(
              context.l10n.messagesPerMinute,
              service.messagesPerMinute(channel).toStringAsFixed(1),
            ),
            _summaryRowWidget(
              context.l10n.trackingFor,
              _ElapsedText(startedAt: service.trackingStartedAt(channel)),
            ),
          ],
        ),
      ),
    );
  }

  /// The channel's bans and timeouts.
  Widget _moderationCard(BuildContext context, String channel) {
    final service = widget.analyticsService;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.moderation,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            _summaryRow(context.l10n.bans, '${service.banCount(channel)}'),
            _summaryRow(
              context.l10n.timeouts,
              '${service.timeoutCount(channel)}',
            ),
          ],
        ),
      ),
    );
  }

  /// One ranking's rows: [label] beside [count], behind an optional
  /// [leading], or [emptyText] when nothing is ranked yet.
  List<Widget> _rankedRows<T>(
    List<T> items, {
    required String Function(T item) label,
    required int Function(T item) count,
    required String emptyText,
    Widget Function(T item)? leading,
  }) {
    if (items.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(emptyText),
        ),
      ];
    }
    return [
      for (final item in items)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: leading?.call(item),
          title: Text(label(item)),
          trailing: Text('${count(item)}'),
        ),
    ];
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  Widget _summaryRow(String label, String value) {
    return _summaryRowWidget(
      label,
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }

  Widget _summaryRowWidget(String label, Widget value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [Text(label), value],
      ),
    );
  }
}
