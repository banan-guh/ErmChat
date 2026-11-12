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
  test('folds exact rows into the first', () {
    final result = compactChat([
      message('KEKW'),
      message('KEKW'),
      message('KEKW'),
    ]);
    expect(result.counts, {0: 3});
    expect(result.hidden, {1: 0, 2: 0});
  });

  test('folds a pair, so the second row never paints', () {
    final result = compactChat([message('KEKW'), message('KEKW')]);
    expect(result.counts, {0: 2});
    expect(result.hidden, {1: 0});
  });

  test('collapses whitespace and folds case', () {
    final result = compactChat([
      message('  KEKW   KEKW '),
      message('kekw kekw'),
    ]);
    expect(result.counts, {0: 2});
    expect(result.hidden, {1: 0});
  });

  test('folds edge punctuation', () {
    final result = compactChat([
      message('Hello there chat!'),
      message('hello there chat'),
      message('"hello there chat"'),
    ]);
    expect(result.counts, {0: 3});
    expect(result.hidden, {1: 0, 2: 0});
  });

  test('one word apart stays separate', () {
    final result = compactChat([
      message('hello there friend'),
      message('hello there friend'),
      message('hello there buddy'),
      message('hello there buddy'),
    ]);
    expect(result.counts, {0: 2, 2: 2});
    expect(result.hidden, {1: 0, 3: 2});
  });

  test('a typo stays separate', () {
    final result = compactChat([
      message('hello there friend'),
      message('hello there freind'),
    ]);
    expect(result.counts, isEmpty);
    expect(result.hidden, isEmpty);
  });

  test('matching stays inside one channel', () {
    final result = compactChat([
      message('KEKW', channel: 'a'),
      message('KEKW', channel: 'b'),
      message('KEKW', channel: 'a'),
      message('KEKW', channel: 'b'),
    ]);
    expect(result.counts, {0: 2, 1: 2});
    expect(result.hidden, {2: 0, 3: 1});
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

  test('a gap of ten seconds starts a new run', () {
    final at = DateTime(2026, 1, 1, 12);
    final result = compactChat([
      message('KEKW', at: at),
      message('KEKW', at: at.add(const Duration(seconds: 1))),
      message('KEKW', at: at.add(const Duration(seconds: 11))),
      message('KEKW', at: at.add(const Duration(seconds: 12))),
    ]);
    expect(result.counts, {0: 2, 2: 2});
    expect(result.hidden, {1: 0, 3: 2});
  });

  test('messages between copies do not split the run', () {
    final at = DateTime(2026, 1, 1, 12);
    final result = compactChat([
      message('KEKW', at: at),
      message('something else', at: at.add(const Duration(seconds: 2))),
      message('KEKW', at: at.add(const Duration(seconds: 3))),
    ]);
    expect(result.counts, {0: 2});
    expect(result.hidden, {2: 0});
  });

  test('a lone copy joins a run that follows it', () {
    final at = DateTime(2026, 1, 1, 12);
    final result = compactChat([
      message('om', at: at),
      message('om', at: at.add(const Duration(seconds: 2))),
      message('om', at: at.add(const Duration(seconds: 3))),
      message('om', at: at.add(const Duration(seconds: 4))),
      message('om', at: at.add(const Duration(seconds: 5))),
      message('om', at: at.add(const Duration(seconds: 6))),
    ]);
    expect(result.counts, {0: 6});
    expect(result.hidden, {1: 0, 2: 0, 3: 0, 4: 0, 5: 0});
  });

  test('starts a new run after one hundred rows', () {
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

  test('a rewritten row folds by its new text', () {
    final a = message('KEKW');
    final b = message('KEKW');
    expect(compactChat([a, b]).counts, {0: 2});
    // Keyword replacements rewrite text in place between passes.
    b.text = 'OMEGALUL';
    final result = compactChat([a, b]);
    expect(result.counts, isEmpty);
    expect(result.hidden, isEmpty);
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
