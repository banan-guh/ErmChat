import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/util/phrase_compaction.dart';
import 'package:flutter_test/flutter_test.dart';

String? condensed(String text) => compactRepeatedPhrase(text)?.text;

void main() {
  test('collapses a repeated phrase and drops the partial tail', () {
    final text = [
      for (var i = 0; i < 4; i++) 'THIS IS A COPYPASTA LULE',
      'THIS',
    ].join(' ');
    expect(condensed(text), 'THIS IS A COPYPASTA LULE (x4)');
  });

  test('a missing space still repeats', () {
    final text = [
      'THIS IS A COPYPASTA LULE',
      'THIS IS A COPYPASTALULE',
      'THIS IS A COPYPASTA LULE',
    ].join(' ');
    expect(condensed(text), 'THIS IS A COPYPASTA LULE (x3)');
  });

  test('a typo does not break the run and the common spelling wins', () {
    final text = [
      'THIS IS A COPYPASTA LULE',
      'THIS IS A COPYPASTA LUEL',
      'THIS IS A COPYPASTA LULE',
    ].join(' ');
    expect(condensed(text), 'THIS IS A COPYPASTA LULE (x3)');
  });

  test('keeps real text around the run', () {
    final text = [
      'intro',
      for (var i = 0; i < 3; i++) 'THIS IS A COPYPASTA LULE',
      'outro',
    ].join(' ');
    expect(condensed(text), 'intro THIS IS A COPYPASTA LULE (x3) outro');
  });

  test('short repeats are left alone', () {
    expect(condensed('no no no no no no'), isNull);
  });

  test('a normal long sentence is left alone', () {
    expect(
      condensed(
        'this is a normal sentence that is long enough but has no repeated '
        'phrase anywhere inside it at all',
      ),
      isNull,
    );
  });

  test('links and mentions are never part of a run', () {
    final text = [
      for (var i = 0; i < 3; i++) 'join the stream at https://example.com now',
    ].join(' ');
    expect(condensed(text), isNull);
  });

  test('two repeats are left alone', () {
    final text = [
      for (var i = 0; i < 2; i++) 'THIS IS A COPYPASTA LULE',
    ].join(' ');
    expect(condensed(text), isNull);
  });

  test('emote positions move onto the kept copy', () {
    const phrase = 'THIS IS A COPYPASTA LULE';
    final copies = [for (var i = 0; i < 4; i++) phrase];
    final text = copies.join(' ');
    final at = phrase.indexOf('LULE');
    final positions = [
      for (var i = 0; i < copies.length; i++)
        EmotePosition(
          emoteId: 'lule-$i',
          startIndex: i * (phrase.length + 1) + at,
          endIndex: i * (phrase.length + 1) + at + 4,
          emoteCode: 'LULE',
        ),
    ];

    final result = compactRepeatedPhrase(text)!;
    expect(result.text, '$phrase (x4)');
    final moved = result.moveEmotes(positions);
    expect(moved, hasLength(1));
    expect(moved.single.startIndex, at);
    expect(moved.single.endIndex, at + 4);
    expect(result.text.substring(at, at + 4), 'LULE');
  });

  test('emote positions outside the kept copy are dropped', () {
    const phrase = 'THIS IS A COPYPASTA LULE';
    final text = [for (var i = 0; i < 4; i++) phrase].join(' ');
    // A position in the third copy, which is condensed away.
    final third = 2 * (phrase.length + 1) + phrase.indexOf('LULE');
    final result = compactRepeatedPhrase(text)!;
    final moved = result.moveEmotes([
      EmotePosition(
        emoteId: 'lule',
        startIndex: third,
        endIndex: third + 4,
        emoteCode: 'LULE',
      ),
    ]);
    expect(moved, isEmpty);
  });
}
