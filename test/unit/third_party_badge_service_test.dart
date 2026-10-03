import 'dart:convert';

import 'package:ermchat/services/third_party_badge_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Shape of https://api.limerino.com/v1/badges (trimmed).
final _catalog = jsonEncode({
  'badges': [
    {
      'id': 'founder',
      'kind': 'BADGE',
      'data': {
        'id': 'founder',
        'name': 'Limerino Founder',
        'tooltip': 'Limerino Founder',
        'host': {
          'url': '//api.limerino.com/v1/badges/art/founder/3',
          'files': [
            {'name': '1x.webp', 'static_name': '1x.png'},
            {'name': '2x.webp', 'static_name': '2x.png'},
            {'name': '2x.png'},
          ],
        },
      },
    },
  ],
});

void main() {
  test('Limerino badges batch lookups, cache answers, and back off', () {
    fakeAsync((async) {
      final lookups = <List<String>>[];
      var status = 200;
      final client = MockClient((req) async {
        if (req.method == 'GET') return http.Response(_catalog, 200);
        final ids = List<String>.from(
          (jsonDecode(req.body) as Map<String, dynamic>)['twitch_ids'] as List,
        );
        lookups.add(ids);
        if (status == 429) {
          return http.Response('', 429, headers: {'retry-after': '30'});
        }
        return http.Response(
          jsonEncode({
            'users': {
              'a': ['founder'],
            },
          }),
          200,
        );
      });
      final service = ThirdPartyBadgeService(
        client: client,
        now: () => DateTime(2026).add(async.elapsed),
      );
      addTearDown(service.dispose);

      // Off until the app starts it: bare renders queue nothing.
      expect(service.resolveBadge('a'), isNull);
      async.elapse(const Duration(seconds: 1));
      expect(lookups, isEmpty);

      service.fetchLimerinoBadges();
      async.flushMicrotasks();
      final before = service.version;
      service
        ..resolveBadge('a')
        ..resolveBadge('b');
      async.elapse(const Duration(milliseconds: 300));
      expect(lookups, [
        ['a', 'b'],
      ], reason: 'one batched request');
      expect(service.resolveBadge('a'), (
        url: 'https://api.limerino.com/v1/badges/art/founder/3/2x.webp',
        name: 'Limerino Founder',
      ));
      expect(service.version, greaterThan(before));

      // A miss is remembered for 30 minutes, then asked again.
      expect(service.resolveBadge('b'), isNull);
      async.elapse(const Duration(minutes: 29));
      service.resolveBadge('b');
      async.elapse(const Duration(seconds: 1));
      expect(lookups, hasLength(1));
      async.elapse(const Duration(minutes: 2));
      status = 429;
      service.resolveBadge('b');
      async.elapse(const Duration(seconds: 1));
      expect(lookups, hasLength(2));

      // 429: wait retry-after before the retry, not the batch delay.
      async.elapse(const Duration(seconds: 20));
      expect(lookups, hasLength(2), reason: 'retry-after not honored');
      status = 200;
      async.elapse(const Duration(seconds: 15));
      expect(lookups, hasLength(3));
      expect(lookups.last, ['b']);
    });
  });
}
