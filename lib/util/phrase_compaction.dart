import 'dart:math' show min;

final _word = RegExp(r'\S+');
final _nonAlnum = RegExp(r'[^\p{L}\p{N}]', unicode: true);

/// Collapses a phrase repeated at least three times inside [text]. Returns
/// null when there is no run worth hiding. The result is display only.
String? compactRepeatedPhrase(String text) {
  if (text.length < 60) return null;
  final tokens = [
    for (final match in _word.allMatches(text))
      _Token(match.start, match.end, match[0]!),
  ];
  final n = tokens.length;
  if (n < 9) return null;

  final joined = StringBuffer();
  final origAt = <int>[];
  final starts = List<int>.filled(n + 1, 0);
  for (var i = 0; i < n; i++) {
    for (var j = tokens[i].start; j < tokens[i].end; j++) {
      final normalized = text[j].toLowerCase().replaceAll(_nonAlnum, '');
      if (normalized.isEmpty) continue;
      joined.write(normalized);
      for (var k = 0; k < normalized.length; k++) {
        origAt.add(j);
      }
    }
    starts[i + 1] = joined.length;
  }
  final norm = joined.toString();
  if (norm.length < 36) return null;

  _Run? best;
  final maxStart = min(n - 3, 12);
  for (var s = 0; s <= maxStart; s++) {
    final blockStart = starts[s];
    for (var p = 3; s + p < n; p++) {
      final length = starts[s + p] - blockStart;
      if (length < 12) continue;
      if (blockStart + length * 3 > norm.length) break;
      if (_protected(tokens, s, s + p)) continue;
      final base = norm.substring(blockStart, blockStart + length);
      final budget = _budget(length);
      var repeats = 1;
      var next = blockStart + length;
      while (next + length <= norm.length &&
          _close(base, norm.substring(next, next + length), budget)) {
        repeats++;
        next += length;
      }
      if (repeats < 3) continue;
      final score = (repeats - 1) * length;
      if (best == null || score > best.score) {
        best = _Run(
          blockStart: blockStart,
          length: length,
          repeats: repeats,
          end: next,
          score: score,
        );
      }
    }
  }
  if (best == null) return null;

  final blockOrig = <String, int>{};
  for (var i = 0; i < best.repeats; i++) {
    final start = best.blockStart + i * best.length;
    final original = text.substring(
      origAt[start],
      origAt[start + best.length - 1] + 1,
    );
    blockOrig[original] = (blockOrig[original] ?? 0) + 1;
  }
  var block = blockOrig.keys.first;
  for (final entry in blockOrig.entries) {
    if (entry.value > blockOrig[block]!) block = entry.key;
  }

  final base = norm.substring(best.blockStart, best.blockStart + best.length);
  var prefix = text.substring(0, origAt[best.blockStart]).trimRight();
  var suffix = best.end < norm.length
      ? text.substring(origAt[best.end]).trimLeft()
      : '';
  final prefixNorm = norm.substring(0, best.blockStart);
  final suffixNorm = norm.substring(best.end);
  if (prefixNorm.isNotEmpty &&
      prefixNorm.length < base.length &&
      base.endsWith(prefixNorm)) {
    prefix = '';
  }
  if (suffixNorm.isNotEmpty &&
      suffixNorm.length < base.length &&
      base.startsWith(suffixNorm)) {
    suffix = '';
  }

  final out = [
    if (prefix.isNotEmpty) prefix,
    block.trim(),
    '(x${best.repeats})',
    if (suffix.isNotEmpty) suffix,
  ].join(' ');
  return out.length < text.length ? out : null;
}

class _Token {
  _Token(this.start, this.end, this.raw);

  final int start;
  final int end;
  final String raw;
}

class _Run {
  const _Run({
    required this.blockStart,
    required this.length,
    required this.repeats,
    required this.end,
    required this.score,
  });

  final int blockStart;
  final int length;
  final int repeats;
  final int end;
  final int score;
}

bool _protected(List<_Token> tokens, int start, int end) {
  for (var i = start; i < end; i++) {
    final token = tokens[i].raw.toLowerCase();
    if (token.startsWith('@') ||
        token.startsWith('#') ||
        token.startsWith('http') ||
        token.startsWith('www.') ||
        token.contains('/') ||
        token.contains('.')) {
      return true;
    }
  }
  return false;
}

int _budget(int length) {
  if (length < 20) return 0;
  if (length < 40) return 2;
  if (length < 80) return 3;
  return 4;
}

bool _close(String a, String b, int budget) {
  var differences = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] == b[i]) continue;
    if (++differences > budget) return false;
  }
  return true;
}
