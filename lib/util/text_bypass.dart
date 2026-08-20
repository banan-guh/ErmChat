const _invisibleChar = '\u034F';

/// Mirrors DankChat's duplicate-message bypass. Twitch rejects two consecutive
/// identical messages, so when [text] equals the last wire text we sent
/// ([lastSent]), toggle a trailing invisible-char suffix on or off. Adjacent
/// sends then always differ on the wire while looking identical to the viewer,
/// and the suffix never accumulates into a pile of invisible characters.
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
