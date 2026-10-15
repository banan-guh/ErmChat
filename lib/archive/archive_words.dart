import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'archive_io.dart';

/// The search index's pieces: the words of a text, a block's sorted word ids
/// (delta varints, deflated when that is smaller), and vocabulary chunks
/// (newline-joined new words, deflated).

final _split = RegExp(r'[^\p{L}\p{N}_]+', unicode: true);

/// Lowercased words of [text]: runs of letters, digits and underscores.
Iterable<String> searchWords(String text) =>
    text.toLowerCase().split(_split).where((w) => w.isNotEmpty);

const int _listRaw = 0;
const int _listDeflated = 1;

/// Packs word ids, any order, duplicates allowed.
Uint8List encodeWordList(Iterable<int> ids) {
  final sorted = ids.toSet().toList()..sort();
  final w = ByteWriter()..varint(sorted.length);
  var prev = 0;
  for (final id in sorted) {
    w.varint(id - prev);
    prev = id;
  }
  final raw = w.takeBytes();
  final packed = ZLibCodec(level: 6, raw: true).encode(raw);
  return packed.length < raw.length
      ? (BytesBuilder()
              ..addByte(_listDeflated)
              ..add(packed))
            .takeBytes()
      : (BytesBuilder()
              ..addByte(_listRaw)
              ..add(raw))
            .takeBytes();
}

/// Sorted word ids of a [encodeWordList] result.
List<int> decodeWordList(Uint8List data) {
  if (data.isEmpty) {
    throw const ArchiveFormatException('empty word list');
  }
  final body = Uint8List.sublistView(data, 1);
  final raw = switch (data[0]) {
    _listRaw => body,
    _listDeflated => Uint8List.fromList(ZLibCodec(raw: true).decode(body)),
    _ => throw const ArchiveFormatException('unknown word list kind'),
  };
  final r = ByteReader(raw);
  final n = r.varint();
  if (n > raw.length) {
    throw const ArchiveFormatException('implausible word count');
  }
  final out = List<int>.filled(n, 0);
  var prev = 0;
  for (var i = 0; i < n; i++) {
    out[i] = prev += r.varint();
  }
  return out;
}

/// Packs a run of new vocabulary words.
Uint8List encodeVocabChunk(List<String> words) => Uint8List.fromList(
  ZLibCodec(level: 6, raw: true).encode(utf8.encode(words.join('\n'))),
);

List<String> decodeVocabChunk(Uint8List data) =>
    utf8.decode(ZLibCodec(raw: true).decode(data)).split('\n');
