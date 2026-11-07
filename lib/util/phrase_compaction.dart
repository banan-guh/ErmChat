import 'dart:math' show min;

import '../models/twitch_message.dart' show EmotePosition;

final _word = RegExp(r'\S+');
final _nonAlnum = RegExp(r'[^\p{L}\p{N}]', unicode: true);

/// A condensed message: the text to show plus where each kept stretch of the
/// original landed, so emote positions can move onto it.
class PhraseCompaction {
  const PhraseCompaction(this.text, this.pieces);

  final String text;

  /// Kept stretches: offset in [text], offset in the input, and length.
  final List<({int at, int from, int length})> pieces;

  /// Moves [positions] onto [text], dropping the ones in removed stretches.
  List<EmotePosition> moveEmotes(Iterable<EmotePosition> positions) => [
    for (final position in positions)
      for (final piece in pieces)
        if (position.startIndex >= piece.from &&
            position.endIndex <= piece.from + piece.length)
          EmotePosition(
            emoteId: position.emoteId,
            startIndex: position.startIndex - piece.from + piece.at,
            endIndex: position.endIndex - piece.from + piece.at,
            emoteCode: position.emoteCode,
          ),
  ];
}

/// Collapses a phrase repeated at least three times inside [text]. Returns
/// null when there is no run worth hiding. The result is display only.
PhraseCompaction? compactRepeatedPhrase(String text) {
  final found = _find(text, const <int>{});
  if (found == null) return null;
  final best = found.best;
  final origAt = found.origAt;
  final norm = found.norm;

  // Keep the most common spelling of the repeated block, and remember which
  // copy it came from so its emote positions can travel with it.
  final variants = <String, ({int count, int start})>{};
  for (var i = 0; i < best.repeats; i++) {
    final start = best.blockStart + i * best.length;
    final from = origAt[start];
    final original = text.substring(from, origAt[start + best.length - 1] + 1);
    final prior = variants[original];
    variants[original] = (
      count: (prior?.count ?? 0) + 1,
      start: prior?.start ?? from,
    );
  }
  var block = variants.keys.first;
  for (final entry in variants.entries) {
    if (entry.value.count > variants[block]!.count) block = entry.key;
  }
  final chosen = variants[block]!;

  final base = norm.substring(best.blockStart, best.blockStart + best.length);
  var prefixEnd = origAt[best.blockStart];
  while (prefixEnd > 0 && text[prefixEnd - 1].trim().isEmpty) {
    prefixEnd--;
  }
  var suffixStart = best.end < norm.length ? origAt[best.end] : text.length;
  while (suffixStart < text.length && text[suffixStart].trim().isEmpty) {
    suffixStart++;
  }
  final prefixNorm = norm.substring(0, best.blockStart);
  final suffixNorm = norm.substring(best.end);
  if (prefixNorm.isNotEmpty &&
      prefixNorm.length < base.length &&
      base.endsWith(prefixNorm)) {
    prefixEnd = 0;
  }
  if (suffixNorm.isNotEmpty &&
      suffixNorm.length < base.length &&
      base.startsWith(suffixNorm)) {
    suffixStart = text.length;
  }

  final out = StringBuffer();
  final pieces = <({int at, int from, int length})>[];
  void add(int from, int to) {
    if (to <= from) return;
    if (out.isNotEmpty) out.write(' ');
    pieces.add((at: out.length, from: from, length: to - from));
    out.write(text.substring(from, to));
  }

  add(0, prefixEnd);
  add(chosen.start, chosen.start + block.length);
  if (out.isNotEmpty) out.write(' ');
  out.write('(x${best.repeats})');
  add(suffixStart, text.length);

  final display = out.toString();
  return display.length < text.length
      ? PhraseCompaction(display, pieces)
      : null;
}

/// Where the first full copy of a phrase repeated in [text] ends, ignoring
/// the characters in [emotes] while matching. Null when nothing repeats.
int? repeatedPhraseCut(String text, {required Set<int> emotes}) {
  final found = _find(text, emotes);
  if (found == null) return null;
  final second = found.best.blockStart + found.best.length;
  if (second >= found.origAt.length) return null;
  var end = found.origAt[second];
  while (end > 0 && text[end - 1].trim().isEmpty) {
    end--;
  }
  return end > 0 ? end : null;
}

/// The best run in [text], with the maps that turn its normalized offsets
/// back into the original. [skipped] characters take no part in matching.
({_Run best, List<int> origAt, String norm})? _find(
  String text,
  Set<int> skipped,
) {
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
      if (skipped.contains(j)) continue;
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
  return (best: best, origAt: origAt, norm: norm);
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
