import 'package:ermchat/util/phrase_compaction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('collapses a repeated phrase and drops the partial tail', () {
    final text = [
      for (var i = 0; i < 4; i++) 'THIS IS A COPYPASTA LULE',
      'THIS',
    ].join(' ');
    expect(compactRepeatedPhrase(text), 'THIS IS A COPYPASTA LULE (x4)');
  });

  test('a missing space still repeats', () {
    final text = [
      'THIS IS A COPYPASTA LULE',
      'THIS IS A COPYPASTALULE',
      'THIS IS A COPYPASTA LULE',
    ].join(' ');
    expect(compactRepeatedPhrase(text), 'THIS IS A COPYPASTA LULE (x3)');
  });

  test('a typo does not break the run and the common spelling wins', () {
    final text = [
      'THIS IS A COPYPASTA LULE',
      'THIS IS A COPYPASTA LUEL',
      'THIS IS A COPYPASTA LULE',
    ].join(' ');
    expect(compactRepeatedPhrase(text), 'THIS IS A COPYPASTA LULE (x3)');
  });

  test('keeps real text around the run', () {
    final text = [
      'intro',
      for (var i = 0; i < 3; i++) 'THIS IS A COPYPASTA LULE',
      'outro',
    ].join(' ');
    expect(
      compactRepeatedPhrase(text),
      'intro THIS IS A COPYPASTA LULE (x3) outro',
    );
  });

  test('short repeats are left alone', () {
    expect(compactRepeatedPhrase('no no no no no no'), isNull);
  });

  test('a normal long sentence is left alone', () {
    expect(
      compactRepeatedPhrase(
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
    expect(compactRepeatedPhrase(text), isNull);
  });

  test('two repeats are left alone', () {
    final text = [
      for (var i = 0; i < 2; i++) 'THIS IS A COPYPASTA LULE',
    ].join(' ');
    expect(compactRepeatedPhrase(text), isNull);
  });
}
