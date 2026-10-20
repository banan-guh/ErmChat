import 'dart:math';

import 'package:ermchat/services/gap_fill.dart';
import 'package:flutter_test/flutter_test.dart';

/// What one strategy did across the simulated reconnects.
class _Tally {
  int filled = 0, rows = 0, fetches = 0, short = 0;
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

  test('the gap is fetched only within the margin', () {
    // (fetched, expected missing, fetch?)
    final cases = [(100, 300.0, true), (100, 500.0, true), (100, 700.0, false)];
    for (final (fetched, missing, fetch) in cases) {
      expect(
        shouldFetchGap(fetched, missing),
        fetch,
        reason: '$missing missing',
      );
    }
  });

  test('dynamic fetch against manual counts over simulated gaps', () {
    // Reconnects over channel sizes, gap lengths and live states, with chat
    // rates swinging up to twofold from what the archive and the newest page
    // suggest. A manual count always loads that many and fills a gap it
    // covers. Dynamic loads [page], then the whole gap when it judges robotty
    // holds it all; a gap fetch robotty cannot hold comes back short.
    const page = 100;
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

    const strategies = ['manual 100', 'manual 800', 'dynamic'];
    final tallies = {for (final m in strategies) m: _Tally()};
    var total = 0, fillable = 0;
    for (final (_, usual, live) in profiles) {
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
            for (final (name, count) in [
              ('manual 100', 100),
              ('manual 800', 800),
            ]) {
              final t = tallies[name]!..rows += count;
              if (missing <= count) t.filled++;
            }
            final dynamic = tallies['dynamic']!..rows += page;
            if (missing <= page) {
              dynamic.filled++;
              continue;
            }
            // Where the newest page starts.
            final liveRows = liveStart == null
                ? 0.0
                : rows(max(0, liveStart), gap.toDouble());
            final oldest = liveStart == null
                ? gap - page / off
                : liveRows >= page
                ? gap - page / on
                : max(0, liveStart) - (page - liveRows) / off;
            final measured =
                page / (gap - oldest) * pow(2, rng.nextDouble() - 0.5);
            final expected = expectedGapMessages(
              lastSeen: base,
              oldestFetched: at(oldest),
              recentRate: measured,
              // A channel new to the archive has no usual rate yet.
              archiveRate: rng.nextDouble() < 0.2 ? null : usual * swing(),
              liveSince: liveStart == null ? null : at(liveStart),
            );
            if (shouldFetchGap(page, expected)) {
              dynamic.fetches++;
              dynamic.rows += min(missing, robottyBuffer);
              missing <= robottyBuffer ? dynamic.filled++ : dynamic.short++;
            }
          }
        }
      }
    }

    String pct(int n, int of) =>
        '${(100 * n / max(1, of)).toStringAsFixed(1)}%'.padLeft(6);
    // ignore: avoid_print
    print(
      [
        '$total reconnects, ${pct(fillable, total).trim()} fit robotty',
        for (final m in strategies)
          '${m.padRight(11)} filled ${pct(tallies[m]!.filled, total)}'
              '  ${(tallies[m]!.rows * 440 / 1024 / total).toStringAsFixed(1).padLeft(5)} KB/reconnect'
              '${tallies[m]!.fetches == 0 ? '' : '  gap fetches ${tallies[m]!.fetches}, short ${pct(tallies[m]!.short, tallies[m]!.fetches).trim()}'}',
      ].join('\n'),
    );

    final small = tallies['manual 100']!;
    final big = tallies['manual 800']!;
    final dynamic = tallies['dynamic']!;
    expect(dynamic.filled, greaterThan(small.filled));
    expect(
      dynamic.filled,
      greaterThan(big.filled * 0.85),
      reason: 'dynamic fills most of what loading 800 every time would',
    );
    expect(dynamic.rows, lessThan(big.rows / 3), reason: 'at a fraction of it');
    expect(
      dynamic.short / dynamic.fetches,
      lessThan(0.05),
      reason: 'gap fetches rarely come back short',
    );
  });
}
