import 'package:ermchat/emotes/emote.dart';
import 'package:flutter_test/flutter_test.dart';

Emote _emote(String code, {int? at}) => Emote(
  id: code,
  code: code,
  meta: const BttvMeta(),
  scales: const {},
  createdAtMs: at,
);

List<String> _codes(List<Emote> emotes) => [for (final e in emotes) e.code];

void main() {
  test('name order is alphabetical', () {
    final out = sortedEmotes([
      _emote('c'),
      _emote('a'),
      _emote('b'),
    ], EmoteSortOrder.name);
    expect(_codes(out), ['a', 'b', 'c']);
  });

  test('newest and oldest follow the date, undated last', () {
    final list = [
      _emote('old', at: 1000),
      _emote('undated'),
      _emote('new', at: 3000),
      _emote('mid', at: 2000),
    ];
    expect(_codes(sortedEmotes(list, EmoteSortOrder.newest)), [
      'new',
      'mid',
      'old',
      'undated',
    ]);
    expect(_codes(sortedEmotes(list, EmoteSortOrder.oldest)), [
      'old',
      'mid',
      'new',
      'undated',
    ]);
  });

  test('equal dates fall back to the code', () {
    final out = sortedEmotes([
      _emote('b', at: 1000),
      _emote('a', at: 1000),
    ], EmoteSortOrder.newest);
    expect(_codes(out), ['a', 'b']);
  });

  test('the input list keeps its order', () {
    final list = [_emote('b', at: 1000), _emote('a', at: 2000)];
    sortedEmotes(list, EmoteSortOrder.newest);
    expect(_codes(list), ['b', 'a']);
  });
}
