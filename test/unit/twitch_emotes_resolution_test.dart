import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/services/emote_providers/twitch_emotes.dart';

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

void main() {
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

    test('low uses the smallest scale and no urlLarge', () async {
      final result = await fetchGlobal(EmoteResolution.low);
      expect(result.single.url, _url('1', '1.0'));
      expect(result.single.urlLarge, isNull);
    });

    test('medium uses the 2.0 scale and no urlLarge', () async {
      final result = await fetchGlobal(EmoteResolution.medium);
      expect(result.single.url, _url('1', '2.0'));
      expect(result.single.urlLarge, isNull);
    });

    test('high uses 2.0 and the largest (3.0) urlLarge', () async {
      final result = await fetchGlobal(EmoteResolution.high);
      expect(result.single.url, _url('1', '2.0'));
      expect(result.single.urlLarge, _url('1', '3.0'));
    });

    test('low falls back to the smallest available scale', () async {
      final result = await fetchGlobal(
        EmoteResolution.low,
        data: [
          _emoteJson('2', ['3.0']),
        ],
      );
      expect(result.single.url, _url('2', '3.0'));
      expect(result.single.urlLarge, isNull);
    });
  });
}
