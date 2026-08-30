import 'dart:async';

import '../models/emote_fetch_tier.dart';
import '../util/log.dart';

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
  int evictions = 0;

  EmoteFetchTier? appliedTier;
  bool mobile = false;

  Timer? _emitTimer;

  void recordIrcRead(int bytes) => ircReadBytes += bytes;
  void recordIrcWrite(int bytes) => ircWriteBytes += bytes;
  void recordEmoteDownload(int bytes) => emoteDownloadBytes += bytes;
  void recordJson(int bytes) => jsonBytes += bytes;
  void recordEviction() => evictions++;

  void setContext({EmoteFetchTier? tier, bool? isMobile}) {
    if (tier != null) appliedTier = tier;
    if (isMobile != null) mobile = isMobile;
  }

  int get totalBytes =>
      ircReadBytes + ircWriteBytes + emoteDownloadBytes + jsonBytes;

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
      'evict=$evictions tier=${appliedTier?.label ?? '?'} mobile=$mobile',
    );
  }

  void dispose() {
    _emitTimer?.cancel();
    _emitTimer = null;
  }
}
