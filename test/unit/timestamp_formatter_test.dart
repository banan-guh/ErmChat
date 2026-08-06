import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/util/timestamp_formatter.dart';

void main() {
  // Fixed local time: 2026-08-06 03:05:09 in the host's local time zone.
  final midnight = DateTime(2026, 8, 6, 0, 5, 9);
  final noon = DateTime(2026, 8, 6, 12, 5, 9);
  final pm = DateTime(2026, 8, 6, 15, 5, 9);

  group('formatTimestamp', () {
    test('24-hour formats', () {
      expect(formatTimestamp(pm, 'H:mm'), '15:05');
      expect(formatTimestamp(pm, 'HH:mm'), '15:05');
      expect(formatTimestamp(midnight, 'H:mm'), '0:05');
      expect(formatTimestamp(midnight, 'HH:mm'), '00:05');
      expect(formatTimestamp(pm, 'H:mm:ss'), '15:05:09');
      expect(formatTimestamp(pm, 'HH:mm:ss'), '15:05:09');
    });

    test('12-hour formats with AM/PM', () {
      expect(formatTimestamp(pm, 'h:mm a'), '3:05 PM');
      expect(formatTimestamp(pm, 'hh:mm a'), '03:05 PM');
      expect(formatTimestamp(midnight, 'h:mm a'), '12:05 AM');
      expect(formatTimestamp(midnight, 'hh:mm a'), '12:05 AM');
      expect(formatTimestamp(noon, 'h:mm:ss a'), '12:05:09 PM');
      expect(formatTimestamp(noon, 'hh:mm:ss a'), '12:05:09 PM');
      expect(formatTimestamp(pm, 'h:mm:ss a'), '3:05:09 PM');
      expect(formatTimestamp(pm, 'hh:mm:ss a'), '03:05:09 PM');
    });

    test('default format is HH:mm', () {
      expect(kDefaultTimestampFormat, 'HH:mm');
      expect(
        formatTimestamp(DateTime(2026, 8, 6, 9, 7, 0), kDefaultTimestampFormat),
        '09:07',
      );
    });

    test('drops milliseconds regardless of input precision', () {
      final withMillis = DateTime(2026, 8, 6, 15, 5, 9, 123, 456);
      expect(formatTimestamp(withMillis, 'HH:mm:ss'), '15:05:09');
    });
  });

  test('presets cover 24h and 12h with and without seconds', () {
    expect(kTimestampFormats, containsAll(['HH:mm', 'hh:mm a', 'HH:mm:ss']));
    expect(kTimestampFormats.length, 8);
  });
}
