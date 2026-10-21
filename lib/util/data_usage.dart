import 'dart:async';

import '../models/emote_fetch_tier.dart';
import 'log.dart';

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

/// A count since the app started, and the part taken on mobile data.
class SessionCount {
  int all = 0;
  int mobile = 0;

  int of({required bool mobileOnly}) => mobileOnly ? mobile : all;
}

/// Lightweight numeric data-usage aggregator for the mobile data-saver work.
///
/// Counts bytes by source (IRC sockets, emote image downloads, provider JSON)
/// plus cache churn (evictions), so we can see where bandwidth goes. A 10-minute
/// timer synthesizes one summary line into [AppLog] (visible in Dev settings >
/// App log). The counters are plain ints mutated only on the UI isolate,
/// so no locking is needed.
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
  int evictions = 0;

  // What the data savers served without a download, against what they
  // fetched, for the Saved rows.
  final imagesFromDisk = SessionCount();
  final imageBytesFromDisk = SessionCount();
  final imagesDownloaded = SessionCount();
  final listsFromDisk = SessionCount();
  final listsFetched = SessionCount();
  final gapFetches = SessionCount();
  final gapsFilled = SessionCount();

  EmoteFetchTier? appliedTier;
  bool mobile = false;

  Timer? _emitTimer;

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
  final jsonByEndpoint = <String, int>{};

  void recordJson(int bytes, Uri uri) {
    jsonBytes += bytes;
    _countMobile(DataSource.emoteLists, bytes);
    final path = [
      for (final s in uri.pathSegments)
        s.length >= 12 || int.tryParse(s) != null ? '*' : s,
    ].join('/');
    final key = '${uri.host}/$path';
    jsonByEndpoint[key] = (jsonByEndpoint[key] ?? 0) + bytes;
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

  /// Bytes for [source], or only those sent or received on mobile data.
  int bytesFor(DataSource source, {bool mobileOnly = false}) {
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

  int totalFor({bool mobileOnly = false}) => DataSource.values.fold(
    0,
    (sum, source) => sum + bytesFor(source, mobileOnly: mobileOnly),
  );

  /// Downloads of a URL this session already evicted: the cost of a cap or
  /// keep-priority that dropped the wrong file.
  int refetches = 0;

  // Bounded so a long session cannot grow it without limit.
  final _evicted = <String>{};
  static const _maxEvicted = 5000;

  void recordEviction(String url) {
    evictions++;
    _evicted.add(url);
    if (_evicted.length > _maxEvicted) _evicted.remove(_evicted.first);
  }

  /// An emote image download of [url] starting.
  void recordEmoteFetch(String url) {
    if (_evicted.remove(url)) refetches++;
  }

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

  void setContext({EmoteFetchTier? tier, bool? isMobile}) {
    if (tier != null) appliedTier = tier;
    if (isMobile != null) mobile = isMobile;
  }

  int get totalBytes => totalFor();

  /// Starts the 10-minute summary emitter. Idempotent; safe to call once at
  /// startup.
  void start() {
    _emitTimer?.cancel();
    _emitTimer = Timer.periodic(const Duration(minutes: 10), (_) => _emit());
  }

  void _emit() {
    AppLog.I.record(
      'DATA',
      '10min total=${totalBytes}B '
          'ircR=${ircReadBytes}B ircW=${ircWriteBytes}B '
          'emote=${emoteDownloadBytes}B json=${jsonBytes}B '
          'history=${historyBytes}B helix=${helixBytes}B event=${eventBytes}B '
          'evict=$evictions refetch=$refetches tier=${appliedTier?.label ?? '?'} mobile=$mobile '
          'jsonBy=$jsonByEndpoint',
    );
  }

  void dispose() {
    _emitTimer?.cancel();
    _emitTimer = null;
  }
}
