// Chat text normalization, shared by rendering, copying, and sending.

/// Our duplicate-message bypass mark (also 7TV's): U+034F, invisible.
const invisibleChar = '\u034F';
const _invisibleChar = invisibleChar;

// Invisible marks: duplicate bypasses (ours/7TV U+034F, Chatterino U+E0000)
// and zero-width spaces. A CGJ after a space counts as a letter for line
// breaking, so left in it can wrap onto an empty line of its own. Never
// U+200D or U+FE0F, which build emoji.
const _invisible = '[\u034F\u200B\u2060\uFEFF\u180E\u{E0000}]';
// Blank lookalikes that read as a space: NBSP, typographic spaces, Hangul
// fillers. Braille blank (U+2800) stays: braille art relies on it.
const _blanks =
    '[\u00A0\u2000-\u200A\u202F\u205F\u3000\u3164\u115F\u1160\uFFA0]';

final _invisibleRe = RegExp(_invisible, unicode: true);
final _blanksRe = RegExp(_blanks, unicode: true);
final _spaceRunRe = RegExp(r' {2,}');

// Single code units [cleanChatText] rewrites or drops.
const _invisibleUnits = {0x180E, 0x200B, 0x2060, 0x034F, 0xFEFF};
const _blankUnits = {
  0x00A0,
  0x115F,
  0x1160,
  0x202F,
  0x205F,
  0x3000,
  0x3164,
  0xFFA0,
};

/// Whether [text] holds anything [cleanChatText] would rewrite. A code-unit
/// scan beats the unicode regex by an order of magnitude, and clean text is
/// the common case. Surrogates report true, so the regex still decides for
/// them (supplementary blanks live there) and clean emoji text survives.
bool _isClean(String text) {
  var prevSpace = false;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit == 0x20) {
      if (prevSpace) return false;
      prevSpace = true;
      continue;
    }
    prevSpace = false;
    if (unit < 0x7F) continue;
    if (_invisibleUnits.contains(unit) || _blankUnits.contains(unit)) {
      return false;
    }
    if (unit >= 0x2000 && unit <= 0x200A) return false;
    if (unit >= 0xD800 && unit <= 0xDFFF) return false;
  }
  return true;
}

/// Chat text as displayed: invisible marks dropped, blank lookalikes turned
/// into spaces, runs of spaces collapsed. Returns [text] itself when clean.
String cleanChatText(String text) {
  if (_isClean(text)) return text;
  return text
      .replaceAll(_invisibleRe, '')
      .replaceAll(_blanksRe, ' ')
      .replaceAll(_spaceRunRe, ' ');
}

/// What a copy puts on the clipboard: the displayed text, ends trimmed.
String copyableChatText(String text) => cleanChatText(text).trim();

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
