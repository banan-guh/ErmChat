import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/services/emote_providers/ffz_emotes.dart';
import 'package:ermchat/services/emote_providers/bttv_emotes.dart';
import 'package:ermchat/services/emote_providers/twitch_emotes.dart';
import 'package:ermchat/services/emote_providers/seven_tv_emotes.dart';

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

/// Provider scale-map tests. Each provider fills every quality role its API
/// exposes; the render layer picks the role.
void main() {
  tearDown(() => HttpOverrides.global = null);

  group('FfzEmoteProvider scales', () {
    const globalUrl = 'https://api.frankerfacez.com/v1/set/global';
    const base = 'https://cdn.frankerfacez.com/emote/123';

    Future<List<Emote>> fetchGlobal(Map<String, String> urls) {
      HttpOverrides.global = _FakeHttpOverrides({globalUrl: _ffzBody(urls)});
      return FfzEmoteProvider.fetchGlobal();
    }

    test('maps the 1/2/4 urls to small/medium/large', () async {
      final result = await fetchGlobal({
        '1': '$base/1',
        '2': '$base/2',
        '4': '$base/4',
      });
      final scales = result.single.scales;
      expect(scales[EmoteScale.small], '$base/1');
      expect(scales[EmoteScale.medium], '$base/2');
      expect(scales[EmoteScale.large], '$base/4');
    });

    test('fills only the scales the emote actually has', () async {
      final result = await fetchGlobal({'2': '$base/2'});
      final scales = result.single.scales;
      expect(scales[EmoteScale.medium], '$base/2');
      expect(scales.containsKey(EmoteScale.small), isFalse);
      expect(scales.containsKey(EmoteScale.large), isFalse);
    });

    test('keeps a lone 4x url as large', () async {
      final result = await fetchGlobal({'4': '$base/4'});
      expect(result.single.scales[EmoteScale.large], '$base/4');
    });

    test('global keeps only default sets', () async {
      HttpOverrides.global = _FakeHttpOverrides({
        globalUrl: jsonEncode({
          'default_sets': [1],
          'sets': {
            '1': {
              'emoticons': [
                {
                  'id': 1,
                  'name': 'Open',
                  'urls': {'1': '$base/1', '2': '$base/2'},
                },
              ],
            },
            '2': {
              'emoticons': [
                {
                  'id': 2,
                  'name': 'Gated',
                  'urls': {'1': '$base/1', '2': '$base/2'},
                },
              ],
            },
          },
        }),
      });
      final result = await FfzEmoteProvider.fetchGlobal();
      expect(result.map((e) => e.code), ['Open']);
    });

    test('animated map marks animated and prefers animated art', () async {
      const animBase = 'https://cdn.frankerfacez.com/emote/999';
      HttpOverrides.global = _FakeHttpOverrides({
        globalUrl: jsonEncode({
          'sets': {
            '1': {
              'emoticons': [
                {
                  'id': 999,
                  'name': 'Dance',
                  'animated': {'1': '$animBase/1', '2': '$animBase/2'},
                  'urls': {'1': '$base/1', '2': '$base/2'},
                },
              ],
            },
          },
        }),
      });
      final result = await FfzEmoteProvider.fetchGlobal();
      expect(result.single.isAnimated, isTrue);
      expect(result.single.scales[EmoteScale.medium], '$animBase/2');
    });

    test('fetchChannel hits the numeric room id endpoint', () async {
      const channelId = '71092938';
      const url = 'https://api.frankerfacez.com/v1/room/id/$channelId';
      HttpOverrides.global = _FakeHttpOverrides({
        url: _ffzBody({
          '1': 'https://cdn.frankerfacez.com/emote/555/1',
          '2': 'https://cdn.frankerfacez.com/emote/555/2',
          '4': 'https://cdn.frankerfacez.com/emote/555/4',
        }),
      });
      final result = await FfzEmoteProvider.fetchChannel(channelId);
      expect(result, hasLength(1));
      expect(result.single.code, 'FFZ');
      expect(
        result.single.scales[EmoteScale.medium],
        'https://cdn.frankerfacez.com/emote/555/2',
      );
      expect(result.single.scope, EmoteScope.channel);
    });

    test('fetchChannel uses the FFZ owner display name', () async {
      const channelId = '71092938';
      const url = 'https://api.frankerfacez.com/v1/room/id/$channelId';
      HttpOverrides.global = _FakeHttpOverrides({
        url: jsonEncode({
          'sets': {
            '1': {
              'emoticons': [
                {
                  'id': 555,
                  'name': 'FFZ',
                  'urls': {'1': '$base/1', '2': '$base/2'},
                  'owner': {'display_name': 'SomeCreator'},
                },
              ],
            },
          },
        }),
      });
      final result = await FfzEmoteProvider.fetchChannel(channelId);
      expect((result.single.meta as FfzMeta).ownerChannel, 'SomeCreator');
    });

    test('fetchChannel leaves ownerChannel null without an owner', () async {
      const channelId = '71092938';
      const url = 'https://api.frankerfacez.com/v1/room/id/$channelId';
      HttpOverrides.global = _FakeHttpOverrides({
        url: _ffzBody({'1': '$base/1', '2': '$base/2'}),
      });
      final result = await FfzEmoteProvider.fetchChannel(channelId);
      expect((result.single.meta as FfzMeta).ownerChannel, isNull);
    });
  });

  group('BttvEmoteProvider scales', () {
    const globalUrl = 'https://api.betterttv.net/3/cached/emotes/global';
    const body =
        '[{"id":"b1","code":"Pog","imageType":"png","zeroWidth":false}]';

    Future<List<Emote>> fetchGlobal() {
      HttpOverrides.global = _FakeHttpOverrides({globalUrl: body});
      return BttvEmoteProvider.fetchGlobal();
    }

    test('maps the 1x/2x/3x urls to small/medium/large', () async {
      final result = await fetchGlobal();
      final scales = result.single.scales;
      expect(scales[EmoteScale.small], 'https://cdn.betterttv.net/emote/b1/1x');
      expect(
        scales[EmoteScale.medium],
        'https://cdn.betterttv.net/emote/b1/2x',
      );
      expect(scales[EmoteScale.large], 'https://cdn.betterttv.net/emote/b1/3x');
    });

    test(
      'fetchChannel hits the users/twitch endpoint and parses both lists',
      () async {
        const channelId = '71092938';
        const url =
            'https://api.betterttv.net/3/cached/users/twitch/$channelId';
        HttpOverrides.global = _FakeHttpOverrides({
          url: jsonEncode({
            'channelEmotes': [
              {'id': 'c1', 'code': 'ChnlBTTV', 'imageType': 'png'},
            ],
            'sharedEmotes': [
              {'id': 's1', 'code': 'Shared', 'imageType': 'gif'},
            ],
          }),
        });
        final result = await BttvEmoteProvider.fetchChannel(channelId);
        expect(result, hasLength(2));
        expect(result.any((e) => e.code == 'ChnlBTTV'), isTrue);
        expect(result.any((e) => e.code == 'Shared'), isTrue);
        expect(result.firstWhere((e) => e.code == 'Shared').isAnimated, isTrue);
      },
    );
  });

  group('TwitchEmoteProvider scales', () {
    const globalUrl = 'https://api.twitch.tv/helix/chat/emotes/global';

    Future<List<Emote>> fetchGlobal({List<Map<String, dynamic>>? data}) {
      HttpOverrides.global = _FakeHttpOverrides({
        globalUrl: jsonEncode({
          'data':
              data ??
              [
                _emoteJson('1', ['1.0', '2.0', '3.0']),
              ],
        }),
      });
      return TwitchEmoteProvider.fetchGlobal();
    }

    test('maps the 1.0/2.0/3.0 scales to small/medium/large', () async {
      final result = await fetchGlobal();
      final scales = result.single.scales;
      expect(scales[EmoteScale.small], _url('1', '1.0'));
      expect(scales[EmoteScale.medium], _url('1', '2.0'));
      expect(scales[EmoteScale.large], _url('1', '3.0'));
    });

    test('keeps only the smallest available scale', () async {
      final result = await fetchGlobal(
        data: [
          _emoteJson('2', ['3.0']),
        ],
      );
      final scales = result.single.scales;
      expect(scales[EmoteScale.large], _url('2', '3.0'));
      expect(scales.containsKey(EmoteScale.small), isFalse);
      expect(scales.containsKey(EmoteScale.medium), isFalse);
    });

    test('maps tier and emote_type to TwitchEmoteKind', () async {
      Map<String, dynamic> item(
        String id,
        String name, {
        String? tier,
        String? emoteType,
      }) => {
        'id': id,
        'name': name,
        'format': ['static'],
        'scale': ['2.0'],
        'theme_mode': ['light'],
        'tier': ?tier,
        'emote_type': ?emoteType,
      };

      final result = await fetchGlobal(
        data: [
          item('s', 'Sub', tier: '3', emoteType: 'subscriptions'),
          item('f', 'Follower', emoteType: 'follower'),
          item('b', 'Bits', emoteType: 'bitstier'),
          item('p', 'Prime', emoteType: 'prime'),
          item('d', 'Default'),
          item('t', 'TierOnly', tier: 'notanumber'),
        ],
      );

      TwitchMeta metaOf(String code) =>
          result.firstWhere((e) => e.code == code).meta as TwitchMeta;

      expect(metaOf('Sub').kind, TwitchEmoteKind.sub);
      expect(metaOf('Sub').subTier, 3);
      expect(metaOf('Follower').kind, TwitchEmoteKind.follower);
      expect(metaOf('Bits').kind, TwitchEmoteKind.bits);
      expect(metaOf('Prime').kind, TwitchEmoteKind.standard);
      expect(metaOf('Default').kind, TwitchEmoteKind.standard);
      expect(metaOf('TierOnly').kind, TwitchEmoteKind.sub);
      expect(metaOf('TierOnly').subTier, isNull);
    });
  });

  group('TwitchEmoteProvider global unlockables', () {
    const unlockUrl =
        'https://api.twitch.tv/helix/chat/emotes?broadcaster_id=0';

    Future<List<Emote>> fetchUnlockable() {
      HttpOverrides.global = _FakeHttpOverrides({
        unlockUrl: jsonEncode({
          'data': [
            {
              'id': 'prime1',
              'name': 'PrimePride',
              'format': ['static'],
              'scale': ['1.0', '2.0', '3.0'],
              'theme_mode': ['light'],
              'emote_type': 'prime',
            },
          ],
        }),
      });
      return TwitchEmoteProvider.fetchGlobalUnlockable();
    }

    test('parses unlockables as global emotes', () async {
      final result = await fetchUnlockable();
      expect(result, hasLength(1));
      final emote = result.single;
      expect(emote.code, 'PrimePride');
      expect(emote.scope, EmoteScope.global);
      expect((emote.meta as TwitchMeta).kind, TwitchEmoteKind.standard);
      expect(emote.scales[EmoteScale.medium], _url('prime1', '2.0'));
    });
  });

  group('SevenTvEmoteProvider scales', () {
    Map<String, dynamic> emote(List<String> names) => {
      'id': 'stv-1',
      'name': 'Sized',
      'data': {
        'name': 'Sized',
        'host': {
          'url': '//cdn.7tv.app/emote/sized',
          'files': [
            for (final n in names)
              {'name': n, 'format': 'WEBP', 'width': 32, 'height': 32},
          ],
        },
      },
    };

    const base = 'https://cdn.7tv.app/emote/sized';

    test('maps 1x/2x/4x to small/medium/large', () {
      final emotes = SevenTvEmoteProvider.parseSingleEmote(
        emote(['1x.webp', '2x.webp', '4x.webp']),
      );
      expect(emotes, isNotNull);
      final scales = emotes!.scales;
      expect(scales[EmoteScale.small], '$base/1x.webp');
      expect(scales[EmoteScale.medium], '$base/2x.webp');
      expect(scales[EmoteScale.large], '$base/4x.webp');
      expect(scales.values.any((url) => url.contains('3x')), isFalse);
    });

    test('uses 3x as large when no 4x exists', () {
      final emote3x = SevenTvEmoteProvider.parseSingleEmote(
        emote(['1x.webp', '2x.webp', '3x.webp']),
      );
      expect(emote3x, isNotNull);
      expect(emote3x!.scales[EmoteScale.large], '$base/3x.webp');
    });

    test('keeps an emote without a 2x file', () {
      final noMedium = SevenTvEmoteProvider.parseSingleEmote(
        emote(['1x.webp', '4x.webp']),
      );
      expect(noMedium, isNotNull);
      expect(noMedium!.scales[EmoteScale.small], '$base/1x.webp');
      expect(noMedium.scales[EmoteScale.large], '$base/4x.webp');
      expect(noMedium.scales.containsKey(EmoteScale.medium), isFalse);
    });
  });
}
