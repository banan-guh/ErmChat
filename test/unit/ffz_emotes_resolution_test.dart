import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/services/emote_providers/ffz_emotes.dart';

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
}
