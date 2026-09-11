/// Formats [at] as an ISO-style date, `yyyy-MM-dd`.
String formatYmd(DateTime at) =>
    '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
