import 'dart:math';

import 'package:ermchat/services/gap_fill.dart';
import 'package:flutter_test/flutter_test.dart';

/// What one level did across the simulated reconnects.
class _Tally {
  int filled = 0, fetches = 0, wasted = 0, skipped = 0, extraRows = 0;
}

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
      (GapFill.low, 100, 500.0, true),
      (GapFill.low, 100, 700.0, false),
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

  test('levels trade fills against wasted fetches over simulated gaps', () {
    // Reconnects over channel sizes, gap lengths and live states, with chat
    // rates swinging up to twofold from what the archive and the newest page
    // suggest. A gap fills when the newest page reaches it, or when the level
    // fetches and robotty's buffer holds it all. A fetch that cannot hold it
    // is wasted, and a gap that fit but was not fetched is skipped.
    const limit = 100;
    final rng = Random(7);
    double swing() => pow(2, rng.nextDouble() * 2 - 1).toDouble();
    // (profile, usual offline messages a second, live messages a second)
    const profiles = [
      ('tiny', 0.001, 0.2),
      ('small', 0.01, 1.0),
      ('mid', 0.05, 5.0),
      ('big', 0.3, 30.0),
    ];
    const gaps = [120, 600, 1800, 3600, 3 * 3600, 8 * 3600, 24 * 3600];
    final base = DateTime.utc(2026, 10, 19);
    DateTime at(double s) =>
        base.add(Duration(milliseconds: (s * 1000).round()));

    final tallies = {for (final m in GapFill.values) m: _Tally()};
    final byProfile = {
      for (final p in profiles)
        p.$1: {for (final m in GapFill.values) m: _Tally()},
    };
    var total = 0, fillable = 0, reached = 0;
    for (final (name, usual, live) in profiles) {
      for (final gap in gaps) {
        // 0 offline, 1 live the whole gap, 2 went live during it.
        for (final state in [0, 1, 2]) {
          for (var draw = 0; draw < 20; draw++) {
            final off = usual * swing();
            final on = live * swing();
            final liveStart = switch (state) {
              0 => null,
              1 => -3600.0,
              _ => gap * rng.nextDouble(),
            };
            double rows(double a, double b) {
              if (liveStart == null || liveStart >= b) return off * (b - a);
              final from = max(a, liveStart);
              return off * (from - a) + on * (b - from);
            }

            final missing = rows(0, gap.toDouble()).round();
            total++;
            if (missing <= robottyBuffer) fillable++;
            if (missing <= limit) {
              reached++;
              for (final m in GapFill.values) {
                tallies[m]!.filled++;
                byProfile[name]![m]!.filled++;
              }
              continue;
            }
            // Where the newest page of [limit] rows starts.
            final liveRows = liveStart == null
                ? 0.0
                : rows(max(0, liveStart), gap.toDouble());
            final oldest = liveStart == null
                ? gap - limit / off
                : liveRows >= limit
                ? gap - limit / on
                : max(0, liveStart) - (limit - liveRows) / off;
            final measured =
                limit / (gap - oldest) * pow(2, rng.nextDouble() - 0.5);
            final expected = expectedGapMessages(
              lastSeen: base,
              oldestFetched: at(oldest),
              recentRate: measured,
              // A channel new to the archive has no usual rate yet.
              archiveRate: rng.nextDouble() < 0.2 ? null : usual * swing(),
              liveSince: liveStart == null ? null : at(liveStart),
            );
            for (final m in GapFill.values) {
              for (final t in [tallies[m]!, byProfile[name]![m]!]) {
                if (shouldFetchGap(m, limit, expected)) {
                  t.fetches++;
                  t.extraRows += min(missing, robottyBuffer);
                  if (missing <= robottyBuffer) {
                    t.filled++;
                  } else {
                    t.wasted++;
                  }
                } else if (missing <= robottyBuffer) {
                  t.skipped++;
                }
              }
            }
          }
        }
      }
    }

    String pct(int n, int of) =>
        '${(100 * n / max(1, of)).toStringAsFixed(1)}%'.padLeft(6);
    String row(String label, _Tally t, int of) =>
        '${label.padRight(12)} filled ${pct(t.filled, of)}'
        '  fetches ${'${t.fetches}'.padLeft(4)}'
        '  wasted ${pct(t.wasted, t.fetches)}'
        '  skipped ${'${t.skipped}'.padLeft(4)}'
        '  extra ${(t.extraRows * 440 / 1024 / max(1, of)).toStringAsFixed(1)} KB/reconnect';
    // ignore: avoid_print
    print(
      [
        '$total reconnects, $fillable fit robotty '
            '(${pct(fillable, total).trim()}), '
            '$reached reached by the newest $limit',
        for (final m in GapFill.values) row(m.name, tallies[m]!, total),
        for (final p in profiles)
          for (final m in [GapFill.low, GapFill.high])
            row('${p.$1} ${m.name}', byProfile[p.$1]![m]!, total ~/ 4),
      ].join('\n'),
    );

    final off = tallies[GapFill.off]!;
    final low = tallies[GapFill.low]!;
    final high = tallies[GapFill.high]!;
    expect(off.filled, reached, reason: 'off fills only what the page reaches');
    expect(low.filled, greaterThan(off.filled));
    expect(high.filled, greaterThanOrEqualTo(low.filled));
    expect(
      low.wasted / low.fetches,
      lessThan(0.05),
      reason: 'low rarely fetches short',
    );
    expect(high.wasted, greaterThanOrEqualTo(low.wasted));
  });
}
