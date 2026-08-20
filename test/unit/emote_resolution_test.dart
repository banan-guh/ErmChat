import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/services/emote_providers/ffz_emotes.dart';
import 'package:ermchat/services/emote_providers/bttv_emotes.dart';
import 'package:ermchat/services/emote_providers/twitch_emotes.dart';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:ermchat/services/emote_codec/native_emote_codec.dart';
import 'package:ermchat/widgets/emote_image.dart';

class _FakeHttpOverrides extends HttpOverrides {
  final Map<String, String> responses;
  _FakeHttpOverrides(this.responses);

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(responses);
}

class _FakeHttpClient implements HttpClient {
  final Map<String, String> responses;
  _FakeHttpClient(this.responses);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeHttpClientRequest(responses[url.toString()] ?? '');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this.body);

  final String body;
  final _FakeHttpHeaders _headers = _FakeHttpHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  int contentLength = 0;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  bool persistentConnection = true;

  @override
  Future<HttpClientResponse> addStream(Stream<List<int>> stream) async {
    await stream.drain<void>();
    return _FakeHttpClientResponse(body);
  }

  @override
  Future<HttpClientResponse> close() async => _FakeHttpClientResponse(body);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientResponse implements HttpClientResponse {
  _FakeHttpClientResponse(this.body);

  final String body;

  @override
  int get statusCode => 200;

  @override
  int get contentLength => body.length;

  @override
  HttpHeaders get headers => _FakeHttpHeaders();

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => true;

  @override
  String get reasonPhrase => 'OK';

  @override
  List<RedirectInfo> get redirects => [];

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = [value.toString()];
  }

  @override
  void forEach(void Function(String name, List<String> values) f) {
    _values.forEach(f);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

String _ffzBody(Map<String, String> urls) {
  return jsonEncode({
    'sets': {
      '1': {
        'emoticons': [
          {'id': 123, 'name': 'FFZ', 'animated': false, 'urls': urls},
        ],
      },
    },
  });
}

Map<String, dynamic> _emoteJson(String id, List<String> scales) {
  return {
    'id': id,
    'name': 'Emote$id',
    'format': ['static'],
    'scale': scales,
    'theme_mode': ['light'],
    'owner_id': 'owner-1',
    'tier': '3',
    'emote_type': 'subscriptions',
  };
}

String _url(String id, String scale) =>
    'https://static-cdn.jtvnw.net/emoticons/v2/$id/static/light/$scale';

/// Gated unit tests for the native libwebp decoder.
///
/// Requires the host-built shim: run `tool/build_native_linux.sh`, then
/// `EMOTE_CODEC_SO=build/native/libemote_codec.so flutter test
/// test/unit/native_emote_codec_test.dart`. Without the env var the tests
/// skip silently (the pure-Dart fallback is the default everywhere else).

Future<Uint8List> _pixels(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

int _diffCount(Uint8List a, Uint8List b) {
  var n = 0;
  final len = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < len; i += 4) {
    if (a[i] != b[i] ||
        a[i + 1] != b[i + 1] ||
        a[i + 2] != b[i + 2] ||
        a[i + 3] != b[i + 3]) {
      n++;
    }
  }
  return n;
}

void main() {
  tearDown(() => HttpOverrides.global = null);

  group('FfzEmoteProvider resolution', () {
    const globalUrl = 'https://api.frankerfacez.com/v1/set/global';
    const base = 'https://cdn.frankerfacez.com/emote/123';

    Future<List<GenericEmote>> fetchGlobal(
      EmoteResolution resolution, {
      Map<String, String>? urls,
    }) {
      HttpOverrides.global = _FakeHttpOverrides({
        globalUrl: _ffzBody(
          urls ?? {'1': '$base/1', '2': '$base/2', '4': '$base/4'},
        ),
      });
      return FfzEmoteProvider.fetchGlobal(resolution: resolution);
    }

    test('low uses the 1x url with url1x and keeps the 4x as url3x', () async {
      final result = await fetchGlobal(
        EmoteResolution.low,
        urls: {'1': '$base/1', '2': '$base/2', '4': '$base/4'},
      );
      expect(result.single.url, '$base/1');
      expect(result.single.url1x, '$base/1');
      expect(result.single.url3x, '$base/4');
    });

    test('medium uses the 2x url with url1x and the 4x url3x', () async {
      final result = await fetchGlobal(
        EmoteResolution.medium,
        urls: {'1': '$base/1', '2': '$base/2', '4': '$base/4'},
      );
      expect(result.single.url, '$base/2');
      expect(result.single.url1x, '$base/1');
      expect(result.single.url3x, '$base/4');
    });

    test('drops url1x/url3x when the emote lacks those sizes', () async {
      final result = await fetchGlobal(
        EmoteResolution.medium,
        urls: {'2': '$base/2'},
      );
      expect(result.single.url, '$base/2');
      expect(result.single.url1x, isNull);
      expect(result.single.url3x, isNull);
    });

    test('never emits a 4x url even as a fallback', () async {
      final result = await fetchGlobal(
        EmoteResolution.low,
        urls: {'4': '$base/4'},
      );
      expect(result, isEmpty);
    });
  });

  tearDown(() => HttpOverrides.global = null);

  group('BttvEmoteProvider resolution', () {
    const globalUrl = 'https://api.betterttv.net/3/cached/emotes/global';
    const body =
        '[{"id":"b1","code":"Pog","imageType":"png","zeroWidth":false}]';

    Future<List<GenericEmote>> fetchGlobal(EmoteResolution resolution) {
      HttpOverrides.global = _FakeHttpOverrides({globalUrl: body});
      return BttvEmoteProvider.fetchGlobal(resolution: resolution);
    }

    test('low uses the 1x url and no url3x', () async {
      final result = await fetchGlobal(EmoteResolution.low);
      expect(result.single.url, 'https://cdn.betterttv.net/emote/b1/1x');
      expect(result.single.url1x, 'https://cdn.betterttv.net/emote/b1/1x');
      expect(result.single.url3x, isNull);
    });

    test('medium uses the 2x url with 1x alternate and no url3x', () async {
      final result = await fetchGlobal(EmoteResolution.medium);
      expect(result.single.url, 'https://cdn.betterttv.net/emote/b1/2x');
      expect(result.single.url1x, 'https://cdn.betterttv.net/emote/b1/1x');
      expect(result.single.url3x, isNull);
    });

    test('high uses the 2x url, 1x alternate and the 3x url3x', () async {
      final result = await fetchGlobal(EmoteResolution.high);
      expect(result.single.url, 'https://cdn.betterttv.net/emote/b1/2x');
      expect(result.single.url1x, 'https://cdn.betterttv.net/emote/b1/1x');
      expect(result.single.url3x, 'https://cdn.betterttv.net/emote/b1/3x');
    });
  });

  tearDown(() => HttpOverrides.global = null);

  group('TwitchEmoteProvider resolution', () {
    const globalUrl = 'https://api.twitch.tv/helix/chat/emotes/global';

    Future<List<GenericEmote>> fetchGlobal(
      EmoteResolution resolution, {
      List<Map<String, dynamic>>? data,
    }) {
      HttpOverrides.global = _FakeHttpOverrides({
        globalUrl: jsonEncode({
          'data':
              data ??
              [
                _emoteJson('1', ['1.0', '2.0', '3.0']),
              ],
        }),
      });
      return TwitchEmoteProvider.fetchGlobal(resolution: resolution);
    }

    test('low uses the smallest scale and no url3x', () async {
      final result = await fetchGlobal(EmoteResolution.low);
      expect(result.single.url, _url('1', '1.0'));
      expect(result.single.url1x, _url('1', '1.0'));
      expect(result.single.url3x, isNull);
    });

    test('medium uses the 2.0 scale and no url3x', () async {
      final result = await fetchGlobal(EmoteResolution.medium);
      expect(result.single.url, _url('1', '2.0'));
      expect(result.single.url1x, _url('1', '1.0'));
      expect(result.single.url3x, isNull);
    });

    test('high uses 2.0, 1x alternate and the largest (3.0) url3x', () async {
      final result = await fetchGlobal(EmoteResolution.high);
      expect(result.single.url, _url('1', '2.0'));
      expect(result.single.url1x, _url('1', '1.0'));
      expect(result.single.url3x, _url('1', '3.0'));
    });

    test('low falls back to the smallest available scale', () async {
      final result = await fetchGlobal(
        EmoteResolution.low,
        data: [
          _emoteJson('2', ['3.0']),
        ],
      );
      expect(result.single.url, _url('2', '3.0'));
      expect(result.single.url1x, isNull);
      expect(result.single.url3x, isNull);
    });
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  final soPath = Platform.environment['EMOTE_CODEC_SO'];
  if (soPath == null || !File(soPath).existsSync()) {
    return;
  }

  group('NativeEmoteCodec (gated)', () {
    setUp(() {
      NativeEmoteCodec.debugLibPath = soPath;
      NativeEmoteCodec.reset();
    });
    tearDown(NativeEmoteCodec.reset);

    test('isAvailable is true when the shim loads', () {
      expect(NativeEmoteCodec.isAvailable, isTrue);
    });

    test('isAvailable is false when the library is missing', () {
      NativeEmoteCodec.debugLibPath = '/nonexistent/libemote_codec.so';
      NativeEmoteCodec.reset();
      expect(NativeEmoteCodec.isAvailable, isFalse);
    });

    test(
      'decode matches the pure-Dart reference on the kiss fixture',
      () async {
        final bytes = File('test/fixtures/7tv_kiss_2x.webp').readAsBytesSync();
        final native = await NativeEmoteCodec.decodeWebpInline(bytes);
        expect(native, isNotNull);
        final dart = await decodeWebpPureDart(bytes);

        expect(native!.frames.length, dart.frames.length);
        expect(native.frames.length, 47);
        for (var i = 0; i < native.frames.length; i++) {
          expect(
            native.frames[i].width,
            dart.frames[i].width,
            reason: 'frame $i width',
          );
          expect(
            native.frames[i].height,
            dart.frames[i].height,
            reason: 'frame $i height',
          );
          expect(
            native.durations[i],
            dart.durations[i],
            reason: 'frame $i duration',
          );
        }

        // Spot-check the first frame's pixels.
        final a = await _pixels(native.frames[0]);
        final b = await _pixels(dart.frames[0]);
        expect(_diffCount(a, b), lessThan(100));

        for (final f in native.frames) {
          f.dispose();
        }
        for (final f in dart.frames) {
          f.dispose();
        }
      },
    );

    test('garbage input returns null, not an exception', () async {
      final garbage = Uint8List.fromList(List.generate(64, (i) => i * 7));
      final result = await NativeEmoteCodec.decodeWebpInline(garbage);
      expect(result, isNull);
    });

    test('repeated decodes do not corrupt state (free-path sanity)', () async {
      final bytes = File('test/fixtures/7tv_kiss_2x.webp').readAsBytesSync();
      for (var i = 0; i < 3; i++) {
        final native = await NativeEmoteCodec.decodeWebpInline(bytes);
        expect(native, isNotNull);
        expect(native!.frames.length, 47);
        for (final f in native.frames) {
          f.dispose();
        }
      }
    });
  });
}
