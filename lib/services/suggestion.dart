import 'package:flutter/material.dart';
import '../models/generic_emote.dart';
import '../models/twitch_command.dart';

class CurrentWord {
  final int start;
  final int end;
  final String text;
  const CurrentWord({
    required this.start,
    required this.end,
    required this.text,
  });
}

CurrentWord getCurrentWord(String text, int cursorOffset) {
  final safeOffset = cursorOffset.clamp(0, text.length);
  int start = safeOffset;
  while (start > 0 && text[start - 1] != ' ') {
    start--;
  }
  int end = safeOffset;
  while (end < text.length && text[end] != ' ') {
    end++;
  }
  return CurrentWord(start: start, end: end, text: text.substring(start, end));
}

void replaceCurrentWord(TextEditingController controller, String replacement) {
  final text = controller.text;
  final cursor = controller.selection.baseOffset.clamp(0, text.length);
  final word = getCurrentWord(text, cursor);
  final trailingSpace = word.end < text.length && text[word.end] == ' '
      ? ''
      : ' ';
  final newText =
      '${text.substring(0, word.start)}$replacement$trailingSpace${text.substring(word.end)}';
  controller.text = newText;
  final newCursor = word.start + replacement.length + trailingSpace.length;
  controller.selection = TextSelection.collapsed(
    offset: newCursor.clamp(0, newText.length),
  );
}

sealed class Suggestion {
  String get displayText;
}

class UserSuggestion implements Suggestion {
  final String displayName;
  @override
  String get displayText => displayName;
  const UserSuggestion({required this.displayName});
}

class EmoteSuggestion implements Suggestion {
  final GenericEmote emote;
  @override
  String get displayText => emote.code;
  const EmoteSuggestion({required this.emote});
}

class CommandSuggestion implements Suggestion {
  final String command;
  @override
  String get displayText => command;
  const CommandSuggestion({required this.command});
}

List<Suggestion> filterSuggestions({
  required String word,
  required List<GenericEmote> emotes,
  required Iterable<String> users,
  List<TwitchCommand> commands = const [],
  bool preferEmotesFirst = false,
  Set<String> recentEmoteIds = const {},
}) {
  if (word.isEmpty) return const [];

  // Slash words only match commands; users and emote codes cannot contain
  // slashes. Typing "/" alone surfaces the whole (unfiltered) list.
  if (word.startsWith('/')) {
    final results = <Suggestion>[];
    final lower = word.toLowerCase();
    for (final cmd in commands) {
      if (cmd.name.toLowerCase().startsWith(lower)) {
        results.add(CommandSuggestion(command: cmd.name));
      }
    }
    return results;
  }

  // Score-based ranking (ported from dankchat's SuggestionProvider, itself
  // Chatterino's SmartEmoteStrategy): shorter, case-exact, recently used
  // matches rank first. Users carry a small penalty so emotes win near-ties.
  // preferEmotesFirst keeps the classic type split: every emote before any
  // user.
  final emoteScored = <(Suggestion, int)>[];
  final matchedIds = <String>{};
  for (final emote in emotes) {
    final score = _scoreEmote(
      emote.code,
      word,
      recentEmoteIds.contains(emote.id),
    );
    if (score == _noMatch) continue;
    if (matchedIds.add(emote.id)) {
      emoteScored.add((EmoteSuggestion(emote: emote), score));
    }
  }
  final userScored = <(Suggestion, int)>[];
  for (final user in users) {
    final score = _scoreEmote(user, word, false);
    if (score == _noMatch) continue;
    userScored.add((
      UserSuggestion(displayName: user),
      score + _userScorePenalty,
    ));
  }

  emoteScored.sort(_byScore);
  userScored.sort(_byScore);

  if (preferEmotesFirst) {
    return [
      ...emoteScored,
      ...userScored,
    ].take(_maxSuggestions).map((e) => e.$1).toList();
  }

  // Merge the two pre-sorted lists by score; emotes win exact ties.
  final merged = <Suggestion>[];
  var i = 0;
  var j = 0;
  while (merged.length < _maxSuggestions &&
      (i < emoteScored.length || j < userScored.length)) {
    final pick = i >= emoteScored.length
        ? userScored[j++]
        : j >= userScored.length
        ? emoteScored[i++]
        : emoteScored[i].$2 <= userScored[j].$2
        ? emoteScored[i++]
        : userScored[j++];
    merged.add(pick.$1);
  }
  return merged;
}

int _byScore((Suggestion, int) a, (Suggestion, int) b) {
  final byScore = a.$2.compareTo(b.$2);
  if (byScore != 0) return byScore;
  return a.$1.displayText.compareTo(b.$1.displayText);
}

const _noMatch = -1 << 62;
const _userScorePenalty = 25;
const _maxSuggestions = 100;

// How costly it is to turn the query into the code: match anywhere
// (case-insensitive), then charge for case differences and extra characters.
// An exact-case match gets a flat -10; recently used emotes get a -50 boost.
// Lower is better. Ported from dankchat's SuggestionProvider, which credits
// Chatterino2's SmartEmoteStrategy by Mm2PL (chatterino2#4987).
int _scoreEmote(String code, String query, bool isRecentlyUsed) {
  final matchIndex = code.toLowerCase().indexOf(query.toLowerCase());
  if (matchIndex < 0) return _noMatch;

  var caseDiffs = 0;
  for (var i = 0; i < query.length; i++) {
    if (code[matchIndex + i] != query[i]) caseDiffs++;
  }

  final extraChars = code.length - query.length;
  final caseCost = caseDiffs == 0 ? -10 : caseDiffs;
  final usageBoost = isRecentlyUsed ? -50 : 0;
  return caseCost + extraChars * 100 + usageBoost;
}
