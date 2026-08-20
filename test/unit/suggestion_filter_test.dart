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

List<String> _codes(List<Suggestion> suggestions) =>
    suggestions.map((s) => s.displayText).toList();

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

    test('returns empty for empty word', () {
      final result = filterSuggestions(
        word: '',
        emotes: [_e('1', 'Kappa')],
        users: {'user1'},
      );
      expect(result, isEmpty);
    });

    group('emote scoring', () {
      test('shorter matches rank before longer ones', () {
        final result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'PogChamp'), _e('2', 'PogU'), _e('3', 'Pog')],
          users: {},
        );
        expect(_codes(result), ['Pog', 'PogU', 'PogChamp']);
      });

      test('exact case beats case mismatch at the same length', () {
        final result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'POGX'), _e('2', 'PogX')],
          users: {},
        );
        // PogX: 1 case diff + 1*100 = 101, POGX: 2 case diffs + 1*100 = 102.
        expect(_codes(result), ['PogX', 'POGX']);
      });

      test('shorter match beats case-mismatched longer match', () {
        final result = filterSuggestions(
          word: 'wi',
          emotes: [_e('1', 'wikked'), _e('2', 'Wink')],
          users: {},
        );
        // Wink: 1 case diff + 2*100 = 201, wikked: -10 + 4*100 = 390.
        expect(_codes(result), ['Wink', 'wikked']);
      });

      test('recently used emote gets a boost', () {
        final result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'PogChamp'), _e('2', 'PogU')],
          users: {},
          recentEmoteIds: {'1'},
        );
        // PogChamp: -10 + 5*100 - 50 = 440, PogU: -10 + 1*100 = 90.
        expect(_codes(result), ['PogU', 'PogChamp']);
      });

      test('non-matching emotes are excluded', () {
        final result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'Kappa'), _e('2', 'PogChamp'), _e('3', 'LUL')],
          users: {},
        );
        expect(_codes(result), ['PogChamp']);
      });

      test('matches mid-code case-insensitively', () {
        final result = filterSuggestions(
          word: 'pog',
          emotes: [_e('1', 'PogChamp')],
          users: {},
        );
        expect(_codes(result), ['PogChamp']);
      });

      test('deduplicates by emote id', () {
        final result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'PogChamp'), _e('1', 'PogChamp')],
          users: {},
        );
        expect(result.length, 1);
      });
    });

    group('users', () {
      test('users carry a penalty so emotes win near-ties', () {
        final result = filterSuggestions(
          word: 'Pog',
          emotes: [_e('1', 'PogU')],
          users: {'Pog'},
        );
        // Emote PogU: -10 + 100 = 90. User Pog: -10 + 25 = 15.
        expect(_codes(result), ['Pog', 'PogU']);
      });

      test('users match anywhere (contains) and sort by score', () {
        final result = filterSuggestions(
          word: 'xq',
          emotes: [],
          users: {'xqcL', 'xqc'},
        );
        // xqc: -10 + 100 + 25 = 115, xqcL: -10 + 200 + 25 = 215.
        expect(_codes(result), ['xqc', 'xqcL']);
      });

      test('preferEmotesFirst keeps the type split: all emotes first', () {
        final defaultResult = filterSuggestions(
          word: 'test',
          emotes: [_e('1', 'testEmote')],
          users: {'testUser'},
        );
        // testUser: -10 + 400 + 25 = 415, testEmote: -10 + 500 = 490.
        expect(defaultResult[0], isA<UserSuggestion>());

        final flipped = filterSuggestions(
          word: 'test',
          emotes: [_e('1', 'testEmote')],
          users: {'testUser'},
          preferEmotesFirst: true,
        );
        expect(flipped[0], isA<EmoteSuggestion>());
        expect(flipped[1], isA<UserSuggestion>());
      });

      test('numeric queries surface the short exact emote first', () {
        final result = filterSuggestions(
          word: '7',
          emotes: [_e('1', 'pog7'), _e('2', '777'), _e('3', '17tv')],
          users: {'7up'},
        );
        // 777: -10 + 200 = 190, 7up: -10 + 200 + 25 = 215,
        // 17tv/pog7: -10 + 300 = 290 (alphabetical tie-break).
        expect(_codes(result), ['777', '7up', '17tv', 'pog7']);
      });

      test('non-matching users are excluded', () {
        final result = filterSuggestions(
          word: 'alice',
          emotes: [],
          users: {'bob', 'carol'},
        );
        expect(result, isEmpty);
      });
    });

    group('commands', () {
      test('bare slash returns every available command', () {
        final result = filterSuggestions(
          word: '/',
          emotes: [],
          users: {},
          commands: _commands,
        );
        expect(_codes(result), ['/me', '/color', '/ban']);
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
  });
}
