import 'dart:io';
import 'dart:typed_data';

import 'package:ermchat/services/media_uploader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

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

  Future<File> tempUploadFile() async {
    final dir = await Directory.systemTemp.createTemp('ermchat_upload_test');
    final file = File('${dir.path}/image.png');
    await file.writeAsBytes([0x89, 0x50, 0x4E, 0x47]);
    return file;
  }

  group('UploaderConfig', () {
    test('parses semicolon-separated headers', () {
      const config = UploaderConfig(
        uploadUrl: 'https://example.com/upload',
        formField: 'file',
        headers: 'X-A: 1; X-B:two; garbage; X-C: three ',
      );
      expect(config.parsedHeaders, [
        (name: 'X-A', value: '1'),
        (name: 'X-B', value: 'two'),
        (name: 'X-C', value: 'three'),
      ]);
    });

    test('round-trips through json', () {
      const config = UploaderConfig(
        uploadUrl: 'https://example.com/upload',
        formField: 'file',
        headers: 'X-A: 1',
        imageLinkPattern: '{link}',
        deletionLinkPattern: '{delete}',
      );
      expect(
        UploaderConfig.fromJson(config.toJson()).uploadUrl,
        config.uploadUrl,
      );
      expect(
        UploaderConfig.fromJson(config.toJson()).deletionLinkPattern,
        '{delete}',
      );
    });

    test('missing fields fall back to defaults', () {
      final config = UploaderConfig.fromJson(const {});
      expect(config.uploadUrl, UploaderConfig.defaultConfig.uploadUrl);
      expect(config.formField, UploaderConfig.defaultConfig.formField);
    });
  });

  group('MediaUploader.uploadMedia', () {
    test('parses {link} pattern from kappa.lol response', () async {
      final uploader = MediaUploader(
        client: MockClient((request) async {
          expect(request.url.toString(), 'https://kappa.lol/api/upload');
          expect(request.headers['User-Agent'], 'ermchat');
          return http.Response(
            '{"id":"abc","link":"https://kappa.lol/abc","delete":"https://kappa.lol/delete?key"}',
            200,
          );
        }),
      );
      final file = await tempUploadFile();

      final result = await uploader.uploadMedia(file);

      expect(result.imageLink, 'https://kappa.lol/abc');
      expect(result.deleteLink, 'https://kappa.lol/delete?key');
    });

    test('substitutes nested pattern tokens', () async {
      final uploader = MediaUploader(
        client: MockClient(
          (_) async => http.Response('{"id":"abc","ext":".png"}', 200),
        ),
      );
      await uploader.saveConfig(
        const UploaderConfig(
          uploadUrl: 'https://example.com/upload',
          formField: 'file',
          imageLinkPattern: 'https://example.com/{id}{ext}',
          deletionLinkPattern: '{delete}',
        ),
      );
      final file = await tempUploadFile();

      final result = await uploader.uploadMedia(file);

      expect(result.imageLink, 'https://example.com/abc.png');
      expect(result.deleteLink, isNull);
    });

    test('uses raw body when no image link pattern is set', () async {
      final uploader = MediaUploader(
        client: MockClient(
          (_) async => http.Response('https://kappa.lol/raw', 200),
        ),
      );
      await uploader.saveConfig(
        const UploaderConfig(
          uploadUrl: 'https://example.com/upload',
          formField: 'file',
          imageLinkPattern: null,
        ),
      );
      final file = await tempUploadFile();

      final result = await uploader.uploadMedia(file);

      expect(result.imageLink, 'https://kappa.lol/raw');
      expect(result.deleteLink, isNull);
    });

    test('throws on non-2xx responses', () async {
      final uploader = MediaUploader(
        client: MockClient((_) async => http.Response('oops', 500)),
      );
      final file = await tempUploadFile();

      expect(uploader.uploadMedia(file), throwsA(isA<HttpException>()));
    });
  });

  group('MediaUploader config persistence', () {
    test('loads default config when nothing is stored', () async {
      final uploader = MediaUploader(
        client: MockClient((_) async => http.Response('', 200)),
      );
      final config = await uploader.loadConfig();
      expect(config.uploadUrl, 'https://kappa.lol/api/upload');
    });

    test('save then load round-trips', () async {
      final uploader = MediaUploader(
        client: MockClient((_) async => http.Response('', 200)),
      );
      const config = UploaderConfig(
        uploadUrl: 'https://example.com/upload',
        formField: 'file',
        headers: 'X-A: 1',
        imageLinkPattern: '{link}',
        deletionLinkPattern: '{delete}',
      );
      await uploader.saveConfig(config);

      final loaded = await uploader.loadConfig();
      expect(loaded.uploadUrl, 'https://example.com/upload');
      expect(loaded.headers, 'X-A: 1');
    });

    test('reset restores kappa.lol defaults', () async {
      final uploader = MediaUploader(
        client: MockClient((_) async => http.Response('', 200)),
      );
      await uploader.saveConfig(
        const UploaderConfig(uploadUrl: 'https://example.com', formField: 'x'),
      );
      await uploader.resetConfig();

      final loaded = await uploader.loadConfig();
      expect(loaded.uploadUrl, 'https://kappa.lol/api/upload');
      expect(loaded.formField, 'file');
    });
  });

  group('MediaUploader recent uploads', () {
    test('addRecent inserts at the front and caps the list', () async {
      final uploader = MediaUploader(
        client: MockClient((_) async => http.Response('', 200)),
      );
      for (var i = 0; i < 60; i++) {
        await uploader.addRecent(
          UploadResult(imageLink: 'https://kappa.lol/$i', deleteLink: null),
        );
      }

      final uploads = await uploader.recentUploads();
      expect(uploads.length, 50);
      expect(uploads.first.imageLink, 'https://kappa.lol/59');
      expect(uploads.last.imageLink, 'https://kappa.lol/10');
    });

    test('removeRecent deletes the entry at the index', () async {
      final uploader = MediaUploader(
        client: MockClient((_) async => http.Response('', 200)),
      );
      await uploader.addRecent(const UploadResult(imageLink: 'a'));
      await uploader.addRecent(const UploadResult(imageLink: 'b'));

      await uploader.removeRecent(0);

      final uploads = await uploader.recentUploads();
      expect(uploads.length, 1);
      expect(uploads.first.imageLink, 'a');
    });

    test('clearRecents empties the list', () async {
      final uploader = MediaUploader(
        client: MockClient((_) async => http.Response('', 200)),
      );
      await uploader.addRecent(const UploadResult(imageLink: 'a'));

      await uploader.clearRecents();

      expect(await uploader.recentUploads(), isEmpty);
    });
  });
}
