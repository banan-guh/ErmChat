import 'dart:async';
import 'dart:typed_data';

import 'package:ermchat/widgets/image_embed_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Cache that never holds anything and records every write.
class _NoCache implements BaseCacheManager {
  final puts = <String>[];

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    // putFile returns a package:file File; a failed write stands in for it.
    if (invocation.memberName == #putFile) {
      puts.add(invocation.positionalArguments.first as String);
      return Future<Never>.error(UnimplementedError());
    }
    return super.noSuchMethod(invocation);
  }
}

// 1x1 PNG.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

// First bytes of an MP4: size, then 'ftyp'.
final _mp4Head = Uint8List.fromList([
  0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D, //
]);

void main() {
  late _NoCache cache;

  // Stream events land in microtasks; the second pump paints their setState.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  setUp(() {
    cache = _NoCache();
    ImageEmbedPreview.debugClearRecent();
  });

  Future<StreamController<List<int>>> pumpPreview(
    WidgetTester tester, {
    required String contentType,
    int? contentLength,
  }) async {
    final body = StreamController<List<int>>();
    // Not awaited: a cancelled stream's close never completes.
    addTearDown(() => unawaited(body.close()));
    final client = MockClient.streaming(
      (_, _) async => http.StreamedResponse(
        body.stream,
        200,
        headers: {'content-type': contentType},
        contentLength: contentLength,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImageEmbedPreview(
            url: 'https://kappa.lol/abc',
            maxWidth: 300,
            maxHeight: 120,
            client: client,
            cache: cache,
          ),
        ),
      ),
    );
    await tester.pump();
    return body;
  }

  testWidgets('a video content type is rejected before any bytes', (
    tester,
  ) async {
    final body = await pumpPreview(tester, contentType: 'video/mp4');
    expect(body.hasListener, isFalse);
    expect(find.textContaining('video/mp4'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('an untyped video is rejected on its first bytes', (
    tester,
  ) async {
    final body = await pumpPreview(
      tester,
      contentType: 'application/octet-stream',
      contentLength: 10000000,
    );
    body.add(_mp4Head);
    await settle(tester);
    expect(body.hasListener, isFalse);
    expect(find.textContaining("Can't preview"), findsOneWidget);
  });

  testWidgets('counts progress, then shows the image', (tester) async {
    final body = await pumpPreview(
      tester,
      contentType: 'image/png',
      contentLength: _png.length * 2,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    body.add(_png);
    await settle(tester);
    expect(find.text('50%'), findsOneWidget);

    body.add(Uint8List(_png.length));
    unawaited(body.close());
    await settle(tester);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(cache.puts, ['https://kappa.lol/abc']);
  });

  testWidgets('reopening a loaded embed skips the loading box', (tester) async {
    final body = await pumpPreview(
      tester,
      contentType: 'image/png',
      contentLength: _png.length,
    );
    body.add(_png);
    unawaited(body.close());
    await settle(tester);
    expect(find.byType(Image), findsOneWidget);

    // Collapse and expand again: the first frame already shows the image.
    await tester.pumpWidget(const SizedBox());
    await pumpPreview(tester, contentType: 'image/png');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(Image), findsOneWidget);
  });

  test('content types', () {
    expect(embedTypeMayBeImage('image/gif'), isTrue);
    expect(embedTypeMayBeImage(''), isTrue);
    expect(embedTypeMayBeImage('application/octet-stream'), isTrue);
    expect(embedTypeMayBeImage('video/mp4'), isFalse);
    expect(embedTypeMayBeImage('text/html; charset=utf-8'), isFalse);
  });

  test('byte sniff', () {
    expect(sniffEmbedImage(_png), isTrue);
    expect(sniffEmbedImage(_mp4Head), isFalse);
    expect(sniffEmbedImage(Uint8List(4)), isNull);
  });
}
