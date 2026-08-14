import 'dart:convert';
import 'dart:typed_data';

/// Builds a minimal GIF89a with one pixel per frame.
///
/// [pixels] is one LZW pixel index per frame (0 or 1 from the 2-color global
/// table: index 0 = opaque red, index 1 = the transparent-index slot).
/// [transparent] marks which frames carry a transparency-enabled Graphic
/// Control Extension (flag bit 0, per the GIF89a spec). [delays] is per-frame
/// delay in centiseconds.
Uint8List buildTestGif({
  required List<int> pixels,
  List<bool>? transparent,
  List<int>? delays,
  int width = 1,
  int height = 1,
}) {
  final b = BytesBuilder();
  b.add(ascii.encode('GIF89a'));
  b.add(<int>[
    width & 0xFF,
    (width >> 8) & 0xFF,
    height & 0xFF,
    (height >> 8) & 0xFF,
    0x80, // global color table, 2^(0+1) entries
    0x00, // background index
    0x00, // aspect ratio
  ]);
  b.add(const <int>[0xFF, 0x00, 0x00, 0x00, 0x00, 0x00]); // red, black

  const lzwForPixel = <int, List<int>>{
    0: <int>[0x44, 0x01],
    1: <int>[0x4C, 0x01],
  };

  for (var i = 0; i < pixels.length; i++) {
    final isTransparent = transparent != null && transparent[i];
    final gcePacked = (isTransparent ? 0x01 : 0x00);
    final delay = delays != null ? delays[i] : 0;
    b.add(<int>[
      0x21,
      0xF9,
      0x04,
      gcePacked,
      delay & 0xFF,
      (delay >> 8) & 0xFF,
      0x01,
      0x00,
    ]);
    b.add(<int>[
      0x2C,
      0x00,
      0x00,
      0x00,
      0x00,
      width & 0xFF,
      (width >> 8) & 0xFF,
      height & 0xFF,
      (height >> 8) & 0xFF,
      0x00,
    ]);
    b.add(<int>[0x02]); // LZW min code size
    b.add(const <int>[0x02]); // sub-block length
    b.add(lzwForPixel[pixels[i]]!);
    b.add(const <int>[0x00]); // sub-block terminator
  }
  b.add(const <int>[0x3B]); // trailer
  return b.toBytes();
}
