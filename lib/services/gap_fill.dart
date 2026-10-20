import 'dart:math';

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
/// [expectedMissing] must fit robotty's buffer with a margin. Chat rates
/// swing about twofold, and the margin is tuned so few fetches come back
/// short.
bool shouldFetchGap(int fetched, double expectedMissing) =>
    fetched + expectedMissing <= robottyBuffer * 0.85;
