String unescapeIrcTag(String raw) {
  return raw
      .replaceAll('\\s', ' ')
      .replaceAll('\\\\', '\\')
      .replaceAll('\\:', ';')
      .replaceAll('\\r', '\r')
      .replaceAll('\\n', '\n');
}

String? unescapeIrcTagNullable(String? raw) {
  if (raw == null) return null;
  return unescapeIrcTag(raw);
}
