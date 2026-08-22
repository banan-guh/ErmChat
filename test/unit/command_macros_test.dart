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

    test('returns null when no trigger matches', () {
      expect(expandMacro('!unknown x', macros), isNull);
      expect(expandMacro('Kappa 123', macros), isNull);
    });

    test('returns null for empty input or empty lookup', () {
      expect(expandMacro('', macros), isNull);
      expect(expandMacro('   ', macros), isNull);
      expect(expandMacro('!so forsen', const {}), isNull);
    });

    test('substitutes positional args', () {
      expect(expandMacro('!so forsen', macros), '/shoutout forsen');
      expect(
        expandMacro('!love forsen forsen2', macros),
        'forsen loves forsen2',
      );
    });

    test('missing args expand to empty string', () {
      expect(expandMacro('!so', macros), '/shoutout ');
      expect(expandMacro('!love forsen', macros), 'forsen loves ');
    });

    test('{n+} joins the tail of the args', () {
      expect(expandMacro('!multi a b c d', macros), 'a then b c d end');
      expect(expandMacro('!multi a', macros), 'a then  end');
    });

    test('trigger matching is case-insensitive, body preserved', () {
      expect(expandMacro('!SO forsen', macros), '/shoutout forsen');
    });

    test('trigger must be the first token', () {
      expect(expandMacro('say !so now', macros), isNull);
    });

    test('invalid or zero placeholder specs stay literal', () {
      const body = 'keep {0} and {x} and {} but use {1}';
      final result = expandMacro('!t hi', {'!t': body});
      expect(result, 'keep {0} and {x} and {} but use hi');
    });

    test('no re-expansion of macro output (single pass)', () {
      // "!plain" expands to "hello", never to the !love chain.
      final nested = {'!a': '!b {1}', '!b': 'done'};
      expect(expandMacro('!a x', nested), '!b x');
    });
  });

  group('macro store', () {
    test('save + load round-trips per account', () async {
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
    });

    test('accounts are isolated and cache stays fresh after save', () async {
      SharedPreferences.setMockInitialValues({});
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
