import 'dart:typed_data';

import 'package:ermchat/archive/archive_io.dart';
import 'package:ermchat/archive/archive_words.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('search words split on anything but letters, digits and _', () {
    expect(searchWords("@Alice: catJAM!! it's 10/10 ÉTÉ_ok こんにちは"), [
      'alice',
      'catjam',
      'it',
      's',
      '10',
      '10',
      'été_ok',
      'こんにちは',
    ]);
  });

  test('word lists and vocabulary chunks round-trip', () {
    final ids = [900, 3, 3, 70000, 0, 42];
    expect(decodeWordList(encodeWordList(ids)), [0, 3, 42, 900, 70000]);
    final many = [for (var i = 0; i < 2000; i += 3) i];
    expect(decodeWordList(encodeWordList(many)), many, reason: 'deflated');
    expect(decodeWordList(encodeWordList(const [])), isEmpty);
    expect(
      () => decodeWordList(Uint8List.fromList([9, 1, 2])),
      throwsA(isA<ArchiveFormatException>()),
    );
    expect(decodeVocabChunk(encodeVocabChunk(['a', 'é', 'catjam'])), [
      'a',
      'é',
      'catjam',
    ]);
  });
}
