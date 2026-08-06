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
}) {
  if (word.isEmpty) return const [];

  final lower = word.toLowerCase();

  // Slash words only match commands; users and emote codes cannot contain
  // slashes. Typing "/" alone surfaces the whole (unfiltered) list.
  if (word.startsWith('/')) {
    final results = <Suggestion>[];
    for (final cmd in commands) {
      if (cmd.name.toLowerCase().startsWith(lower)) {
        results.add(CommandSuggestion(command: cmd.name));
      }
    }
    return _numericFirst(results);
  }

  final userMatches = <Suggestion>[];
  for (final user in users) {
    if (user.toLowerCase().startsWith(lower)) {
      userMatches.add(UserSuggestion(displayName: user));
    }
  }

  final matchedIds = <String>{};
  final emoteMatches = <Suggestion>[];
  for (final emote in emotes) {
    if (emote.code.contains(word) || emote.code.toLowerCase().contains(lower)) {
      if (matchedIds.add(emote.id)) {
        emoteMatches.add(EmoteSuggestion(emote: emote));
      }
    }
  }

  // Numeric-leading suggestions still outrank everything (see _numericFirst);
  // within that, the chosen type order is emotes before users or users first.
  final combined = preferEmotesFirst
      ? [...emoteMatches, ...userMatches]
      : [...userMatches, ...emoteMatches];
  return _numericFirst(combined).take(100).toList();
}

final _leadingDigit = RegExp(r'[0-9]');

// Reorders suggestions so those whose text starts with a digit (e.g. "777",
// "500k") appear first, preserving relative order within each group. Dart's
// List.sort is not stable, so this partitions instead of sorting.
List<Suggestion> _numericFirst(List<Suggestion> suggestions) {
  final numeric = <Suggestion>[];
  final rest = <Suggestion>[];
  for (final suggestion in suggestions) {
    if (suggestion.displayText.startsWith(_leadingDigit)) {
      numeric.add(suggestion);
    } else {
      rest.add(suggestion);
    }
  }
  return [...numeric, ...rest];
}
