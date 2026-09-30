import 'package:ermchat/util/date_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 3, 10, 12);

  test('formatAgo steps from seconds to dates', () {
    expect(
      formatAgo(now.subtract(const Duration(seconds: 20)), now: now),
      'just now',
    );
    expect(
      formatAgo(now.subtract(const Duration(minutes: 5)), now: now),
      '5m ago',
    );
    expect(
      formatAgo(now.subtract(const Duration(hours: 3)), now: now),
      '3h ago',
    );
    expect(
      formatAgo(now.subtract(const Duration(days: 2)), now: now),
      '2d ago',
    );
    expect(formatAgo(DateTime(2025, 12, 1), now: now), '2025-12-01');
    expect(formatAgoIso('not a date'), 'not a date');
  });

  test('formatIn looks ahead', () {
    expect(formatIn(now.add(const Duration(seconds: 45)), now: now), 'in 45s');
    expect(formatIn(now.add(const Duration(minutes: 5)), now: now), 'in 5m');
    expect(formatIn(now.add(const Duration(hours: 2)), now: now), 'in 2h');
    expect(
      formatIn(now.subtract(const Duration(minutes: 1)), now: now),
      'in 0s',
    );
    expect(formatIn(DateTime(2026, 3, 12, 9, 5), now: now), '2026-03-12 09:05');
  });
}
