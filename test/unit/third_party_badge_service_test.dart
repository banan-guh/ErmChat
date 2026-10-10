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

      // At most one lookup every 2 seconds, however fast users arrive.
      service.resolveBadge('c');
      async.elapse(const Duration(milliseconds: 300));
      service.resolveBadge('d');
      async.elapse(const Duration(milliseconds: 900));
      expect(lookups, hasLength(1), reason: 'lookups within 2s');
      async.elapse(const Duration(seconds: 1));
      expect(lookups, hasLength(2));
      expect(lookups.last, ['c', 'd']);
      lookups.removeLast();

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

  test('Chatterino, DankChat, Chatsen and Homies lists parse and rank', () async {
    // Trimmed real payloads from each provider's badge endpoint.
    final bodies = {
      'api.chatterino.com': jsonEncode({
        'badges': [
          {
            'tooltip': 'Chatterino Top Donator',
            'image1': 'https://fourtf.com/chatterino/badges/topd.png',
            'image2': 'https://fourtf.com/chatterino/badges/topd2x.png',
            'image3': 'https://fourtf.com/chatterino/badges/topd3x.png',
            'users': ['241105451', 'both'],
          },
        ],
      }),
      'flxrs.com': jsonEncode([
        {
          'type': 'DuckerZ',
          'url': 'https://flxrs.com/dankchat/badges/ente.gif',
          'users': ['147950640', 'both'],
        },
      ]),
      'api.chatsen.app': jsonEncode([
        {
          'id': '7313273',
          'name': 'Chatsen Patreon: Tier 1',
          'description': null,
          'mipmap': [
            'https://raw.githubusercontent.com/chatsen/resources/master/assets/tier1.png',
          ],
          'users': ['73250113'],
        },
      ]),
      'chatterinohomies.com': jsonEncode({
        'badges': [
          {
            'badgeFileType': 'image/webp',
            'badgeId': '68d98dd23d60203ffbfdce6a',
            'image1':
                'https://cdn.chatterinohomies.com/badges/90b5d49e/18.webp',
            'image2':
                'https://cdn.chatterinohomies.com/badges/90b5d49e/36.webp',
            'image3':
                'https://cdn.chatterinohomies.com/badges/90b5d49e/72.webp',
            'tooltip': 'usVesper Badge',
            'userId': '95700563',
            'username': 'usVesper',
          },
        ],
      }),
      'itzalex.github.io/badges2': jsonEncode({
        'badges': [
          {
            'tooltip': 'Homies Supporter',
            'image1':
                'https://itzalex.github.io/badgesusers/supporter/badge.png',
            'users': [''],
          },
        ],
      }),
    };
    final service = ThirdPartyBadgeService(
      client: MockClient(
        (req) async => http.Response(
          bodies['${req.url.host}${req.url.path}'] ??
              bodies[req.url.host] ??
              '',
          200,
        ),
      ),
    );
    addTearDown(service.dispose);
    await service.fetchListBadges();

    expect(service.resolveBadge('241105451'), (
      url: 'https://fourtf.com/chatterino/badges/topd.png',
      name: 'Chatterino Top Donator',
    ));
    expect(service.resolveBadge('147950640'), (
      url: 'https://flxrs.com/dankchat/badges/ente.gif',
      name: 'DuckerZ',
    ));
    expect(
      service.resolveBadge('73250113')?.url,
      'https://raw.githubusercontent.com/chatsen/resources/master/assets/tier1.png',
    );
    expect(
      service.resolveBadge('both')?.name,
      'Chatterino Top Donator',
      reason: 'Chatterino outranks DankChat',
    );
    expect(service.resolveBadge('95700563'), (
      url: 'https://cdn.chatterinohomies.com/badges/90b5d49e/18.webp',
      name: 'usVesper Badge',
    ));
    expect(
      service.resolveBadge(''),
      isNull,
      reason: 'blank user ids in a Homies list',
    );
  });
}
