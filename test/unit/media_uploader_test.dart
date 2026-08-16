import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ermchat/services/media_uploader.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

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
      final file = await _tempFile();

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
      final file = await _tempFile();

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
      final file = await _tempFile();

      final result = await uploader.uploadMedia(file);

      expect(result.imageLink, 'https://kappa.lol/raw');
      expect(result.deleteLink, isNull);
    });

    test('throws on non-2xx responses', () async {
      final uploader = MediaUploader(
        client: MockClient((_) async => http.Response('oops', 500)),
      );
      final file = await _tempFile();

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

Future<File> _tempFile() async {
  final dir = await Directory.systemTemp.createTemp('ermchat_test');
  final file = File('${dir.path}/image.png');
  await file.writeAsBytes([0x89, 0x50, 0x4E, 0x47]);
  return file;
}
