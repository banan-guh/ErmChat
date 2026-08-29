const _invisibleChar = '\u034F';

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
