import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../emotes/emote.dart';
import '../emotes/emote_catalog.dart';
import '../models/twitch_message.dart';
import 'emote_manager.dart';

class _EmoteCount {
  Emote emote;
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
  final DateTime trackingStartedAt;

  /// Last recorded event; channels idle past the retention window expire.
  DateTime lastActivityAt;

  _ChannelStats(this.trackingStartedAt) : lastActivityAt = trackingStartedAt;

  Map<String, dynamic> toJson() => {
    'total': totalMessages,
    'chatters': chatterCounts,
    'unique': uniqueChatters.toList(),
    'emotes': [
      for (final e in emoteCounts.values)
        {'emote': e.emote.toJson(), 'count': e.count},
    ],
    'words': wordCounts,
    'minutes': {for (final b in minuteBuckets.entries) '${b.key}': b.value},
    'bans': banCount,
    'timeouts': timeoutCount,
    'started': trackingStartedAt.millisecondsSinceEpoch,
    'last': lastActivityAt.millisecondsSinceEpoch,
  };

  static _ChannelStats? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final started = raw['started'];
    final last = raw['last'];
    if (started is! int || last is! int) return null;
    final stats = _ChannelStats(DateTime.fromMillisecondsSinceEpoch(started))
      ..lastActivityAt = DateTime.fromMillisecondsSinceEpoch(last)
      ..totalMessages = raw['total'] as int? ?? 0
      ..banCount = raw['bans'] as int? ?? 0
      ..timeoutCount = raw['timeouts'] as int? ?? 0;
    Map<String, int> counts(Object? m) => {
      if (m is Map<String, dynamic>)
        for (final e in m.entries)
          if (e.value is int) e.key: e.value as int,
    };
    stats.chatterCounts.addAll(counts(raw['chatters']));
    stats.wordCounts.addAll(counts(raw['words']));
    stats.uniqueChatters.addAll([
      for (final u in raw['unique'] as List<dynamic>? ?? const [])
        if (u is String) u,
    ]);
    for (final e in counts(raw['minutes']).entries) {
      final minute = int.tryParse(e.key);
      if (minute != null) stats.minuteBuckets[minute] = e.value;
    }
    for (final raw in raw['emotes'] as List<dynamic>? ?? const []) {
      if (raw is! Map<String, dynamic>) continue;
      try {
        final emote = Emote.fromJson(raw['emote'] as Map<String, dynamic>);
        stats.emoteCounts[emote.id] = _EmoteCount(
          emote,
          raw['count'] as int? ?? 0,
        );
      } catch (_) {
        // A malformed emote drops only itself.
      }
    }
    return stats;
  }
}

/// Where opted-in analytics persist between launches.
abstract interface class AnalyticsStore {
  Future<String?> read();
  Future<void> write(String data);
  Future<void> delete();
}

/// One JSON file in app support storage; never leaves the device.
class FileAnalyticsStore implements AnalyticsStore {
  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}analytics.json');
  }

  @override
  Future<String?> read() async {
    final file = await _file();
    return await file.exists() ? file.readAsString() : null;
  }

  @override
  Future<void> write(String data) async {
    final file = await _file();
    // Write then rename, so a kill mid-write never leaves half a file.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(data, flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<void> delete() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}

class AnalyticsService extends ChangeNotifier {
  static const _rateWindowMinutes = 60;

  /// Per-channel cap on each tracking map/set. Analytics is only read for
  /// top-N lists, so dropping the oldest keys past this keeps memory bounded
  /// without changing the visible results for normal chat.
  static const _maxTrackedPerChannel = 5000;

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

  final EmoteLookup? Function(String channel, String? senderTwitchId)?
  _emoteLookup;
  final DateTime Function() _now;
  final Set<String> stopwords;

  final _channels = <String, _ChannelStats>{};

  /// Null keeps stats in memory only (tests, previews).
  final AnalyticsStore? _store;
  bool _enabled;
  Timer? _saveTimer;
  bool _dirty = false;

  /// Channels idle longer than this are dropped on load and save.
  static const retention = Duration(hours: 24);

  /// Coalesces bursts of chat into one write.
  static const saveDelay = Duration(minutes: 2);

  AnalyticsService({
    this._emoteLookup,
    DateTime Function()? now,
    this.stopwords = defaultStopwords,
    this._store,
    this._enabled = true,
  }) : _now = now ?? DateTime.now;

  bool get enabled => _enabled;

  /// Opt-in switch. On loads the saved stats; off drops them everywhere.
  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    if (value) {
      await load();
      return;
    }
    _saveTimer?.cancel();
    _saveTimer = null;
    _dirty = false;
    _channels.clear();
    _scheduleNotify();
    await _store?.delete();
  }

  /// Restores saved stats, keeping only channels active within [retention].
  /// Live counts recorded before the load finishes win over saved ones.
  Future<void> load() async {
    final store = _store;
    if (store == null || !_enabled) return;
    try {
      final raw = await store.read();
      if (raw == null || !_enabled) return;
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) return;
      for (final entry in data.entries) {
        final stats = _ChannelStats.fromJson(entry.value);
        if (stats != null) _channels.putIfAbsent(entry.key, () => stats);
      }
      _dropExpired();
      _scheduleNotify();
    } catch (_) {
      // A corrupt file starts fresh; the next save overwrites it.
    }
  }

  /// Writes pending stats now (also on app pause).
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final store = _store;
    if (store == null || !_enabled || !_dirty) return;
    _dirty = false;
    _dropExpired();
    await store.write(
      jsonEncode({for (final e in _channels.entries) e.key: e.value.toJson()}),
    );
  }

  void _dropExpired() {
    final cutoff = _now().subtract(retention);
    _channels.removeWhere((_, s) => s.lastActivityAt.isBefore(cutoff));
  }

  void _touch(_ChannelStats stats) {
    stats.lastActivityAt = _now();
    _markDirty();
  }

  void _markDirty() {
    _dirty = true;
    if (_store != null) _saveTimer ??= Timer(saveDelay, () => flush());
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  _ChannelStats? _stats(String channel) => _channels[channel];

  _ChannelStats _statsFor(String channel) {
    return _channels.putIfAbsent(channel, () => _ChannelStats(_now()));
  }

  void recordMessage(String channel, TwitchMessage msg) {
    if (!_enabled) return;
    if (msg.isSystem || msg.isHistory || msg.isBackfill) return;
    final stats = _statsFor(channel);
    _touch(stats);
    final now = _now();
    stats.totalMessages++;
    final login = msg.login.trim().toLowerCase();
    if (login.isNotEmpty) {
      stats.uniqueChatters.add(login);
      stats.chatterCounts[login] = (stats.chatterCounts[login] ?? 0) + 1;
      _capSet(stats.uniqueChatters);
      _capMap(stats.chatterCounts);
    }
    final minute = now.millisecondsSinceEpoch ~/ 60000;
    stats.minuteBuckets[minute] = (stats.minuteBuckets[minute] ?? 0) + 1;
    _pruneBuckets(stats, now);
    _countTokens(stats, channel, msg);
    _scheduleNotify();
  }

  void recordModeration(String channel, bool isTimeout) {
    if (!_enabled) return;
    final stats = _statsFor(channel);
    _touch(stats);
    if (isTimeout) {
      stats.timeoutCount++;
    } else {
      stats.banCount++;
    }
    _scheduleNotify();
  }

  // Resets persist too, or a cleared channel would return on next launch.
  void resetChannel(String channel) {
    if (_channels.remove(channel) == null) return;
    _markDirty();
    _scheduleNotify();
  }

  void resetAll() {
    if (_channels.isEmpty) return;
    _channels.clear();
    _markDirty();
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

  List<({Emote emote, int count})> topEmotes(String channel, int n) {
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
    final stamped = msg.emoteTokens;
    final positions = msg.emotePositions;
    // Ingest already stamped the emote tokens; an empty stamp with Twitch
    // positions means the catalog was missing, so tokenize for those.
    if (stamped != null &&
        (stamped.isNotEmpty || positions == null || positions.isEmpty)) {
      _countStamped(stats, msg.text, stamped);
      return;
    }
    final byCode = _emoteLookup?.call(channel, msg.userId)?.byCode ?? const {};
    final tokens = EmoteManager.tokenize(
      text: msg.text,
      positions: msg.emotePositions,
      byCode: byCode,
    );
    for (final token in tokens) {
      final emote = token.emote;
      if (emote != null) {
        _countEmote(stats, emote);
      } else if (token.text.trim().isNotEmpty) {
        _countWord(stats, token.text);
      }
    }
  }

  /// Counts [tokens] as emotes and the text between them as words.
  void _countStamped(
    _ChannelStats stats,
    String text,
    List<EmoteToken> tokens,
  ) {
    var cursor = 0;
    for (final token in tokens) {
      final start = token.start.clamp(cursor, text.length);
      _countGapWords(stats, text.substring(cursor, start));
      final emote = token.emote;
      if (emote != null) _countEmote(stats, emote);
      cursor = token.end.clamp(start, text.length);
    }
    _countGapWords(stats, text.substring(cursor));
  }

  void _countGapWords(_ChannelStats stats, String gap) {
    for (final word in gap.split(_whitespace)) {
      if (word.isNotEmpty) _countWord(stats, word);
    }
  }

  static final _whitespace = RegExp(r'\s+');

  void _countEmote(_ChannelStats stats, Emote emote) {
    final entry = stats.emoteCounts.putIfAbsent(
      emote.id,
      () => _EmoteCount(emote, 0),
    );
    entry.count++;
    _capMap(stats.emoteCounts);
  }

  void _countWord(_ChannelStats stats, String token) {
    final word = _normalizeWord(token);
    if (word.isEmpty) return;
    stats.wordCounts[word] = (stats.wordCounts[word] ?? 0) + 1;
    _capMap(stats.wordCounts);
  }

  /// Drops oldest entries (insertion order) once a map exceeds the cap.
  static void _capMap<K, V>(Map<K, V> map) {
    while (map.length > _maxTrackedPerChannel) {
      map.remove(map.keys.first);
    }
  }

  static void _capSet(Set<String> set) {
    while (set.length > _maxTrackedPerChannel) {
      set.remove(set.first);
    }
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
