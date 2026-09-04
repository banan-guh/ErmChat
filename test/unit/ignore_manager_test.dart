import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/ignore_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<IgnoreManager> makeManager([
    Map<String, Object> initialPrefs = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(initialPrefs);
    final manager = IgnoreManager();
    await manager.load();
    return manager;
  }

  group('user ignores', () {
    test(
      'matches user ignores case-insensitively unless the flag is set',
      () async {
        final m = await makeManager();
        m.upsertUser(const IgnoreEntry(id: 'u1', pattern: 'SpamBot'));
        const baseCases = [
          ('spambot', true),
          ('SPAMBOT', true),
          ('other', false),
        ];
        for (final (input, expected) in baseCases) {
          expect(m.isIgnored(input), expected, reason: 'input: $input');
        }

        m.upsertUser(
          const IgnoreEntry(id: 'u2', pattern: 'Spam', caseSensitive: true),
        );
        // Contains semantics for literal patterns.
        expect(m.isIgnored('xSpamx'), isTrue);
        expect(m.isIgnored('spam'), isFalse);
      },
    );

    test('regex user patterns match logins', () async {
      final m = await makeManager();
      m.upsertUser(
        const IgnoreEntry(id: 'u3', pattern: r'^bot_\d+$', isRegex: true),
      );
      expect(m.isIgnored('bot_123'), isTrue);
      expect(m.isIgnored('a_bot_123'), isFalse);
      expect(m.isIgnored('bot_abc'), isFalse);
    });
  });

  group('keyword replacements', () {
    test(
      'rewrites plain patterns with the default replacement and resolves overlaps',
      () async {
        final m = await makeManager();
        m.upsertKeyword(const IgnoreEntry(id: 'k1', pattern: 'KEKW'));
        final r = m.applyKeywordReplacements('lol KEKW kekw KEKW!');
        expect(r.text, 'lol *** *** ***!');
        expect(r.changed, isTrue);

        final overlap = await makeManager();
        overlap.upsertKeyword(const IgnoreEntry(id: 'k5a', pattern: 'abcdef'));
        overlap.upsertKeyword(const IgnoreEntry(id: 'k5b', pattern: 'abc'));
        // abcdef starts earlier in the string and wins the overlap.
        final or = overlap.applyKeywordReplacements('xx abcdef yy');
        expect(or.text, 'xx *** yy');
        expect(or.edits.single.start, 3);
        expect(or.edits.single.end, 9);
      },
    );

    test(
      'applies custom replacements while preserving the original casing',
      () async {
        final m = await makeManager();
        m.upsertKeyword(
          const IgnoreEntry(
            id: 'k2',
            pattern: 'bad',
            replacement: '[censored]',
          ),
        );
        m.upsertKeyword(const IgnoreEntry(id: 'k3', pattern: 'ugoh'));
        const cases = {'bad bad': '[censored] [censored]', 'UGOH!': '***!'};
        cases.forEach((input, expected) {
          expect(
            m.applyKeywordReplacements(input).text,
            expected,
            reason: 'input: $input',
          );
        });
      },
    );

    test('regex rules with invalid fallback to literal', () async {
      final m = await makeManager();
      m.upsertKeyword(
        const IgnoreEntry(id: 'k4', pattern: '(oops', isRegex: true),
      );
      expect(m.applyKeywordReplacements('(oops there').text, '*** there');
    });
  });

  group('block mode + whole word', () {
    test('block entries drop instead of rewrite', () async {
      final m = await makeManager();
      m.upsertKeyword(
        const IgnoreEntry(id: 'b1', pattern: 'spoilers', block: true),
      );
      m.upsertKeyword(const IgnoreEntry(id: 'b2', pattern: 'mild'));
      expect(m.isBlockedPhrase('major spoilers ahead'), isTrue);
      expect(m.isBlockedPhrase('a mild take'), isFalse);
      // Blocked rules never rewrite; non-blocked ones still do.
      final r = m.applyKeywordReplacements('mild spoilers');
      expect(r.text, '*** spoilers');
    });

    test(
      'whole word anchors literals without breaking punctuation edges',
      () async {
        final m = await makeManager();
        m.upsertKeyword(
          const IgnoreEntry(id: 'w1', pattern: 'cat', wordBoundary: true),
        );
        expect(m.applyKeywordReplacements('a cat!').text, 'a ***!');
        expect(m.applyKeywordReplacements('category cat').text, 'category ***');
        // Punctuation-edged pattern still anchors via lookaround.
        m.upsertKeyword(
          const IgnoreEntry(id: 'w2', pattern: ':)', wordBoundary: true),
        );
        expect(m.applyKeywordReplacements('hi :)').text, 'hi ***');
        // ':' before the smiley is not a word char, so the second one matches.
        expect(m.applyKeywordReplacements('::)').text, ':***');
      },
    );
  });

  group('rewriteMessageKeywords emote realignment', () {
    EmotePosition pos(int s, int e) => EmotePosition(
      emoteId: 'E1',
      startIndex: s,
      endIndex: e,
      emoteCode: 'Kappa',
    );

    test('emotes after an edit shift by the length delta', () async {
      SharedPreferences.setMockInitialValues({});
      final m = IgnoreManager();
      await m.load();
      m.upsertKeyword(
        // Replacement shorter than the match shifts later positions left.
        const IgnoreEntry(id: 'e1', pattern: 'verylongword', replacement: 'x'),
      );
      final msg = TwitchMessage(
        login: 'a',
        text: 'verylongword Kappa',
        emotePositions: [pos(13, 18)],
      );
      rewriteMessageKeywords(msg, m);
      expect(msg.text, 'x Kappa');
      expect(msg.emotePositions!.single.startIndex, 2);
      expect(msg.emotePositions!.single.endIndex, 7);
    });

    test('emotes overlapping a replaced span are dropped', () async {
      SharedPreferences.setMockInitialValues({});
      final m = IgnoreManager();
      await m.load();
      m.upsertKeyword(const IgnoreEntry(id: 'e2', pattern: 'hide this'));
      final msg = TwitchMessage(
        login: 'a',
        text: 'hide this now',
        emotePositions: [
          pos(0, 4), // overlaps the replaced range -> dropped
          pos(10, 13), // "now" survives, shifted left by 6
        ],
      );
      rewriteMessageKeywords(msg, m);
      expect(msg.text, '*** now');
      expect(msg.emotePositions!.length, 1);
      expect(msg.emotePositions!.first.startIndex, 4);
      expect(msg.emotePositions!.first.endIndex, 7);
    });
  });

  group('persistence', () {
    test('round-trips entries through JSON and tolerates garbage input', () {
      const entry = IgnoreEntry(
        id: 'p1',
        pattern: 'x',
        isRegex: true,
        caseSensitive: true,
        replacement: 'y',
      );
      final decoded = decodeEntries(
        '['
        '{"id":"p1","pattern":"x","isRegex":true,"caseSensitive":true,'
        '"replacement":"y"}'
        ']',
      );
      expect(decoded.single.toJson(), entry.toJson());
      expect(decodeEntries('garbage'), isEmpty);
      expect(decodeEntries('{"id":"x"}'), isEmpty);
    });
  });
}
