import 'package:flutter/foundation.dart';
import '../models/generic_emote.dart';
import '../models/twitch_message.dart';
import 'emote_manager.dart';

class _EmoteCount {
  GenericEmote emote;
  int count;

  _EmoteCount(this.emote, this.count);
}

class _ChannelStats {
  int totalMessages = 0;
  final chatterCounts = <String, int>{};
  final uniqueChatters = <String>{};
  final emoteCounts = <String, _EmoteCount>{};
  final wordCounts = <String, int>{};
  final minuteBuckets = <int, int>{};
  int banCount = 0;
  int timeoutCount = 0;
  late final DateTime trackingStartedAt;

  _ChannelStats(DateTime Function() now) {
    trackingStartedAt = now();
  }
}

class AnalyticsService extends ChangeNotifier {
  static const _rateWindowMinutes = 60;

  /// Coalesces rapid notifyListeners() calls into a single microtask turn.
  bool _notifyPending = false;

  void _scheduleNotify() {
    if (_notifyPending) return;
    _notifyPending = true;
    scheduleMicrotask(() {
      _notifyPending = false;
      notifyListeners();
    });
  }

  static const defaultStopwords = {
    'a',
    'an',
    'and',
    'are',
    'as',
    'at',
    'be',
    'been',
    'but',
    'by',
    'for',
    'from',
    'he',
    'her',
    'his',
    'i',
    'in',
    'is',
    'it',
    'its',
    'me',
    'my',
    'not',
    'of',
    'on',
    'or',
    'our',
    'she',
    'so',
    'that',
    'the',
    'their',
    'them',
    'there',
    'they',
    'this',
    'to',
    'was',
    'we',
    'were',
    'what',
    'when',
    'who',
    'will',
    'with',
    'you',
    'your',
  };

  final ChannelEmotes? Function(String channel)? _emoteLookup;
  final DateTime Function() _now;
  final Set<String> stopwords;

  final _channels = <String, _ChannelStats>{};

  AnalyticsService({
    this._emoteLookup,
    DateTime Function()? now,
    this.stopwords = defaultStopwords,
  }) : _now = now ?? DateTime.now;

  _ChannelStats? _stats(String channel) => _channels[channel];

  _ChannelStats _statsFor(String channel) {
    return _channels.putIfAbsent(channel, () => _ChannelStats(_now));
  }

  void recordMessage(String channel, TwitchMessage msg) {
    if (msg.isSystem || msg.isHistory || msg.isBackfill) return;
    final stats = _statsFor(channel);
    final now = _now();
    stats.totalMessages++;
    final login = msg.login.trim().toLowerCase();
    if (login.isNotEmpty) {
      stats.uniqueChatters.add(login);
      stats.chatterCounts[login] = (stats.chatterCounts[login] ?? 0) + 1;
    }
    final minute = now.millisecondsSinceEpoch ~/ 60000;
    stats.minuteBuckets[minute] = (stats.minuteBuckets[minute] ?? 0) + 1;
    _pruneBuckets(stats, now);
    _countTokens(stats, channel, msg);
    _scheduleNotify();
  }

  void recordModeration(String channel, bool isTimeout) {
    final stats = _statsFor(channel);
    if (isTimeout) {
      stats.timeoutCount++;
    } else {
      stats.banCount++;
    }
    _scheduleNotify();
  }

  void resetChannel(String channel) {
    if (_channels.remove(channel) != null) _scheduleNotify();
  }

  void resetAll() {
    if (_channels.isEmpty) return;
    _channels.clear();
    _scheduleNotify();
  }

  List<String> trackedChannels() => _channels.keys.toList();

  bool isTracking(String channel) => _channels.containsKey(channel);

  int totalMessages(String channel) => _stats(channel)?.totalMessages ?? 0;

  int uniqueChatters(String channel) {
    return _stats(channel)?.uniqueChatters.length ?? 0;
  }

  int banCount(String channel) => _stats(channel)?.banCount ?? 0;

  int timeoutCount(String channel) => _stats(channel)?.timeoutCount ?? 0;

  DateTime? trackingStartedAt(String channel) =>
      _stats(channel)?.trackingStartedAt;

  double messagesPerMinute(String channel) {
    final stats = _stats(channel);
    if (stats == null) return 0;
    final now = _now();
    _pruneBuckets(stats, now);
    var windowTotal = 0;
    for (final count in stats.minuteBuckets.values) {
      windowTotal += count;
    }
    if (windowTotal == 0) return 0;
    var elapsed = now.difference(stats.trackingStartedAt).inMinutes;
    if (elapsed < 1) elapsed = 1;
    if (elapsed > _rateWindowMinutes) elapsed = _rateWindowMinutes;
    return windowTotal / elapsed;
  }

  List<({String name, int count})> topChatters(String channel, int n) {
    final stats = _stats(channel);
    if (stats == null) return const [];
    final sorted = stats.chatterCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(n).map((e) => (name: e.key, count: e.value)).toList();
  }

  List<({GenericEmote emote, int count})> topEmotes(String channel, int n) {
    final stats = _stats(channel);
    if (stats == null) return const [];
    final sorted = stats.emoteCounts.values.toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    return sorted.take(n).map((e) => (emote: e.emote, count: e.count)).toList();
  }

  List<({String word, int count})> topWords(
    String channel,
    int n, {
    bool useStopwords = false,
  }) {
    final stats = _stats(channel);
    if (stats == null) return const [];
    final sorted =
        stats.wordCounts.entries
            .where((e) => !useStopwords || !stopwords.contains(e.key))
            .toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(n).map((e) => (word: e.key, count: e.value)).toList();
  }

  void _countTokens(_ChannelStats stats, String channel, TwitchMessage msg) {
    final byCode = _emoteLookup?.call(channel)?.byCode;
    final text = msg.text;
    final sortedPos = msg.emotePositions ?? const <EmotePosition>[];

    EmotePosition? posAt(int i) {
      var idx = 0;
      while (idx < sortedPos.length && sortedPos[idx].endIndex <= i) {
        idx++;
      }
      if (idx < sortedPos.length && i >= sortedPos[idx].startIndex) {
        return sortedPos[idx];
      }
      return null;
    }

    int i = 0;
    while (i < text.length) {
      final pos = posAt(i);
      if (pos != null) {
        final lookup = byCode?[pos.emoteCode];
        final emote =
            lookup ??
            GenericEmote(
              id: pos.emoteId,
              code: pos.emoteCode,
              type: EmoteType.twitch,
              url:
                  'https://static-cdn.jtvnw.net/emoticons/v2/${pos.emoteId}/default/dark/3.0',
            );
        _countEmote(stats, emote);
        i = pos.endIndex;
        continue;
      }

      if (text[i] == ' ' || text[i] == '\t' || text[i] == '\n') {
        i++;
        continue;
      }

      final start = i;
      while (i < text.length &&
          text[i] != ' ' &&
          text[i] != '\t' &&
          text[i] != '\n' &&
          posAt(i) == null) {
        i++;
      }
      final token = text.substring(start, i);
      final emote = byCode?[token];
      if (emote != null) {
        _countEmote(stats, emote);
      } else {
        _countWord(stats, token);
      }
    }
  }

  void _countEmote(_ChannelStats stats, GenericEmote emote) {
    final entry = stats.emoteCounts.putIfAbsent(
      emote.id,
      () => _EmoteCount(emote, 0),
    );
    entry.count++;
  }

  void _countWord(_ChannelStats stats, String token) {
    final word = _normalizeWord(token);
    if (word.isEmpty) return;
    stats.wordCounts[word] = (stats.wordCounts[word] ?? 0) + 1;
  }

  static final _leadingNonAlnum = RegExp(r'^[^a-z0-9]+');
  static final _trailingNonAlnum = RegExp(r'[^a-z0-9]+$');

  String _normalizeWord(String token) {
    var word = token.toLowerCase();
    word = word.replaceFirst(_leadingNonAlnum, '');
    word = word.replaceAll(_trailingNonAlnum, '');
    return word;
  }

  void _pruneBuckets(_ChannelStats stats, DateTime now) {
    final cutoff = now.millisecondsSinceEpoch ~/ 60000 - _rateWindowMinutes;
    stats.minuteBuckets.removeWhere((minute, _) => minute < cutoff);
  }
}
