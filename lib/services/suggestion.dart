import 'package:flutter/material.dart';
import '../models/generic_emote.dart';

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
  return CurrentWord(
    start: start,
    end: end,
    text: text.substring(start, end),
  );
}

void replaceCurrentWord(TextEditingController controller, String replacement) {
  final text = controller.text;
  final cursor = controller.selection.baseOffset.clamp(0, text.length);
  final word = getCurrentWord(text, cursor);
  final trailingSpace =
      word.end < text.length && text[word.end] == ' ' ? '' : ' ';
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

List<Suggestion> filterSuggestions({
  required String word,
  required List<GenericEmote> emotes,
  required Set<String> users,
}) {
  final results = <Suggestion>[];

  if (word.isEmpty) return results;

  final lower = word.toLowerCase();
  for (final user in users) {
    if (user.toLowerCase().startsWith(lower)) {
      results.add(UserSuggestion(displayName: user));
    }
  }

  final matchedEmotes = <GenericEmote>[];
  for (final emote in emotes) {
    if (emote.code.contains(word)) {
      matchedEmotes.add(emote);
    }
  }
  for (final emote in emotes) {
    if (!matchedEmotes.contains(emote) &&
        emote.code.toLowerCase().contains(lower)) {
      matchedEmotes.add(emote);
    }
  }
  for (final emote in matchedEmotes) {
    results.add(EmoteSuggestion(emote: emote));
  }

  return results;
}
