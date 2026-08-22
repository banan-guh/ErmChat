import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ermchat/services/media_uploader.dart';

/// Builds a small JPEG carrying an APP1 EXIF segment with an Orientation tag
/// (6 = rotate 90 CW), spliced in right after the SOI marker.
Uint8List jpegWithExif({required int width, required int height}) {
  final base = Uint8List.fromList(
    img.encodeJpg(img.Image(width: width, height: height)),
  );
  expect(base[0], 0xFF);
  expect(base[1], 0xD8);

  const exifHeader = 'Exif\x00\x00';
  final tiff = BytesBuilder()
    ..add('II'.codeUnits) // little-endian TIFF
    ..add([0x2A, 0x00]) // magic
    ..add([0x08, 0x00, 0x00, 0x00]) // IFD0 offset
    ..add([0x01, 0x00]) // one entry
    ..add([
      0x12, 0x01, // tag 0x0112 (orientation)
      0x03, 0x00, // type SHORT
      0x01, 0x00, 0x00, 0x00, // count 1
      0x06, 0x00, 0x00, 0x00, // value 6 (rotate 90 CW)
    ])
    ..add([0x00, 0x00, 0x00, 0x00]); // no next IFD
  final payload = <int>[...exifHeader.codeUnits, ...tiff.toBytes()];
  final segmentLength = payload.length + 2;

  return Uint8List.fromList([
    ...base.take(2),
    0xFF,
    0xE1,
    segmentLength >> 8,
    segmentLength & 0xFF,
    ...payload,
    ...base.skip(2),
  ]);
}

void main() {
  group('stripExif', () {
    test('removes the EXIF segment from a JPEG', () async {
      final input = jpegWithExif(width: 4, height: 2);
      expect(String.fromCharCodes(input).contains('Exif'), isTrue);

      final output = await stripExif(input);

      expect(String.fromCharCodes(output).contains('Exif'), isFalse);
      expect(img.decodeJpg(output), isNotNull, reason: 'still a valid JPEG');
    });

    test('bakes the EXIF orientation into the pixels', () async {
      final output = await stripExif(jpegWithExif(width: 4, height: 2));

      final decoded = img.decodeJpg(output)!;
      expect(decoded.width, 2);
      expect(decoded.height, 4);
    });

    test('leaves non-JPEG bytes untouched', () async {
      final png = Uint8List.fromList([1, 2, 3, 4]);

      expect(await stripExif(png), png);
    });
  });
}
