/// Timestamp format presets, mirroring DankChat's `timestamp_formats.xml`.
const List<String> kTimestampFormats = [
  'H:mm',
  'HH:mm',
  'h:mm a',
  'hh:mm a',
  'H:mm:ss',
  'HH:mm:ss',
  'h:mm:ss a',
  'hh:mm:ss a',
];

const String kDefaultTimestampFormat = 'HH:mm';
const String kShowTimestampsPrefKey = 'show_timestamps';
const String kTimestampFormatPrefKey = 'timestamp_format';

/// Formats [time] in local zone using a Java-style pattern (H, h, mm, ss, a).
String formatTimestamp(DateTime time, String format) {
  final local = time.toLocal();
  final h24 = local.hour;
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  final minute = local.minute;
  final second = local.second;
  final ampm = h24 < 12 ? 'AM' : 'PM';

  return format
      .replaceAll('HH', h24.toString().padLeft(2, '0'))
      .replaceAll('H', h24.toString())
      .replaceAll('hh', h12.toString().padLeft(2, '0'))
      .replaceAll('h', h12.toString())
      .replaceAll('mm', minute.toString().padLeft(2, '0'))
      .replaceAll('ss', second.toString().padLeft(2, '0'))
      .replaceAll('a', ampm);
}
