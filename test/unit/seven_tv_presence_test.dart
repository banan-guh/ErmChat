import 'dart:convert';

import 'package:ermchat/services/seven_tv_presence.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('presence posts once a minute per channel with a cached 7TV id', () {
    fakeAsync((async) {
      final requests = <http.Request>[];
      final client = MockClient((req) async {
        requests.add(req);
        if (req.url.path == '/v3/users/twitch/111') {
          return http.Response(
            jsonEncode({
              'user': {'id': '7tv-viewer'},
            }),
            200,
          );
        }
        if (req.url.path == '/v3/users/twitch/222') {
          return http.Response('{}', 404);
        }
        return http.Response('{}', 200);
      });
      final presence = SevenTvPresence(
        client: client,
        now: () => DateTime(2026).add(async.elapsed),
      );
      void announce(String channel, [String viewer = '111']) {
        presence.announce(channelTwitchId: channel, viewerTwitchId: viewer);
        async.flushMicrotasks();
      }

      List<String> paths() => [for (final r in requests) r.url.path];

      announce('chan');
      expect(paths(), [
        '/v3/users/twitch/111',
        '/v3/users/7tv-viewer/presences',
      ]);
      expect(jsonDecode(requests.last.body), {
        'kind': 1,
        'passive': false,
        'data': {'platform': 'TWITCH', 'id': 'chan'},
      });

      // Same channel within a minute: throttled. Another channel: sent, and
      // the 7TV id is not looked up again.
      announce('chan');
      announce('other');
      expect(paths().where((p) => p.endsWith('/presences')), hasLength(2));
      expect(paths().where((p) => p.contains('/twitch/')), hasLength(1));

      async.elapse(const Duration(seconds: 61));
      announce('chan');
      expect(paths().where((p) => p.endsWith('/presences')), hasLength(3));

      // No 7TV account: looked up once, never posted.
      announce('chan2', '222');
      async.elapse(const Duration(minutes: 6));
      announce('chan2', '222');
      expect(paths().where((p) => p.contains('/twitch/222')), hasLength(1));
      expect(paths().where((p) => p.endsWith('/presences')), hasLength(3));
    });
  });
}
