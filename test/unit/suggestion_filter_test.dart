import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/models/twitch_command.dart';
import 'package:ermchat/services/suggestion.dart';

GenericEmote _e(String id, String code, [EmoteType type = EmoteType.bttv]) =>
    GenericEmote(
      id: id,
      code: code,
      type: type,
      url: 'https://example.com/$id.png',
    );

const _commands = <TwitchCommand>[
  TwitchCommand(name: '/me'),
  TwitchCommand(name: '/color'),
  TwitchCommand(name: '/ban'),
];

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

    test('preferEmotesFirst puts emotes before users', () {
      final result = filterSuggestions(
        word: 'test',
        emotes: [_e('1', 'testEmote')],
        users: {'testUser'},
        preferEmotesFirst: true,
      );
      expect(result.length, 2);
      expect(result[0], isA<EmoteSuggestion>());
      expect(result[1], isA<UserSuggestion>());
    });

    test('preferEmotesFirst does not override numeric-first', () {
      final result = filterSuggestions(
        word: '3',
        emotes: [_e('1', 'pog3')],
        users: {'3up'},
        preferEmotesFirst: true,
      );
      expect(
        result.map((s) => s.displayText).toList(),
        ['3up', 'pog3'],
        reason: 'numeric user still outranks a non-numeric emote',
      );
    });

    test('suggestions starting with a digit sort above everything else', () {
      final result = filterSuggestions(
        word: 'k',
        emotes: [_e('1', '500k'), _e('2', 'Kappa')],
        users: {'king'},
      );
      expect(
        result.map((s) => s.displayText).toList(),
        ['500k', 'king', 'Kappa'],
        reason: 'numeric emote outranks the user; non-numeric stays user-first',
      );
    });

    test('numeric ordering preserves relative order within each group', () {
      final result = filterSuggestions(
        word: '7',
        emotes: [_e('1', 'pog7'), _e('2', '777'), _e('3', '17tv')],
        users: {'7up'},
      );
      expect(
        result.map((s) => s.displayText).toList(),
        ['7up', '777', '17tv', 'pog7'],
        reason: 'numeric group keeps users-then-emotes order; rest follows',
      );
    });

    test('returns empty for empty word', () {
      final result = filterSuggestions(
        word: '',
        emotes: [_e('1', 'Kappa')],
        users: {'user1'},
      );
      expect(result, isEmpty);
    });

    test('bare slash returns every available command', () {
      final result = filterSuggestions(
        word: '/',
        emotes: [],
        users: {},
        commands: _commands,
      );
      expect(result.map((s) => s.displayText), ['/me', '/color', '/ban']);
    });

    test('slash word matches command prefixes', () {
      final result = filterSuggestions(
        word: '/b',
        emotes: [],
        users: {},
        commands: _commands,
      );
      expect(result.length, 1);
      expect(result[0], isA<CommandSuggestion>());
      expect(result[0].displayText, '/ban');
    });

    test('slash word matches case-insensitive', () {
      final result = filterSuggestions(
        word: '/ME',
        emotes: [],
        users: {},
        commands: _commands,
      );
      expect(result.length, 1);
      expect(result[0].displayText, '/me');
    });

    test('slash word never matches users or emotes', () {
      final result = filterSuggestions(
        word: '/me',
        emotes: [_e('1', 'me')],
        users: {'me', 'meUser'},
        commands: _commands,
      );
      expect(result.length, 1);
      expect(result[0], isA<CommandSuggestion>());
    });
  });
}
