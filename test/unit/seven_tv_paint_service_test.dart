import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/seven_tv_event_client.dart';
import 'package:ermchat/services/seven_tv_paint_service.dart';
import 'package:ermchat/widgets/chat_message_tile.dart';
import 'package:ermchat/widgets/painted_username_text.dart';

Map<String, dynamic> _paintItem(
  String id,
  String name,
  Map<String, dynamic> data,
) => {'id': id, 'name': name, 'data': data};

final _linearData = {
  'layers': [
    {
      'opacity': 1.0,
      'ty': {
        '__typename': 'PaintLayerTypeLinearGradient',
        'angle': 180,
        'repeating': false,
        'stops': [
          {
            'at': 0.0,
            'color': {'hex': '#FF0000FF'},
          },
          // Duplicate position: a hard edge the renderer must keep.
          {
            'at': 0.5,
            'color': {'hex': '#00FF00FF'},
          },
          {
            'at': 0.5,
            'color': {'hex': '#0000FFFF'},
          },
          {
            'at': 1.0,
            'color': {'hex': '#FFFFFFFF'},
          },
        ],
      },
    },
  ],
  'shadows': [
    {
      'blur': 0.1,
      'offsetX': 1.0,
      'offsetY': -1.0,
      'color': {'hex': '#10203040'},
    },
  ],
};

final _solidData = {
  'layers': [
    {
      'opacity': 0.8,
      'ty': {
        '__typename': 'PaintLayerTypeSingleColor',
        'color': {'hex': '#ABCDEF01'},
      },
    },
  ],
  'shadows': [],
};

String _catalogQueryResponse(List<Map<String, dynamic>> items) => jsonEncode({
  'data': {
    'paints': {'paints': items},
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SevenTvPaintService catalog parsing', () {
    test('parses linear gradients with stops and shadows', () async {
      final queries = <String>[];
      final service = SevenTvPaintService(
        gqlQuery: (query) async {
          queries.add(query);
          return jsonDecode(
                _catalogQueryResponse([_paintItem('p1', 'Test', _linearData)]),
              )['data']
              as Map<String, dynamic>;
        },
      );

      await service.ensureCatalog();
      service
        ..enabled = true
        ..assignForTesting('111', 'p1');

      final paint = service.lookup('111');
      expect(paint, isNotNull);
      expect(paint!.name, 'Test');
      expect(paint.layers.single, isA<SevenTvLinearGradientLayer>());
      final linear = paint.layers.single as SevenTvLinearGradientLayer;
      expect(linear.angleDegrees, 180);
      expect(linear.stops.map((s) => s.at), [0.0, 0.5, 0.5, 1.0]);
      // Duplicate positions are kept so the shader renders a hard edge.
      expect(linear.stops[1].color, const Color(0xFF00FF00));
      expect(paint.shadows.single.color, const Color(0x40102030));

      final shader = service.shaderFor(paint, const Size(100, 20));
      expect(shader, isNotNull);
      service.dispose();
    });

    test('solid paints expose a solid color shortcut', () async {
      final service = SevenTvPaintService(
        gqlQuery: (_) async =>
            jsonDecode(
                  _catalogQueryResponse([
                    _paintItem('p2', 'Solid', _solidData),
                  ]),
                )['data']
                as Map<String, dynamic>,
      );
      await service.ensureCatalog();
      service.enabled = true;
      service.assignForTesting('222', 'p2');

      final paint = service.lookup('222')!;
      final solid = paint.solidColor!;
      // #ABCDEF01 at layer opacity .8: rgb channels kept, alpha multiplied.
      expect(solid.r, closeTo(0xAB / 255, 0.001));
      expect(solid.g, closeTo(0xCD / 255, 0.001));
      expect(solid.b, closeTo(0xEF / 255, 0.001));
      expect(solid.a, closeTo((1 / 255) * 0.8, 0.0005));
      service.dispose();
    });
  });

  group('SevenTvPaintService user resolution', () {
    test('resolves batched users and stays idle while disabled', () async {
      var queried = false;
      final disabled = SevenTvPaintService(
        gqlQuery: (_) async {
          queried = true;
          return null;
        },
      );
      expect(disabled.lookup('111'), isNull);
      await disabled.flushForTesting();
      expect(queried, isFalse);
      disabled.dispose();

      var queryCount = 0;
      late DateTime clock;
      clock = DateTime(2026, 1, 1);
      final service = SevenTvPaintService(
        gqlQuery: (query) async {
          queryCount++;
          expect(query, contains('{ users {'));
          expect(
            query,
            contains(
              'u0: userByConnection(platform: TWITCH, platformId: "111")',
            ),
          );
          expect(
            query,
            contains(
              'u1: userByConnection(platform: TWITCH, platformId: "222")',
            ),
          );
          return {
            'users': {
              'u0': {
                'style': {
                  'activePaint': {'id': 'p1'},
                },
              },
              'u1': null,
            },
          };
        },
        now: () => clock,
      );
      service
        ..addPaintForTesting(
          const SevenTvPaint(id: 'p1', name: 'Known', layers: [], shadows: []),
        )
        ..enabled = true;

      // Both unknown: lookups queue, flush resolves them.
      expect(service.lookup('111'), isNull);
      expect(service.lookup('222'), isNull);
      await service.flushForTesting();

      expect(service.lookup('111')!.id, 'p1');
      expect(service.lookup('222'), isNull);

      // Negative cache: no new request inside the TTL window.
      final countAfterFirstPass = queryCount;
      clock = clock.add(const Duration(minutes: 10));
      expect(service.lookup('222'), isNull);
      await service.flushForTesting();
      expect(queryCount, countAfterFirstPass);
      service.dispose();
    });
  });

  group('SevenTvEventClient entitlement dispatches', () {
    test('surfaces paint and emote set entitlements with twitch ids', () async {
      final client = SevenTvEventClient();
      final events = <SevenTvEntitlementEvent>[];
      client.onEntitlement.listen(events.add);

      client.handleRawMessage({
        'op': 0,
        'd': {
          'type': 'entitlement.create',
          'body': {
            'object': {
              'kind': 'PAINT',
              'ref_id': 'paint-1',
              'user': {
                'connections': [
                  {'platform': 'TWITCH', 'id': '71092938'},
                  {'platform': 'KICK', 'id': '42'},
                ],
              },
            },
          },
        },
      });
      client.handleRawMessage({
        'op': 0,
        'd': {
          'type': 'entitlement.delete',
          'body': {
            'object': {
              'kind': 'EMOTE_SET',
              'ref_id': 'set-1',
              'user': {
                'connections': [
                  {'platform': 'TWITCH', 'id': '27237403'},
                ],
              },
            },
          },
        },
      });
      client.handleRawMessage({
        'op': 0,
        'd': {
          'type': 'entitlement.create',
          'body': {
            'object': {
              'kind': 'EMOTE_SET',
              'ref_id': 'personal-set-1',
              'user': {
                'connections': [
                  {'platform': 'TWITCH', 'id': '71092938'},
                ],
              },
            },
          },
        },
      });

      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(3));
      const cases = [
        ('PAINT', 'entitlement.create', 'paint-1', ['71092938']),
        ('EMOTE_SET', 'entitlement.delete', 'set-1', ['27237403']),
        ('EMOTE_SET', 'entitlement.create', 'personal-set-1', ['71092938']),
      ];
      for (var i = 0; i < cases.length; i++) {
        final (cosmeticKind, kind, cosmeticId, twitchIds) = cases[i];
        expect(events[i].cosmeticKind, cosmeticKind, reason: 'event $i');
        expect(events[i].kind, kind, reason: 'event $i');
        expect(events[i].cosmeticId, cosmeticId, reason: 'event $i');
        expect(events[i].twitchUserIds, twitchIds, reason: 'event $i');
      }
      client.dispose();
    });

    test('service applies live paint entitlements to lookups', () async {
      final client = SevenTvEventClient();
      final service = SevenTvPaintService(gqlQuery: (_) async => null)
        ..addPaintForTesting(
          const SevenTvPaint(id: 'p9', name: 'Live', layers: [], shadows: []),
        )
        ..enabled = true;
      service.bindSevenTvEvents(client);

      client.handleRawMessage({
        'op': 0,
        'd': {
          'type': 'entitlement.create',
          'body': {
            'object': {
              'kind': 'PAINT',
              'ref_id': 'p9',
              'user': {
                'connections': [
                  {'platform': 'TWITCH', 'id': '555'},
                ],
              },
            },
          },
        },
      });
      await Future<void>.delayed(Duration.zero);

      expect(service.lookup('555')!.name, 'Live');
      service.dispose();
      client.dispose();
    });
  });

  group('ChatMessageTile painted username', () {
    TwitchMessage message(String userId) => TwitchMessage(
      login: 'paintuser',
      displayName: 'PaintUser',
      text: 'hello',
      userId: userId,
      color: '#FF0000',
      messageId: 'm-$userId',
    );

    ChatMessageTile tile(TwitchMessage msg, SevenTvPaintService? paints) =>
        ChatMessageTile(
          message: msg,
          channel: 'chan',
          surface: Colors.black,
          textScale: 1.0,
          buildBadgeSpans: (_, _, {badgeScale = 1.0}) => [],
          buildMessageSpans: (_, _, _, {colored = false, textScale = 1.0}) => [
            TextSpan(text: msg.text),
          ],
          paintService: paints,
        );

    testWidgets('renders plain span when the feature is off', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: tile(message('999'), null))),
      );
      expect(find.byType(PaintedUsernameText), findsNothing);
      expect(find.byType(ShaderMask), findsNothing);
    });

    testWidgets('routes painted usernames through the gradient widget', (
      tester,
    ) async {
      final service = SevenTvPaintService(gqlQuery: (_) async => null)
        ..enabled = true;
      service
        ..addPaintForTesting(
          SevenTvPaint(
            id: 'g1',
            name: 'Grad',
            layers: [
              SevenTvLinearGradientLayer(
                stops: const [
                  SevenTvPaintStop(at: 0, color: Colors.red),
                  SevenTvPaintStop(at: 1, color: Colors.blue),
                ],
                angleDegrees: 90,
                repeating: false,
                opacity: 1,
              ),
            ],
            shadows: const [],
          ),
        )
        ..assignForTesting('888', 'g1');

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: tile(message('777'), service))),
      );
      // Let the queued batch flush timer fire so teardown has no pending
      // timers.
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PaintedUsernameText), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: tile(message('888'), service))),
      );
      await tester.pump();

      expect(find.byType(PaintedUsernameText), findsOneWidget);
      expect(find.byType(ShaderMask), findsOneWidget);
      service.dispose();
    });
  });
}
