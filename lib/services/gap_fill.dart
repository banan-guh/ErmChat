import 'dart:math';

/// How hard history tries to fill the gap since the last message seen.
/// Off loads only the newest messages. Low fetches the whole gap when it
/// likely fits robotty's buffer, High even on a long shot.
enum GapFill {
  off,
  low,
  high;

  static GapFill fromIndex(int i) => values[i.clamp(0, values.length - 1)];
}

/// Messages robotty keeps per channel.
const int robottyBuffer = 800;

/// Expected messages between [lastSeen] and [oldestFetched], the stretch the
/// newest-first fetch did not reach.
///
/// [recentRate] (messages a second) is measured from that fetch. A stream
/// live since [liveSince] runs at that rate; the rest of the gap runs at
/// [archiveRate], the channel's usual rate from the archive. Without a live
/// stream the whole gap uses [archiveRate]. A missing [archiveRate] falls
/// back to [recentRate], which overestimates and so fetches less.
double expectedGapMessages({
  required DateTime lastSeen,
  required DateTime oldestFetched,
  required double recentRate,
  double? archiveRate,
  DateTime? liveSince,
}) {
  double seconds(DateTime a, DateTime b) =>
      max(0, b.difference(a).inMilliseconds / 1000);
  final usual = archiveRate ?? recentRate;
  if (liveSince == null || !liveSince.isBefore(oldestFetched)) {
    return usual * seconds(lastSeen, oldestFetched);
  }
  final liveFrom = liveSince.isAfter(lastSeen) ? liveSince : lastSeen;
  return recentRate * seconds(liveFrom, oldestFetched) +
      usual * seconds(lastSeen, liveFrom);
}

/// Whether to fetch the whole gap: [fetched] newest messages plus
/// [expectedMissing] must fit robotty's buffer, judged with [mode]'s margin.
/// Chat rates swing about twofold, so Low wants a clear fit and High tries
/// up to well past the buffer.
bool shouldFetchGap(GapFill mode, int fetched, double expectedMissing) {
  final total = fetched + expectedMissing;
  return switch (mode) {
    GapFill.off => false,
    GapFill.low => total <= robottyBuffer * 0.55,
    GapFill.high => total <= robottyBuffer * 1.8,
  };
}
