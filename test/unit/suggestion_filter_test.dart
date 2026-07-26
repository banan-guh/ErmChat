import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/services/suggestion.dart';

GenericEmote _e(String id, String code, [EmoteType type = EmoteType.bttv]) =>
    GenericEmote(
      id: id,
      code: code,
      type: type,
      url: 'https://example.com/$id.png',
    );

void main() {
  group('filterSuggestions', () {
    test('returns empty when no emote or user matches', () {
      final result = filterSuggestions(
        word: 'xyz',
        emotes: [_e('1', 'Kappa'), _e('2', 'PogChamp')],
        users: {'user1', 'user2'},
      );
      expect(result, isEmpty);
    });

    test('returns users matching prefix case-insensitive', () {
      final result = filterSuggestions(
        word: 'Use',
        emotes: [],
        users: {'UserOne', 'user2', 'other'},
      );
      expect(result.length, 2);
      expect(result[0], isA<UserSuggestion>());
      expect(result[1], isA<UserSuggestion>());
    });

    test('returns emotes matching prefix case-sensitive first', () {
      final result = filterSuggestions(
        word: 'Pog',
        emotes: [_e('1', 'PogChamp'), _e('2', 'poggers'), _e('3', 'Kappa')],
        users: {},
      );
      expect(result.length, 2);
      expect((result[0] as EmoteSuggestion).emote.code, 'PogChamp');
      expect((result[1] as EmoteSuggestion).emote.code, 'poggers');
    });

    test('returns emotes matching prefix case-insensitive after exact', () {
      final result = filterSuggestions(
        word: 'pog',
        emotes: [_e('1', 'PogChamp')],
        users: {},
      );
      expect(result.length, 1);
      expect((result[0] as EmoteSuggestion).emote.code, 'PogChamp');
    });

    test('returns users before emotes in results', () {
      final result = filterSuggestions(
        word: 'test',
        emotes: [_e('1', 'testEmote')],
        users: {'testUser'},
      );
      expect(result.length, 2);
      expect(result[0], isA<UserSuggestion>());
      expect(result[1], isA<EmoteSuggestion>());
    });

    test('deduplicates emotes across case-sensitive and insensitive', () {
      final result = filterSuggestions(
        word: 'Pog',
        emotes: [_e('1', 'PogChamp')],
        users: {},
      );
      expect(result.length, 1);
    });

    test('returns empty for empty word', () {
      final result = filterSuggestions(
        word: '',
        emotes: [_e('1', 'Kappa')],
        users: {'user1'},
      );
      expect(result, isEmpty);
    });
  });

  group('UserSuggestion', () {
    test('displayText returns displayName', () {
      final s = UserSuggestion(displayName: 'TestUser');
      expect(s.displayText, 'TestUser');
    });
  });

  group('EmoteSuggestion', () {
    test('displayText returns emote code', () {
      final emote = _e('1', 'Kappa');
      final s = EmoteSuggestion(emote: emote);
      expect(s.displayText, 'Kappa');
    });
  });
}
