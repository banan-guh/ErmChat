import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/emote_manager.dart';
import '../helpers.dart';

void main() {
  group('GenericEmote', () {
    test('creates with required fields', () {
      final e = makeTestEmote(id: '1', code: 'Kappa');
      expect(e.id, '1');
      expect(e.code, 'Kappa');
      expect(e.type, EmoteType.bttv);
      expect(e.isZeroWidth, false);
      expect(e.scope, EmoteScope.global);
      expect(e.ownerChannel, isNull);
    });

    test('creates with zero-width flag', () {
      final e = makeTestEmote(id: '2', code: 'EZ', isZeroWidth: true);
      expect(e.isZeroWidth, true);
    });

    test('creates with channel scope', () {
      final e = makeTestEmote(
        id: '3',
        code: 'Kappa',
        scope: EmoteScope.channel,
        ownerChannel: 'forsen',
      );
      expect(e.scope, EmoteScope.channel);
      expect(e.ownerChannel, 'forsen');
    });
  });

  group('GenericEmote JSON round-trip', () {
    test('serializes and deserializes', () {
      final original = makeTestEmote(
        id: 'test-id',
        code: 'TestEmote',
        type: EmoteType.sevenTv,
        isZeroWidth: true,
        scope: EmoteScope.channel,
        ownerChannel: 'testuser',
        relativeScale: 0.625,
      );
      final json = original.toJson();
      final restored = GenericEmote.fromJson(json);
      expect(restored.id, original.id);
      expect(restored.code, original.code);
      expect(restored.type, original.type);
      expect(restored.isZeroWidth, original.isZeroWidth);
      expect(restored.scope, original.scope);
      expect(restored.ownerChannel, original.ownerChannel);
      expect(restored.url, original.url);
      expect(restored.relativeScale, original.relativeScale);
    });

    test('deserializes with defaults for missing fields', () {
      final json = <String, dynamic>{
        'id': 'test-id',
        'code': 'TestEmote',
        'type': 'bttv',
        'url': 'https://example.com/test.png',
      };
      final restored = GenericEmote.fromJson(json);
      expect(restored.id, 'test-id');
      expect(restored.isZeroWidth, false);
      expect(restored.scope, EmoteScope.global);
      expect(restored.isAnimated, false);
      expect(restored.ownerChannel, isNull);
      expect(restored.relativeScale, 1.0);
    });

    test('handles all EmoteType values', () {
      for (final type in EmoteType.values) {
        final e = GenericEmote(
          id: '${type.index}',
          code: 'Test',
          type: type,
          url: '',
        );
        final json = e.toJson();
        final restored = GenericEmote.fromJson(json);
        expect(restored.type, type);
      }
    });

    test('handles all EmoteScope values', () {
      for (final scope in EmoteScope.values) {
        final e = GenericEmote(
          id: '1',
          code: 'Test',
          type: EmoteType.bttv,
          url: '',
          scope: scope,
        );
        final json = e.toJson();
        final restored = GenericEmote.fromJson(json);
        expect(restored.scope, scope);
      }
    });
  });

  group('EmotePosition', () {
    test('creates with all fields', () {
      final pos = EmotePosition(
        emoteId: '123',
        startIndex: 0,
        endIndex: 5,
        emoteCode: 'Kappa',
      );
      expect(pos.emoteId, '123');
      expect(pos.startIndex, 0);
      expect(pos.endIndex, 5);
      expect(pos.emoteCode, 'Kappa');
    });
  });

  group('EmoteManager refresh policy', () {
    test('cellular connection gets the longer 48h TTL', () async {
      final manager = EmoteManager(
        probe: () async => [ConnectivityResult.mobile],
      );
      expect(await manager.effectiveTtlForTesting(), const Duration(hours: 48));
    });

    test('wifi connection gets the 24h TTL', () async {
      final manager = EmoteManager(
        probe: () async => [ConnectivityResult.wifi],
      );
      expect(await manager.effectiveTtlForTesting(), const Duration(hours: 24));
    });

    test('probe failure falls back to the 24h wifi TTL', () async {
      final manager = EmoteManager(
        probe: () async => throw Exception('probe failed'),
      );
      expect(await manager.effectiveTtlForTesting(), const Duration(hours: 24));
    });

    test('no probe configured falls back to the 24h wifi TTL', () async {
      final manager = EmoteManager();
      expect(await manager.effectiveTtlForTesting(), const Duration(hours: 24));
    });

    test('connectivity probe result is cached within the 60s window', () async {
      var probeCalls = 0;
      final manager = EmoteManager(
        probe: () async {
          probeCalls++;
          return [ConnectivityResult.mobile];
        },
      );

      await manager.effectiveTtlForTesting();
      await manager.effectiveTtlForTesting();

      expect(probeCalls, 1);
    });

    test('fetch queue serializes actions in order', () async {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      final order = <int>[];

      await Future.wait([
        manager.enqueueFetchForTesting(() async => order.add(1)),
        manager.enqueueFetchForTesting(() async => order.add(2)),
        manager.enqueueFetchForTesting(() async => order.add(3)),
      ]);

      expect(order, [1, 2, 3]);
    });

    test('fetch queue survives a failing action', () async {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      final order = <int>[];

      await expectLater(
        manager.enqueueFetchForTesting(() async => throw Exception('boom')),
        throwsException,
      );
      await manager.enqueueFetchForTesting(() async => order.add(1));

      expect(order, [1]);
    });
  });

  group('subscriber emotes in channel cache', () {
    GenericEmote subEmote() => GenericEmote(
      id: 's1',
      code: 'SubEmote',
      type: EmoteType.twitch,
      url: 'https://example.com/s1.png',
      scope: EmoteScope.channel,
      tier: '3',
      emoteType: 'subscriptions',
    );

    Map<String, Object> persistedCache({required bool fresh}) {
      return {
        'emotes2_ch': jsonEncode({
          'ts': DateTime.now()
              .subtract(
                fresh ? const Duration(hours: 1) : const Duration(days: 2),
              )
              .toIso8601String(),
          'emotes': [makeTestEmote(id: 'n1', code: 'NonTwitch').toJson()],
        }),
      };
    }

    test('applying a fresh persisted cache keeps stored sub emotes', () async {
      SharedPreferences.setMockInitialValues(persistedCache(fresh: true));
      final manager = EmoteManager(fetchStagger: Duration.zero);
      await manager.storeUserTwitchEmotes({
        'ch': [subEmote()],
      });

      await manager.resolveEmotes('ch', 'b1');

      final codes = manager.byCode('ch')!.suggestions.map((e) => e.code);
      expect(codes, contains('SubEmote'));
      expect(codes, contains('NonTwitch'));
    });

    test('stale revalidate does not clobber stored sub emotes', () async {
      SharedPreferences.setMockInitialValues(persistedCache(fresh: false));
      final manager = EmoteManager(fetchStagger: Duration.zero);
      await manager.storeUserTwitchEmotes({
        'ch': [subEmote()],
      });

      await manager.resolveEmotes('ch', 'b1');

      final codes = manager.byCode('ch')!.suggestions.map((e) => e.code);
      expect(codes, contains('SubEmote'));
    });
  });
}
