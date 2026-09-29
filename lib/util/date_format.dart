/// Formats [at] as an ISO-style date, `yyyy-MM-dd`.
String formatYmd(DateTime at) =>
    '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';

/// Formats [at] as `yyyy-MM-dd HH:mm`.
String formatYmdHm(DateTime at) =>
    '${formatYmd(at)} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

/// How long ago [at] was: `just now`, `5m ago`, `3h ago`, `2d ago`, or the
/// date past 30 days.
String formatAgo(DateTime at, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(at);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays < 30) return '${diff.inDays}d ago';
  return formatYmd(at);
}

/// [formatAgo] for an ISO timestamp; unparsable input comes back as is.
String formatAgoIso(String iso) {
  final at = DateTime.tryParse(iso);
  return at == null ? iso : formatAgo(at.toLocal());
}

/// How far ahead [at] is: `in 45s`, `in 5m`, `in 2h`, or the date and time
/// past a day.
String formatIn(DateTime at, {DateTime? now}) {
  final diff = at.difference(now ?? DateTime.now());
  if (diff.inMinutes < 1) return 'in ${diff.inSeconds.clamp(0, 59)}s';
  if (diff.inHours < 1) return 'in ${diff.inMinutes}m';
  if (diff.inDays < 1) return 'in ${diff.inHours}h';
  return formatYmdHm(at);
}
