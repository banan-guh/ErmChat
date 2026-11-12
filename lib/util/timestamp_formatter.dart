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

final _maxLengthCache = <String, int>{};

/// Longest output [format] can produce. Callers reserve a fixed-width
/// timestamp column from this so usernames line up across rows.
int timestampMaxLength(String format) {
  return _maxLengthCache.putIfAbsent(
    format,
    () => format
        .replaceAll('HH', '23')
        .replaceAll('H', '23')
        .replaceAll('hh', '12')
        .replaceAll('h', '12')
        .replaceAll('mm', '59')
        .replaceAll('ss', '59')
        .replaceAll('a', 'PM')
        .length,
  );
}

/// Formats [time] in local zone using a Java-style pattern (H, h, mm, ss, a).
String formatTimestamp(DateTime time, String format) {
  final local = time.toLocal();
  final h24 = local.hour;
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  final minute = local.minute;
  final second = local.second;
  // One left-to-right pass, longest token first, matching what the chained
  // replaceAll calls produced (a replacement never carries a token letter).
  final out = StringBuffer();
  var i = 0;
  while (i < format.length) {
    final c = format[i];
    final doubled = i + 1 < format.length && format[i + 1] == c;
    switch (c) {
      case 'H':
        out.write(doubled ? _pad(h24) : '$h24');
        i += doubled ? 2 : 1;
      case 'h':
        out.write(doubled ? _pad(h12) : '$h12');
        i += doubled ? 2 : 1;
      case 'm' when doubled:
        out.write(_pad(minute));
        i += 2;
      case 's' when doubled:
        out.write(_pad(second));
        i += 2;
      case 'a':
        out.write(h24 < 12 ? 'AM' : 'PM');
        i += 1;
      default:
        out.write(c);
        i += 1;
    }
  }
  return out.toString();
}

String _pad(int value) => value < 10 ? '0$value' : '$value';
