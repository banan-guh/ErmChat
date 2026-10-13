import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Thrown when archive bytes are truncated, corrupt, or from an unknown version.
class ArchiveFormatException implements Exception {
  const ArchiveFormatException(this.message);

  final String message;

  @override
  String toString() => 'ArchiveFormatException: $message';
}

/// Append-only byte buffer with LEB128 varints.
class ByteWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  int get length => _out.length;

  void byte(int b) => _out.addByte(b);

  void bytes(List<int> b) => _out.add(b);

  /// Writes an int as an unsigned 64-bit varint.
  void varint(int v) {
    while (v < 0 || v >= 0x80) {
      _out.addByte((v & 0x7f) | 0x80);
      v >>>= 7;
    }
    _out.addByte(v);
  }

  /// Writes a signed int zigzag-encoded.
  void zigzag(int v) => varint((v << 1) ^ (v >> 63));

  /// Writes a length-prefixed UTF-8 string.
  void string(String s) {
    final b = utf8.encode(s);
    varint(b.length);
    _out.add(b);
  }

  /// Writes the other writer's bytes prefixed with their length.
  void section(ByteWriter other) {
    varint(other.length);
    _out.add(other.takeBytes());
  }

  Uint8List takeBytes() => _out.takeBytes();
}

/// Bounds-checked reader over [data]; every overrun throws [ArchiveFormatException].
class ByteReader {
  ByteReader(this.data, [this.pos = 0, int? end]) : end = end ?? data.length;

  final Uint8List data;
  final int end;
  int pos;

  int get remaining => end - pos;

  int byte() {
    if (pos >= end) {
      throw const ArchiveFormatException('unexpected end of data');
    }
    return data[pos++];
  }

  int varint() {
    var result = 0;
    for (var shift = 0; shift < 70; shift += 7) {
      final b = byte();
      result |= (b & 0x7f) << shift;
      if (b < 0x80) {
        return result;
      }
    }
    throw const ArchiveFormatException('varint too long');
  }

  int zigzag() {
    final v = varint();
    return (v >>> 1) ^ -(v & 1);
  }

  Uint8List bytes(int n) {
    if (n < 0 || n > remaining) {
      throw const ArchiveFormatException('length past end of data');
    }
    final out = Uint8List.sublistView(data, pos, pos + n);
    pos += n;
    return out;
  }

  String string() {
    try {
      return utf8.decode(bytes(varint()));
    } on FormatException {
      throw const ArchiveFormatException('invalid utf-8');
    }
  }

  /// Reads a length-prefixed section as its own reader.
  ByteReader section() {
    final n = varint();
    if (n > remaining) {
      throw const ArchiveFormatException('section past end of data');
    }
    final r = ByteReader(data, pos, pos + n);
    pos += n;
    return r;
  }
}

/// Wraps [raw] as version byte, raw length, deflated length, adler32, then deflate (level 6).
/// The lengths and checksum catch truncation the inflater tolerates.
Uint8List packPayload(int version, Uint8List raw) {
  final packed = ZLibCodec(level: 6, raw: true).encode(raw);
  final out = ByteWriter()
    ..byte(version)
    ..varint(raw.length)
    ..varint(packed.length)
    ..bytes(_adler32(raw))
    ..bytes(packed);
  return out.takeBytes();
}

/// Inverse of [packPayload]; throws [ArchiveFormatException] on any damage.
Uint8List unpackPayload(int version, Uint8List data, String what) {
  final head = ByteReader(data);
  final v = head.byte();
  if (v != version) {
    throw ArchiveFormatException('unknown $what version $v');
  }
  final rawLen = head.varint();
  final packedLen = head.varint();
  final sum = head.bytes(4);
  if (head.remaining != packedLen) {
    throw ArchiveFormatException('truncated $what');
  }
  final Uint8List raw;
  try {
    raw = Uint8List.fromList(
      ZLibCodec(raw: true).decode(Uint8List.sublistView(data, head.pos)),
    );
  } on Object {
    throw ArchiveFormatException('corrupt $what');
  }
  final actual = _adler32(raw);
  var same = raw.length == rawLen;
  for (var i = 0; i < 4; i++) {
    same = same && actual[i] == sum[i];
  }
  if (!same) {
    throw ArchiveFormatException('corrupt $what');
  }
  return raw;
}

Uint8List _adler32(Uint8List data) {
  var a = 1;
  var b = 0;
  for (final x in data) {
    a = (a + x) % 65521;
    b = (b + a) % 65521;
  }
  return Uint8List.fromList([b >> 8, b & 255, a >> 8, a & 255]);
}
