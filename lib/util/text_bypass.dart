const invisibleChar = '\u034F';
const _invisibleChar = invisibleChar;

/// Strips trailing invisible-char suffix and surrounding whitespace.
String stripInvisibleSuffix(String s) {
  var result = s.trimRight();
  if (result.endsWith(_invisibleChar)) {
    result = result.substring(0, result.length - 1).trimRight();
  }
  return result;
}

/// Dedup bypass: toggles a trailing invisible-char suffix when [text] equals [lastSent], so adjacent sends differ on the wire but look identical.
String bypassTextDuplicate(String text, String? lastSent) {
  final trimmed = text.trimRight();
  final last = lastSent ?? '';
  if (last == trimmed) {
    if (trimmed.endsWith(_invisibleChar)) {
      return trimmed.substring(0, trimmed.length - 1).trimRight();
    }
    return '$trimmed $_invisibleChar';
  }
  return trimmed;
}
