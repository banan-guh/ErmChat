import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'prefs.dart';

/// Where counted bytes come from, one per usage row.
enum DataSource {
  chat,
  sent,
  history,
  twitchApi,
  events,
  emoteLists,
  emoteImages,
}

/// A time window for the usage rows.
enum UsagePeriod { session, day, week, month, all }

/// A count since install, and the part taken on mobile data.
class SessionCount {
  int all = 0;
  int mobile = 0;

  int of({required bool mobileOnly}) => mobileOnly ? mobile : all;
}

/// Lightweight numeric data-usage aggregator for the mobile data-saver work.
///
/// Counts bytes by source (IRC sockets, emote image downloads, provider JSON),
/// so we can see where bandwidth goes. The counters are plain ints mutated
/// only on the UI isolate, so no locking is needed. Totals persist across
/// launches; [load] runs at boot and [flush] when the app pauses.
class DataUsageStats {
  DataUsageStats._();
  static final DataUsageStats I = DataUsageStats._();

  int ircReadBytes = 0;
  int ircWriteBytes = 0;
  int emoteDownloadBytes = 0;
  int jsonBytes = 0;
  int historyBytes = 0;
  int helixBytes = 0;
  int eventBytes = 0;

  // What the data savers served without a download, against what they
  // fetched, for the Saved rows.
  final imagesFromDisk = SessionCount();
  final imageBytesFromDisk = SessionCount();
  final imagesDownloaded = SessionCount();
  final listsFromDisk = SessionCount();
  final listsFetched = SessionCount();
  final gapFetches = SessionCount();
  final gapsFilled = SessionCount();

  bool mobile = false;

  // The same counts taken only while [mobile], indexed by [DataSource].
  final _mobileBytes = List<int>.filled(DataSource.values.length, 0);

  void _countMobile(DataSource source, int bytes) {
    if (mobile) _mobileBytes[source.index] += bytes;
  }

  void recordIrcRead(int bytes) {
    ircReadBytes += bytes;
    _countMobile(DataSource.chat, bytes);
  }

  void recordIrcWrite(int bytes) {
    ircWriteBytes += bytes;
    _countMobile(DataSource.sent, bytes);
  }

  void recordEmoteDownload(int bytes) {
    emoteDownloadBytes += bytes;
    _countMobile(DataSource.emoteImages, bytes);
  }

  /// Emote list bytes per endpoint, ids starred, so the perf log shows
  /// which list fetches cost the most.
  void recordJson(int bytes) {
    jsonBytes += bytes;
    _countMobile(DataSource.emoteLists, bytes);
  }

  /// Recent-messages (robotty, zneix) response bodies.
  void recordHistory(int bytes) {
    historyBytes += bytes;
    _countMobile(DataSource.history, bytes);
  }

  /// Helix response bodies.
  void recordHelix(int bytes) {
    helixBytes += bytes;
    _countMobile(DataSource.twitchApi, bytes);
  }

  /// EventSub, PubSub and 7TV socket frames.
  void recordEvent(int bytes) {
    eventBytes += bytes;
    _countMobile(DataSource.events, bytes);
  }

  /// Bytes for [source], or only those sent or received on mobile data, over
  /// [period]. Windows include the unflushed session.
  int bytesFor(
    DataSource source, {
    bool mobileOnly = false,
    UsagePeriod period = UsagePeriod.session,
  }) {
    if (period == UsagePeriod.session) {
      if (mobileOnly) return _mobileBytes[source.index];
      return switch (source) {
        DataSource.chat => ircReadBytes,
        DataSource.sent => ircWriteBytes,
        DataSource.history => historyBytes,
        DataSource.twitchApi => helixBytes,
        DataSource.events => eventBytes,
        DataSource.emoteLists => jsonBytes,
        DataSource.emoteImages => emoteDownloadBytes,
      };
    }
    final index = mobileOnly ? 7 + source.index : source.index;
    final current = _currentValues();
    if (period == UsagePeriod.all) return current[index];
    final start = now().subtract(switch (period) {
      UsagePeriod.day => const Duration(days: 1),
      UsagePeriod.week => const Duration(days: 7),
      UsagePeriod.month => const Duration(days: 30),
      UsagePeriod.session || UsagePeriod.all => Duration.zero,
    });
    final before = _totalBefore(
      period == UsagePeriod.day ? _hours : _days,
      start,
    );
    final used = current[index] - before[index];
    return used > 0 ? used : 0;
  }

  int totalFor({
    bool mobileOnly = false,
    UsagePeriod period = UsagePeriod.session,
  }) => DataSource.values.fold(
    0,
    (sum, source) =>
        sum + bytesFor(source, mobileOnly: mobileOnly, period: period),
  );

  void _add(SessionCount c, [int n = 1]) {
    c.all += n;
    if (mobile) c.mobile += n;
  }

  /// An emote image read from disk ([bytes] long) or downloaded.
  void recordEmoteImage({required bool fromDisk, int bytes = 0}) {
    if (fromDisk) {
      _add(imagesFromDisk);
      _add(imageBytesFromDisk, bytes);
    } else {
      _add(imagesDownloaded);
    }
  }

  /// An emote list served from its fresh disk copy, or fetched.
  void recordEmoteList({required bool fromDisk}) =>
      _add(fromDisk ? listsFromDisk : listsFetched);

  /// A fetch of the whole history gap, and whether it reached the gap.
  void recordGapFetch({required bool filled}) {
    _add(gapFetches);
    if (filled) _add(gapsFilled);
  }

  /// [s]'s length in UTF-8 bytes, without encoding it.
  static int utf8Length(String s) {
    var bytes = 0;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c < 0x80) {
        bytes += 1;
      } else if (c < 0x800) {
        bytes += 2;
      } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
        // A surrogate pair is one 4-byte code point.
        bytes += 4;
        i++;
      } else {
        bytes += 3;
      }
    }
    return bytes;
  }

  void setMobile(bool isMobile) => mobile = isMobile;

  // ── Persistence ─────────────────────────────────────────────────────

  static const _key = 'data_usage_v1';
  bool _loaded = false;

  /// Test seam: the clock the window buckets read.
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  // Bytes per source since install at the last flush; [7..13] are mobile.
  List<int> _base = List<int>.filled(14, 0);
  // This session's counters at the last flush, so a flush adds only the delta.
  final List<int> _flushed = List<int>.filled(14, 0);

  // Cumulative [base] at the start of an hour and of a day, each entry
  // `[timestampMs, ...14]`. Windows subtract the entry before their start.
  List<List<int>> _hours = [];
  List<List<int>> _days = [];

  // The saved counters follow the same base plus session delta, so their
  // section can answer the period tabs too. [7..13] are mobile.
  List<int> _savedBase = List<int>.filled(14, 0);
  final List<int> _savedFlushed = List<int>.filled(14, 0);
  List<List<int>> _savedHours = [];
  List<List<int>> _savedDays = [];

  static const _savedNames = [
    'imagesFromDisk',
    'imageBytesFromDisk',
    'imagesDownloaded',
    'listsFromDisk',
    'listsFetched',
    'gapFetches',
    'gapsFilled',
  ];

  List<SessionCount> get _savedCounters => [
    imagesFromDisk,
    imageBytesFromDisk,
    imagesDownloaded,
    listsFromDisk,
    listsFetched,
    gapFetches,
    gapsFilled,
  ];

  /// [count] over [period], or only its mobile part.
  int savedCount(
    SessionCount count, {
    bool mobileOnly = false,
    UsagePeriod period = UsagePeriod.session,
  }) {
    final index = _savedCounters.indexOf(count);
    if (index < 0) return 0;
    final session = count.of(mobileOnly: mobileOnly);
    if (period == UsagePeriod.session) return session;
    final slot = mobileOnly ? 7 + index : index;
    final current = _savedBase[slot] + session - _savedFlushed[slot];
    if (period == UsagePeriod.all) return current;
    final start = now().subtract(switch (period) {
      UsagePeriod.day => const Duration(days: 1),
      UsagePeriod.week => const Duration(days: 7),
      UsagePeriod.month => const Duration(days: 30),
      UsagePeriod.session || UsagePeriod.all => Duration.zero,
    });
    final before = _totalBefore(
      period == UsagePeriod.day ? _savedHours : _savedDays,
      start,
    );
    final used = current - before[slot];
    return used > 0 ? used : 0;
  }

  List<int> _savedSessionValues() {
    final values = List<int>.filled(14, 0);
    for (var i = 0; i < _savedCounters.length; i++) {
      values[i] = _savedCounters[i].all;
      values[7 + i] = _savedCounters[i].mobile;
    }
    return values;
  }

  /// This session's counters, indexed by [DataSource] then mobile.
  List<int> _sessionValues() {
    final values = List<int>.filled(14, 0);
    values[DataSource.chat.index] = ircReadBytes;
    values[DataSource.sent.index] = ircWriteBytes;
    values[DataSource.history.index] = historyBytes;
    values[DataSource.twitchApi.index] = helixBytes;
    values[DataSource.events.index] = eventBytes;
    values[DataSource.emoteLists.index] = jsonBytes;
    values[DataSource.emoteImages.index] = emoteDownloadBytes;
    for (var i = 0; i < _mobileBytes.length; i++) {
      values[7 + i] = _mobileBytes[i];
    }
    return values;
  }

  /// Bytes since install, including the session not flushed yet.
  List<int> _currentValues() {
    final session = _sessionValues();
    return [
      for (var i = 0; i < _base.length; i++)
        _base[i] + session[i] - _flushed[i],
    ];
  }

  /// [snapshots]' cumulative totals just before [at], or zeros when the app
  /// has no snapshot that old (all recorded usage is inside the window).
  static List<int> _totalBefore(List<List<int>> snapshots, DateTime at) {
    final cut = at.millisecondsSinceEpoch;
    List<int>? best;
    for (final entry in snapshots) {
      if (entry[0] <= cut && (best == null || entry[0] > best[0])) best = entry;
    }
    return best == null ? List<int>.filled(14, 0) : best.sublist(1);
  }

  /// Loads the totals saved by [flush]. Later calls are no-ops.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await Prefs.load()).rawGetString(_key);
      if (raw == null) return;
      final data = jsonDecode(raw) as Map<String, Object?>;
      _base = _ints(data['total']);
      _hours = _snapshots(data['hours']);
      _days = _snapshots(data['days']);
      _savedBase = _ints(data['saved']);
      _savedHours = _snapshots(data['savedHours']);
      _savedDays = _snapshots(data['savedDays']);
      // Legacy blobs stored the saved counters as name -> [all, mobile].
      final legacy = data['saved'];
      if (legacy is Map) {
        for (var i = 0; i < _savedNames.length; i++) {
          final pair = legacy[_savedNames[i]];
          if (pair is List && pair.length >= 2) {
            _savedBase[i] = pair[0] is int ? pair[0] as int : 0;
            _savedBase[7 + i] = pair[1] is int ? pair[1] as int : 0;
          }
        }
        _savedHours = [];
        _savedDays = [];
      }
    } catch (_) {
      // A bad blob starts the totals over.
    }
  }

  /// Folds this session into the saved totals and writes them back.
  Future<void> flush() async {
    final session = _sessionValues();
    var added = false;
    for (var i = 0; i < _base.length; i++) {
      final delta = session[i] - _flushed[i];
      if (delta == 0) continue;
      _base[i] += delta;
      _flushed[i] = session[i];
      added = true;
    }
    final saved = _savedSessionValues();
    for (var i = 0; i < _savedBase.length; i++) {
      final delta = saved[i] - _savedFlushed[i];
      if (delta == 0) continue;
      _savedBase[i] += delta;
      _savedFlushed[i] = saved[i];
      added = true;
    }
    if (added) _snapshot();
    final prefs = await Prefs.load();
    await prefs.setRawString(_key, jsonEncode(toJson()));
  }

  /// Records the running total at the start of this hour and day, keeping an
  /// anchor just before each window so it can be subtracted.
  void _snapshot() {
    final at = now();
    final hour = DateTime(at.year, at.month, at.day, at.hour);
    final day = DateTime(at.year, at.month, at.day);
    _append(_hours, hour, const Duration(hours: 26), 72, _base);
    _append(_savedHours, hour, const Duration(hours: 26), 72, _savedBase);
    _append(_days, day, const Duration(days: 31), 48, _base);
    _append(_savedDays, day, const Duration(days: 31), 48, _savedBase);
  }

  void _append(
    List<List<int>> snapshots,
    DateTime bucket,
    Duration keep,
    int max,
    List<int> values,
  ) {
    final ts = bucket.millisecondsSinceEpoch;
    if (snapshots.isEmpty || snapshots.last[0] != ts) {
      snapshots.add([ts, ...values]);
    }
    final cutoff = now().subtract(keep).millisecondsSinceEpoch;
    // Keep the newest entry older than the cutoff: windows subtract it.
    List<int>? anchor;
    for (final entry in snapshots) {
      if (entry[0] <= cutoff) anchor = entry;
    }
    snapshots.removeWhere(
      (entry) => entry[0] < cutoff && !identical(entry, anchor),
    );
    if (snapshots.length > max) {
      snapshots.removeRange(0, snapshots.length - max);
    }
  }

  Map<String, Object?> toJson() => {
    'total': _base,
    'hours': _hours,
    'days': _days,
    'saved': _savedBase,
    'savedHours': _savedHours,
    'savedDays': _savedDays,
  };

  static List<int> _ints(Object? value) {
    final out = List<int>.filled(14, 0);
    if (value is List) {
      for (var i = 0; i < 14 && i < value.length; i++) {
        if (value[i] case final int v) out[i] = v;
      }
    }
    return out;
  }

  /// Entries are `[timestampMs, ...14]`, padded so a partial blob is safe.
  static List<List<int>> _snapshots(Object? value) {
    if (value is! List) return [];
    return [
      for (final entry in value)
        if (entry is List) _snapshotEntry(entry),
    ];
  }

  static List<int> _snapshotEntry(List<Object?> entry) {
    final out = List<int>.filled(15, 0);
    for (var i = 0; i < 15 && i < entry.length; i++) {
      if (entry[i] case final int v) out[i] = v;
    }
    return out;
  }

  /// Clears every total, as a fresh install would.
  @visibleForTesting
  void reset() {
    ircReadBytes = 0;
    ircWriteBytes = 0;
    emoteDownloadBytes = 0;
    jsonBytes = 0;
    historyBytes = 0;
    helixBytes = 0;
    eventBytes = 0;
    _mobileBytes.fillRange(0, _mobileBytes.length, 0);
    _base = List<int>.filled(14, 0);
    _flushed.fillRange(0, _flushed.length, 0);
    _hours = [];
    _days = [];
    _savedBase = List<int>.filled(14, 0);
    _savedFlushed.fillRange(0, _savedFlushed.length, 0);
    _savedHours = [];
    _savedDays = [];
    for (final count in _savedCounters) {
      count
        ..all = 0
        ..mobile = 0;
    }
    _loaded = false;
  }
}
