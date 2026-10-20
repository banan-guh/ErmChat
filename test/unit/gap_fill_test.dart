import 'package:ermchat/services/gap_fill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the expected gap splits at the stream start', () {
    final now = DateTime.utc(2026, 10, 19, 12);
    final lastSeen = now.subtract(const Duration(hours: 12));
    // (case, live since, expected messages): 4/s live, 0.01/s usual.
    final cases = [
      ('offline the whole gap', null, 0.01 * 12 * 3600),
      (
        'live for the last hour',
        now.subtract(const Duration(hours: 1)),
        4 * 3600 + 0.01 * 11 * 3600,
      ),
      (
        'live for the last two minutes',
        now.subtract(const Duration(minutes: 2)),
        4 * 120 + 0.01 * (12 * 3600 - 120),
      ),
      (
        'live since before the gap',
        lastSeen.subtract(const Duration(hours: 1)),
        4 * 12 * 3600,
      ),
    ];
    for (final (name, liveSince, expected) in cases) {
      expect(
        expectedGapMessages(
          lastSeen: lastSeen,
          oldestFetched: now,
          recentRate: 4,
          archiveRate: 0.01,
          liveSince: liveSince,
        ),
        closeTo(expected, 0.001),
        reason: name,
      );
    }
    expect(
      expectedGapMessages(
        lastSeen: lastSeen,
        oldestFetched: now,
        recentRate: 4,
      ),
      4 * 12 * 3600,
      reason: 'no archive rate falls back to the measured one',
    );
  });

  test('each level fetches the gap only within its margin', () {
    // (mode, fetched, expected missing, fetch?)
    final cases = [
      (GapFill.off, 100, 0.0, false),
      (GapFill.low, 100, 300.0, true),
      (GapFill.low, 100, 500.0, false),
      (GapFill.high, 100, 500.0, true),
      (GapFill.high, 100, 1300.0, true),
      (GapFill.high, 100, 1500.0, false),
    ];
    for (final (mode, fetched, missing, fetch) in cases) {
      expect(
        shouldFetchGap(mode, fetched, missing),
        fetch,
        reason: '$mode with $missing missing',
      );
    }
  });
}
