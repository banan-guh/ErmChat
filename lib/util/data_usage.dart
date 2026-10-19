import 'dart:async';

import '../models/emote_fetch_tier.dart';
import 'log.dart';

/// Lightweight numeric data-usage aggregator for the mobile data-saver work.
///
/// Counts bytes by source (IRC sockets, emote image downloads, provider JSON)
/// plus cache churn (evictions), so we can see where bandwidth goes. A 10-minute
/// timer synthesizes one summary line into [PerfLog] (visible in Dev settings >
/// Performance log). The counters are plain ints mutated only on the UI isolate,
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

  EmoteFetchTier? appliedTier;
  bool mobile = false;

  Timer? _emitTimer;

  void recordIrcRead(int bytes) => ircReadBytes += bytes;
  void recordIrcWrite(int bytes) => ircWriteBytes += bytes;
  void recordEmoteDownload(int bytes) => emoteDownloadBytes += bytes;
  void recordJson(int bytes) => jsonBytes += bytes;

  /// Recent-messages (robotty, zneix) response bodies.
  void recordHistory(int bytes) => historyBytes += bytes;

  /// Helix response bodies.
  void recordHelix(int bytes) => helixBytes += bytes;

  /// EventSub, PubSub and 7TV socket frames.
  void recordEvent(int bytes) => eventBytes += bytes;
  void recordEviction() => evictions++;

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

  int get totalBytes =>
      ircReadBytes +
      ircWriteBytes +
      emoteDownloadBytes +
      jsonBytes +
      historyBytes +
      helixBytes +
      eventBytes;

  /// Starts the 10-minute summary emitter. Idempotent; safe to call once at
  /// startup.
  void start() {
    _emitTimer?.cancel();
    _emitTimer = Timer.periodic(const Duration(minutes: 10), (_) => _emit());
  }

  void _emit() {
    PerfLog.I.record(
      'DATA',
      '10min total=${totalBytes}B '
          'ircR=${ircReadBytes}B ircW=${ircWriteBytes}B '
          'emote=${emoteDownloadBytes}B json=${jsonBytes}B '
          'history=${historyBytes}B helix=${helixBytes}B event=${eventBytes}B '
          'evict=$evictions tier=${appliedTier?.label ?? '?'} mobile=$mobile',
    );
  }

  void dispose() {
    _emitTimer?.cancel();
    _emitTimer = null;
  }
}
