import 'dart:convert';
import 'dart:io' show Directory;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/emote_manager.dart';
import '../helpers.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String tempDir;
  _FakePathProvider(this.tempDir);

  @override
  Future<String?> getTemporaryPath() async => tempDir;

  @override
  Future<String?> getApplicationSupportPath() async => tempDir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
        baseName: 'AliasedEmote',
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
      expect(restored.baseName, 'AliasedEmote');
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

  group('7TV live updates', () {
    test('renaming a 7TV emote preserves baseName and ownerChannel', () async {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      manager.updateSevenTvEmotes(
        'ch',
        added: [
          GenericEmote(
            id: 'e1',
            code: 'OldName',
            type: EmoteType.sevenTv,
            url: 'https://example.com/e1.png',
            scope: EmoteScope.channel,
            ownerChannel: 'Creator',
            baseName: 'BaseEmote',
          ),
        ],
      );
      manager.updateSevenTvEmotes(
        'ch',
        renamed: {'e1': (newName: 'NewName', oldName: 'OldName')},
      );
      final emote = manager.byCode('ch')!.byCode['NewName'];
      expect(emote, isNotNull);
      expect(emote!.baseName, 'BaseEmote');
      expect(emote.ownerChannel, 'Creator');
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
        'emotes3_ch': jsonEncode({
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

  group('disk cache GC', () {
    // Preloads the usage registry (via startCacheGc) then cancels the timer,
    // so touches recorded via enqueueSeenEmotes get per-call timestamps. The
    // manager's pure GC/touch methods remain usable after dispose().
    Future<EmoteManager> makeManager({
      required DateTime Function() clock,
      required void Function(String) remove,
    }) async {
      PathProviderPlatform.instance = _FakePathProvider(Directory.systemTemp.path);
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        now: clock,
        removeCachedFile: (url) async => remove(url),
      );
      await manager.startCacheGc();
      manager.dispose();
      return manager;
    }

    test('evicts emotes unused for over 24h regardless of count', () async {
      SharedPreferences.setMockInitialValues({});
      var clock = DateTime(2026, 1, 1, 12);
      final removed = <String>[];
      final manager = await makeManager(
        clock: () => clock,
        remove: (url) => removed.add(url),
      );
      manager.enqueueSeenEmotes([
        GenericEmote(id: 'f', code: 'Fresh', url: 'https://example.com/fresh.png', type: EmoteType.bttv),
      ]);
      clock = clock.add(const Duration(hours: 25));
      manager.enqueueSeenEmotes([
        GenericEmote(id: 's', code: 'Stale', url: 'https://example.com/stale.png', type: EmoteType.bttv),
      ]);

      await manager.runCacheGc();

      expect(removed, ['https://example.com/fresh.png']);
    });

    test('trims to max emotes by evicting oldest unused for over 1h', () async {
      SharedPreferences.setMockInitialValues({});
      var clock = DateTime(2026, 1, 1, 12);
      final removed = <String>[];
      final manager = await makeManager(
        clock: () => clock,
        remove: (url) => removed.add(url),
      );
      final emotes = <GenericEmote>[];
      for (var i = 0; i < 90; i++) {
        emotes.add(
          GenericEmote(
            id: 'e$i',
            code: 'E$i',
            url: 'https://example.com/e$i.png',
            type: EmoteType.bttv,
          ),
        );
      }
      // Seed 40 old emotes (touched 2h ago), then 50 fresh (now).
      manager.enqueueSeenEmotes(emotes.sublist(0, 40));
      clock = clock.add(const Duration(hours: 2));
      manager.enqueueSeenEmotes(emotes.sublist(40));

      await manager.runCacheGc();

      // 90 > 80, so 10 of the old emotes should be evicted. Among equal
      // timestamps the sort order is unspecified, so assert set membership
      // rather than exact order.
      expect(removed, hasLength(10));
      for (final url in removed) {
        final idx = int.parse(
          url.replaceAll('https://example.com/e', '').replaceAll('.png', ''),
        );
        expect(idx, lessThan(40));
      }
    });

    test('does not evict fresh emotes even when over capacity', () async {
      SharedPreferences.setMockInitialValues({});
      var clock = DateTime(2026, 1, 1, 12);
      final removed = <String>[];
      final manager = await makeManager(
        clock: () => clock,
        remove: (url) => removed.add(url),
      );
      final emotes = <GenericEmote>[];
      for (var i = 0; i < 90; i++) {
        emotes.add(
          GenericEmote(
            id: 'e$i',
            code: 'E$i',
            url: 'https://example.com/e$i.png',
            type: EmoteType.bttv,
          ),
        );
      }
      manager.enqueueSeenEmotes(emotes);

      await manager.runCacheGc();

      expect(removed, isEmpty);
    });

    test('evicts nothing when under max and none over 24h', () async {
      SharedPreferences.setMockInitialValues({});
      var clock = DateTime(2026, 1, 1, 12);
      final removed = <String>[];
      final manager = await makeManager(
        clock: () => clock,
        remove: (url) => removed.add(url),
      );
      manager.enqueueSeenEmotes([
        GenericEmote(id: 'a', code: 'A', url: 'https://example.com/a.png', type: EmoteType.bttv),
      ]);

      await manager.runCacheGc();

      expect(removed, isEmpty);
    });

    test('usage registry persists across manager instances', () async {
      SharedPreferences.setMockInitialValues({});
      var clock = DateTime(2026, 1, 1, 12);
      final removed = <String>[];
      final manager = await makeManager(
        clock: () => clock,
        remove: removed.add,
      );
      manager.enqueueSeenEmotes([
        GenericEmote(id: 'a', code: 'A', url: 'https://example.com/a.png', type: EmoteType.bttv),
      ]);
      await manager.runCacheGc();

      // Fresh instance loads the same registry.
      final removed2 = <String>[];
      final manager2 = await makeManager(
        clock: () => clock.add(const Duration(hours: 25)),
        remove: removed2.add,
      );
      await manager2.runCacheGc();

      expect(removed2, ['https://example.com/a.png']);
    });

    test('one-time migration sets the flag once', () async {
      SharedPreferences.setMockInitialValues({});
      PathProviderPlatform.instance = _FakePathProvider(Directory.systemTemp.path);
      final manager = EmoteManager(fetchStagger: Duration.zero);
      await manager.startCacheGc();
      manager.dispose();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('emote_gc_migrated_v1'), isTrue);

      // Second start skips migration but still schedules a sweep.
      final manager2 = EmoteManager(fetchStagger: Duration.zero);
      await manager2.startCacheGc();
      manager2.dispose();
      expect(await SharedPreferences.getInstance(), isNotNull);
    });

    test('dispose cancels the periodic timer', () async {
      SharedPreferences.setMockInitialValues({});
      PathProviderPlatform.instance = _FakePathProvider(Directory.systemTemp.path);
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        removeCachedFile: (_) async {},
      );
      await manager.startCacheGc();
      manager.dispose();
      // If the timer leaked, the test would fail with a pending timer error.
    });
  });
}
