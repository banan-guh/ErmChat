import '../emotes/emote.dart';

/// Emote-fetch behavior tier.
enum EmoteFetchTier {
  /// Render only whatever is already cached; fetch nothing at all.
  nothing,

  /// Fetch rakes + subscriber emotes at 1x, cache forever.
  low,

  /// Fetch rakes + subscriber emotes at 2x, refresh every 24h.
  medium,

  /// 2x with on-demand 3x assets, refresh every 12h on wifi / 24h on cellular.
  high,
}

extension EmoteFetchTierX on EmoteFetchTier {
  String get label => switch (this) {
    EmoteFetchTier.nothing => 'Nothing',
    EmoteFetchTier.low => 'Low',
    EmoteFetchTier.medium => 'Medium',
    EmoteFetchTier.high => 'High',
  };

  String get subtitle => switch (this) {
    EmoteFetchTier.nothing => 'Show only already-cached emotes, never fetch',
    EmoteFetchTier.low =>
      'Small 1x emotes, fetched once then frozen (data saver)',
    EmoteFetchTier.medium => 'Medium 2x emotes, normal updates',
    EmoteFetchTier.high => 'Medium 2x emotes with large 4x card detail',
  };

  /// Scale the chat surface downloads when nothing better is cached, or null
  /// for nothing (no downloads at all).
  EmoteScale? get downloadScale => switch (this) {
    EmoteFetchTier.nothing => null,
    EmoteFetchTier.low => EmoteScale.small,
    EmoteFetchTier.medium || EmoteFetchTier.high => EmoteScale.medium,
  };

  /// Whether the detail card may fetch the large asset on demand.
  bool get allowsLargeDownload => this == EmoteFetchTier.high;
}

const bytesPerMb = 1024 * 1024;

/// Disk-cache cap in MB.
const defaultEmoteCacheMb = 50;
const minEmoteCacheMb = 0;
const maxEmoteCacheMb = 300;

/// Mean emote file size used when the cache is empty.
const fallbackEmoteAvgBytes = 40 * 1024;

/// Entry bound for a byte cap when no live stats exist.
int emoteEntriesForCap(int capBytes) => capBytes ~/ fallbackEmoteAvgBytes;

/// Rough emote count for [capBytes], extrapolated from live [stats].
int estimatedEmoteCount({
  required int capBytes,
  required int fileCount,
  required int totalBytes,
  int fallbackAvgBytes = fallbackEmoteAvgBytes,
}) {
  final avg = fileCount > 0 && totalBytes > 0
      ? totalBytes / fileCount
      : fallbackAvgBytes.toDouble();
  if (avg <= 0) return 0;
  return capBytes ~/ avg;
}

/// Default auto mode: pick tier by connectivity.
const defaultEmoteFetchAutoMode = EmoteFetchAutoMode.balanced;

/// Auto tier selection by connectivity. Off = manual; others pick by Wi-Fi vs cellular.
enum EmoteFetchAutoMode { off, balanced, aggressive }

extension EmoteFetchAutoModeX on EmoteFetchAutoMode {
  String get label => switch (this) {
    EmoteFetchAutoMode.off => 'Off',
    EmoteFetchAutoMode.balanced => 'Balanced',
    EmoteFetchAutoMode.aggressive => 'Aggressive',
  };

  String get subtitle => switch (this) {
    EmoteFetchAutoMode.off => 'Always use the selected tier',
    EmoteFetchAutoMode.balanced => 'High on Wi-Fi, Low on cellular',
    EmoteFetchAutoMode.aggressive => 'Medium on Wi-Fi, nothing on cellular',
  };
}

/// Effective tier: manual when auto is off, otherwise per isMobile (true = cellular).
EmoteFetchTier effectiveEmoteFetchTier({
  required EmoteFetchTier manual,
  required EmoteFetchAutoMode auto,
  required bool isMobile,
}) {
  if (auto == EmoteFetchAutoMode.off) return manual;
  return switch (auto) {
    EmoteFetchAutoMode.balanced =>
      isMobile ? EmoteFetchTier.low : EmoteFetchTier.high,
    EmoteFetchAutoMode.aggressive =>
      isMobile ? EmoteFetchTier.nothing : EmoteFetchTier.medium,
    EmoteFetchAutoMode.off => manual,
  };
}
