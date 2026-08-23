import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/twitch_message.dart';

/// One local ignore entry. With [replacement] null it deletes every message
/// from a matching login outright (user ignores); with a replacement it
/// rewrites matched keyword occurrences in message text instead. A keyword
/// entry with [block] drops the whole message rather than rewriting it.
class IgnoreEntry {
  final String id;
  final String pattern;
  final bool isRegex;
  final bool caseSensitive;

  /// Literal patterns must match on word boundaries. Regexes ignore this
  /// flag (hand-written lookarounds cover that case).
  final bool wordBoundary;
  final bool block;
  final String? replacement;

  const IgnoreEntry({
    required this.id,
    required this.pattern,
    this.isRegex = false,
    this.caseSensitive = false,
    this.wordBoundary = false,
    this.block = false,
    this.replacement,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'pattern': pattern,
    'isRegex': isRegex,
    'caseSensitive': caseSensitive,
    'wordBoundary': wordBoundary,
    'block': block,
    if (replacement != null) 'replacement': replacement,
  };

  factory IgnoreEntry.fromJson(Map<String, dynamic> json) => IgnoreEntry(
    id: json['id'] as String? ?? '',
    pattern: json['pattern'] as String? ?? '',
    isRegex: json['isRegex'] == true,
    caseSensitive: json['caseSensitive'] == true,
    wordBoundary: json['wordBoundary'] == true,
    block: json['block'] == true,
    replacement: json['replacement'] as String?,
  );
}

List<IgnoreEntry> decodeEntries(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return [
      for (final e in decoded)
        if (e is Map) IgnoreEntry.fromJson(Map<String, dynamic>.from(e)),
    ];
  } catch (_) {
    return [];
  }
}

/// A replaced region expressed in the ORIGINAL text's coordinates.
class TextEdit {
  final int start;
  final int end;
  final int replacementLength;
  const TextEdit(this.start, this.end, this.replacementLength);

  int get delta => replacementLength - (end - start);
}

class RewriteResult {
  final String text;

  /// Edits sorted ascending by [TextEdit.start], original coordinates.
  final List<TextEdit> edits;
  const RewriteResult(this.text, this.edits);

  bool get changed => edits.isNotEmpty;
}

/// Local ignores, separate from server-side Twitch blocks: user ignores
/// delete messages outright, keyword rules rewrite them in place (dankchat
/// style, default replacement "***").
class IgnoreManager extends ChangeNotifier {
  static const _usersKey = 'local_ignores_v1';
  static const _keywordsKey = 'keyword_replacements_v1';

  /// Shared app-wide instance so settings screens edit the lists the live
  /// pipeline consults; tests construct fresh instances.
  static final IgnoreManager instance = IgnoreManager();

  List<IgnoreEntry> _users = [];
  List<IgnoreEntry> _keywords = [];
  bool _loaded = false;
  final Map<String, RegExp?> _regexCache = {};

  bool get loaded => _loaded;
  List<IgnoreEntry> get users => List.unmodifiable(_users);
  List<IgnoreEntry> get keywords => List.unmodifiable(_keywords);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _users = decodeEntries(prefs.getString(_usersKey) ?? '');
    _keywords = decodeEntries(prefs.getString(_keywordsKey) ?? '');
    _regexCache.clear();
    _loaded = true;
    notifyListeners();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _usersKey,
      jsonEncode([for (final u in _users) u.toJson()]),
    );
    await prefs.setString(
      _keywordsKey,
      jsonEncode([for (final k in _keywords) k.toJson()]),
    );
    _regexCache.clear();
    notifyListeners();
  }

  void upsertUser(IgnoreEntry entry) {
    _upsert(_users, entry);
    notifyListeners();
  }

  void removeUser(String id) {
    _users.removeWhere((e) => e.id == id);
    notifyListeners();
  }

  void upsertKeyword(IgnoreEntry entry) {
    _upsert(_keywords, entry);
    notifyListeners();
  }

  void removeKeyword(String id) {
    _keywords.removeWhere((e) => e.id == id);
    notifyListeners();
  }

  void _upsert(List<IgnoreEntry> list, IgnoreEntry entry) {
    final i = list.indexWhere((e) => e.id == entry.id);
    if (i >= 0) {
      list[i] = entry;
    } else {
      list.add(entry);
    }
  }

  RegExp? _regexFor(IgnoreEntry entry) {
    final key =
        '${entry.id}\u0000${entry.pattern}\u0000${entry.caseSensitive}'
        '\u0000${entry.wordBoundary}';
    return _regexCache.putIfAbsent(key, () {
      try {
        // Whole-word literals anchor via lookaround (not \b) so patterns
        // starting or ending with non-word characters still bind correctly.
        if (!entry.isRegex && entry.wordBoundary) {
          return RegExp(
            '(?<!\\w)${RegExp.escape(entry.pattern)}(?!\\w)',
            caseSensitive: entry.caseSensitive,
          );
        }
        return RegExp(entry.pattern, caseSensitive: entry.caseSensitive);
      } on FormatException {
        return null;
      }
    });
  }

  bool matchesPattern(IgnoreEntry entry, String value) {
    if (entry.pattern.isEmpty) return false;
    if (entry.isRegex || entry.wordBoundary) {
      final re = _regexFor(entry);
      if (re != null) return re.hasMatch(value);
      // Invalid regex falls back to a literal comparison.
    }
    return entry.caseSensitive
        ? value.contains(entry.pattern)
        : value.toLowerCase().contains(entry.pattern.toLowerCase());
  }

  bool isIgnored(String login) =>
      _users.any((e) => e.pattern.isNotEmpty && matchesPattern(e, login));

  /// True when any block-mode keyword rule matches [text]: the whole message
  /// is dropped at ingestion instead of rewritten.
  bool isBlockedPhrase(String text) =>
      _keywords.any((e) => e.block && matchesPattern(e, text));

  /// Finds every non-overlapping keyword occurrence in [text]. Earliest
  /// start wins; at equal starts the longest match replaces.
  RewriteResult applyKeywordReplacements(String text) {
    if (!_loaded || text.isEmpty) return RewriteResult(text, const []);
    final candidates = <(int, int, String)>[];
    for (final rule in _keywords) {
      if (rule.pattern.isEmpty || rule.block) continue;
      if (rule.isRegex || rule.wordBoundary) {
        final re = _regexFor(rule);
        if (re != null) {
          for (final m in re.allMatches(text)) {
            candidates.add((m.start, m.end, rule.replacement ?? '***'));
          }
          continue;
        }
        // Invalid regex falls back to literal matching below.
      }
      final haystack = rule.caseSensitive ? text : text.toLowerCase();
      final needle = rule.caseSensitive
          ? rule.pattern
          : rule.pattern.toLowerCase();
      var from = 0;
      while (true) {
        final i = haystack.indexOf(needle, from);
        if (i < 0) break;
        candidates.add((i, i + needle.length, rule.replacement ?? '***'));
        from = i + needle.length;
      }
    }
    candidates.sort((a, b) {
      final byStart = a.$1.compareTo(b.$1);
      if (byStart != 0) return byStart;
      // Longest first, then insertion order is irrelevant for determinism.
      return (b.$2 - b.$1).compareTo(a.$2 - a.$1);
    });
    final chosen = <(int, int, String)>[];
    var lastEnd = -1;
    for (final c in candidates) {
      if (c.$1 < lastEnd) continue;
      chosen.add(c);
      lastEnd = c.$2;
    }

    final buffer = StringBuffer();
    final edits = <TextEdit>[];
    var cursor = 0;
    for (final (start, end, replacement) in chosen) {
      buffer.write(text.substring(cursor, start));
      buffer.write(replacement);
      edits.add(TextEdit(start, end, replacement.length));
      cursor = end;
    }
    buffer.write(text.substring(cursor));
    return RewriteResult(buffer.toString(), edits);
  }
}

/// Rewrites a message's text with keyword replacements and realigns its
/// emote positions, which arrive in IRC tags keyed to the original text.
/// Emotes overlapping a replaced span are dropped (their coordinates no
/// longer mean anything).
void rewriteMessageKeywords(TwitchMessage msg, IgnoreManager manager) {
  final result = manager.applyKeywordReplacements(msg.text);
  if (!result.changed) return;
  msg.text = result.text;
  final positions = msg.emotePositions;
  if (positions == null || positions.isEmpty) return;
  final kept = <EmotePosition>[];
  for (final p in positions) {
    var delta = 0;
    var overlaps = false;
    for (final edit in result.edits) {
      if (edit.end <= p.startIndex) {
        delta += edit.delta;
      } else if (edit.start >= p.endIndex) {
        break;
      } else {
        overlaps = true;
        break;
      }
    }
    if (overlaps) continue;
    kept.add(
      EmotePosition(
        emoteId: p.emoteId,
        startIndex: p.startIndex + delta,
        endIndex: p.endIndex + delta,
        emoteCode: p.emoteCode,
      ),
    );
  }
  positions
    ..clear()
    ..addAll(kept);
}
