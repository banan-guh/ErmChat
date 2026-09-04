import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ermchat/services/command_macros.dart';

void main() {
  group('expandMacro', () {
    final macros = {
      '!so': '/shoutout {1}',
      '!love': '{1} loves {2}',
      '!multi': '{1} then {2+} end',
      '!plain': 'hello',
    };

    test('returns null when nothing matches or the input is empty', () {
      const nullInputs = ['!unknown x', 'Kappa 123', '', '   '];
      for (final input in nullInputs) {
        expect(expandMacro(input, macros), isNull, reason: 'input: "$input"');
      }
      expect(expandMacro('!so forsen', const {}), isNull);
    });

    test(
      'substitutes positional and tail args, leaving missing args empty',
      () {
        const cases = {
          '!so forsen': '/shoutout forsen',
          '!love forsen forsen2': 'forsen loves forsen2',
          '!so': '/shoutout ',
          '!love forsen': 'forsen loves ',
          '!multi a b c d': 'a then b c d end',
          '!multi a': 'a then  end',
        };
        cases.forEach((input, expected) {
          expect(
            expandMacro(input, macros),
            expected,
            reason: 'input: "$input"',
          );
        });
      },
    );

    test('matches the trigger case-insensitively as the first token only', () {
      expect(expandMacro('!SO forsen', macros), '/shoutout forsen');
      expect(expandMacro('say !so now', macros), isNull);
    });

    test('keeps invalid specs literal and never re-expands output', () {
      const body = 'keep {0} and {x} and {} but use {1}';
      expect(
        expandMacro('!t hi', {'!t': body}),
        'keep {0} and {x} and {} but use hi',
      );
      // "!plain" expands to "hello", never to the !love chain.
      final nested = {'!a': '!b {1}', '!b': 'done'};
      expect(expandMacro('!a x', nested), '!b x');
    });
  });

  group('macro store', () {
    test('round-trips macros per account and keeps the cache fresh', () async {
      SharedPreferences.setMockInitialValues({});
      const login = 'tester';
      final macros = [
        const CommandMacro(name: '!so', body: '/shoutout {1}'),
        const CommandMacro(name: '!h', body: 'hi {1+}'),
      ];

      await saveMacros(login, macros);
      final loaded = await loadMacros(login);

      expect(loaded, hasLength(2));
      expect(loaded[0].name, '!so');
      expect(loaded[0].body, '/shoutout {1}');
      expect(loaded[1].body, 'hi {1+}');

      await saveMacros('alice', [const CommandMacro(name: '!a', body: 'aaa')]);
      await saveMacros('bob', [const CommandMacro(name: '!b', body: 'bbb')]);

      expect((await loadMacros('alice')).single.name, '!a');
      expect((await loadMacros('bob')).single.name, '!b');

      // cachedMacroLookup reflects the save without an explicit reload.
      expect(cachedMacroLookup('ALICE')?['!a'], 'aaa');
      expect(cachedMacroLookup('nobody'), isNull);

      await saveMacros('alice', []);
      expect(cachedMacroLookup('alice'), isNull);
    });

    test('corrupt entries are skipped on load', () async {
      SharedPreferences.setMockInitialValues({
        'macros_corrupt': ['not json', '{"name":"!ok","body":"fine"}'],
      });

      final loaded = await loadMacros('corrupt');
      expect(loaded, hasLength(1));
      expect(loaded.single.name, '!ok');
    });
  });

  test('macroLookup lowercases triggers', () {
    final lookup = macroLookup([const CommandMacro(name: '!So', body: 'x')]);
    expect(lookup.containsKey('!so'), isTrue);
    expect(lookup.containsKey('!So'), isFalse);
  });
}
