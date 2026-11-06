import 'package:ermchat/models/highlight_state.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/util/chat_compaction.dart';
import 'package:flutter_test/flutter_test.dart';

TwitchMessage message(
  String text, {
  String login = 'alice',
  DateTime? at,
  bool system = false,
  bool deleted = false,
  bool highlighted = false,
  bool first = false,
  String? replyTo,
  String channel = 'channel',
}) => TwitchMessage(
  login: login,
  text: text,
  timestamp: at ?? DateTime(2026, 1, 1, 12),
  isSystem: system,
  deleted: deleted,
  highlight: highlighted
      ? const HighlightState(types: {HighlightType.tint})
      : null,
  isFirstMessage: first,
  replyToUser: replyTo,
  channel: channel,
);

void main() {
  test('folds three exact rows into the first', () {
    final result = compactChat([
      message('KEKW'),
      message('KEKW'),
      message('KEKW'),
    ]);
    expect(result.counts, {0: 3});
    expect(result.hidden, {1: 0, 2: 0});
  });

  test('keeps a pair visible', () {
    final result = compactChat([message('KEKW'), message('KEKW')]);
    expect(result.counts, isEmpty);
    expect(result.hidden, isEmpty);
  });

  test('normalizes whitespace but keeps case', () {
    final result = compactChat([
      message('  KEKW   KEKW '),
      message('KEKW KEKW'),
      message('KEKW KEKW'),
      message('kekw kekw'),
      message('kekw kekw'),
      message('kekw kekw'),
    ]);
    expect(result.counts, {0: 3, 3: 3});
    expect(result.hidden, {1: 0, 2: 0, 4: 3, 5: 3});
  });

  test('folds one-word variants into the first', () {
    final result = compactChat([
      message('hello there friend'),
      message('hello there buddy'),
      message('hello there pal'),
    ]);
    expect(result.counts, {0: 3});
    expect(result.hidden, {1: 0, 2: 0});
  });

  test('folds a word added or removed', () {
    final result = compactChat([
      message('hello there chat'),
      message('hello there my chat'),
      message('hello there chat'),
    ]);
    expect(result.counts, {0: 3});
    expect(result.hidden, {1: 0, 2: 0});
  });

  test('folds case and punctuation variants', () {
    final result = compactChat([
      message('Hello there chat!'),
      message('hello there chat'),
      message('HELLO THERE CHAT'),
    ]);
    expect(result.counts, {0: 3});
    expect(result.hidden, {1: 0, 2: 0});
  });

  test('two strong copypastas one word apart stay separate', () {
    final result = compactChat([
      message('hello there friend'),
      message('hello there friend'),
      message('hello there friend'),
      message('hello there buddy'),
      message('hello there buddy'),
      message('hello there buddy'),
    ]);
    expect(result.counts, {0: 3, 3: 3});
    expect(result.hidden, {1: 0, 2: 0, 4: 3, 5: 3});
  });

  test('two-word rows never fuzzy match', () {
    final result = compactChat([
      message('ok thanks'),
      message('no thanks'),
      message('ok thanks'),
    ]);
    expect(result.counts, isEmpty);
    expect(result.hidden, isEmpty);
  });

  test('urls, mentions and hashtags never fuzzy match', () {
    final result = compactChat([
      message('look at this http://a.example'),
      message('look at this http://b.example'),
      message('look at this http://a.example'),
      message('thanks @alice for this'),
      message('thanks @bobby for this'),
      message('thanks @alice for this'),
      message('join the #one crowd now'),
      message('join the #two crowd now'),
      message('join the #one crowd now'),
      message('go to a.example now'),
      message('go to b.example now'),
      message('go to a.example now'),
    ]);
    expect(result.counts, isEmpty);
    expect(result.hidden, isEmpty);
  });

  test('fuzzy matching stays inside one channel', () {
    final result = compactChat([
      message('hello there friend', channel: 'a'),
      message('hello there buddy', channel: 'b'),
      message('hello there friend', channel: 'a'),
    ]);
    expect(result.counts, isEmpty);
    expect(result.hidden, isEmpty);
  });

  test('groups two copypastas independently', () {
    final result = compactChat([
      message('first'),
      message('second'),
      message('first'),
      message('second'),
      message('first'),
      message('second'),
    ]);
    expect(result.counts, {0: 3, 1: 3});
    expect(result.hidden, {2: 0, 3: 1, 4: 0, 5: 1});
  });

  test('a seeded group folds at two in the next chunk', () {
    final at = DateTime(2026, 1, 1, 12);
    final result = compactChat([
      message('KEKW', at: at),
      message('KEKW', at: at.add(const Duration(seconds: 1))),
      message('KEKW', at: at.add(const Duration(seconds: 2))),
      message('KEKW', at: at.add(const Duration(seconds: 11))),
      message('KEKW', at: at.add(const Duration(seconds: 12))),
    ]);
    expect(result.counts, {0: 3, 3: 2});
    expect(result.hidden, {1: 0, 2: 0, 4: 3});
  });

  test('a fuzzy variant resumes the seed', () {
    final at = DateTime(2026, 1, 1, 12);
    final result = compactChat([
      message('hello there friend', at: at),
      message('hello there friend', at: at.add(const Duration(seconds: 1))),
      message('hello there friend', at: at.add(const Duration(seconds: 2))),
      message('hello there buddy', at: at.add(const Duration(seconds: 11))),
      message('hello there buddy', at: at.add(const Duration(seconds: 12))),
    ]);
    expect(result.counts, {0: 3, 3: 2});
    expect(result.hidden, {1: 0, 2: 0, 4: 3});
  });

  test('a resumed seed still needs two messages', () {
    final at = DateTime(2026, 1, 1, 12);
    final result = compactChat([
      message('KEKW', at: at),
      message('KEKW', at: at.add(const Duration(seconds: 1))),
      message('KEKW', at: at.add(const Duration(seconds: 2))),
      message('KEKW', at: at.add(const Duration(seconds: 11))),
    ]);
    expect(result.counts, {0: 3});
    expect(result.hidden, {1: 0, 2: 0});
  });

  test('a chunk without the seed drops it', () {
    final at = DateTime(2026, 1, 1, 12);
    final result = compactChat([
      message('KEKW', at: at),
      message('KEKW', at: at.add(const Duration(seconds: 1))),
      message('KEKW', at: at.add(const Duration(seconds: 2))),
      message('other', at: at.add(const Duration(seconds: 11))),
      message('KEKW', at: at.add(const Duration(seconds: 21))),
      message('KEKW', at: at.add(const Duration(seconds: 22))),
    ]);
    expect(result.counts, {0: 3});
    expect(result.hidden, {1: 0, 2: 0});
  });

  test('starts a new chunk after ten seconds', () {
    final at = DateTime(2026, 1, 1, 12);
    final result = compactChat([
      message('KEKW', at: at),
      message('KEKW', at: at.add(const Duration(seconds: 1))),
      message('KEKW', at: at.add(const Duration(seconds: 2))),
      message('KEKW', at: at.add(const Duration(seconds: 11))),
      message('KEKW', at: at.add(const Duration(seconds: 12))),
      message('KEKW', at: at.add(const Duration(seconds: 13))),
    ]);
    expect(result.counts, {0: 3, 3: 3});
    expect(result.hidden, {1: 0, 2: 0, 4: 3, 5: 3});
  });

  test('starts a new chunk after one hundred rows', () {
    final at = DateTime(2026, 1, 1, 12);
    final rows = [
      for (var i = 0; i < 101; i++)
        message('KEKW', at: at.add(Duration(milliseconds: i))),
    ];
    final result = compactChat(rows);
    expect(result.counts, {0: 100});
    expect(result.hidden.length, 99);
    expect(result.hidden.containsKey(100), isFalse);
  });

  test('skips highlighted, first, reply, system and deleted rows', () {
    final result = compactChat([
      message('KEKW'),
      message('KEKW', highlighted: true),
      message('KEKW', first: true),
      message('KEKW', replyTo: 'bob'),
      message('KEKW', system: true),
      message('KEKW', deleted: true),
      message('KEKW'),
      message('KEKW'),
    ]);
    expect(result.counts, {0: 3});
    expect(result.hidden, {6: 0, 7: 0});
  });

  test('a deleted member leaves a visible row', () {
    final result = compactChat([
      message('KEKW'),
      message('KEKW', deleted: true),
      message('KEKW'),
      message('KEKW'),
    ]);
    expect(result.counts, {0: 3});
    expect(result.hidden, {2: 0, 3: 0});
  });

  test('local skips never count', () {
    final result = compactChat([
      message('KEKW', login: 'ignored'),
      message('KEKW'),
      message('KEKW'),
      message('KEKW'),
    ], skip: (m) => m.login == 'ignored');
    expect(result.counts, {1: 3});
    expect(result.hidden, {2: 1, 3: 1});
  });
}
