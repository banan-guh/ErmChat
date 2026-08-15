import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/services/emote_providers/bttv_emotes.dart';

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

void main() {
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
}
