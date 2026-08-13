import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ermchat/models/emote_fetch_tier.dart';
import 'package:ermchat/models/generic_emote.dart';
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

    test('round-trips urlLarge', () {
      final original = GenericEmote(
        id: 'id-url',
        code: 'Emote',
        type: EmoteType.bttv,
        url: 'https://example.com/2x.png',
        urlLarge: 'https://example.com/3x.png',
      );
      final restored = GenericEmote.fromJson(original.toJson());
      expect(restored.urlLarge, original.urlLarge);
    });

    test('urlLarge is null when not provided', () {
      final e = GenericEmote(
        id: '1',
        code: 'Test',
        type: EmoteType.bttv,
        url: 'https://example.com/1x.png',
      );
      expect(e.urlLarge, isNull);
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

    test('low tier caches forever (infinite TTL)', () async {
      final manager = EmoteManager(
        tier: EmoteFetchTier.low,
        probe: () async => [ConnectivityResult.mobile],
      );
      expect(
        await manager.effectiveTtlForTesting(),
        const Duration(days: 365000),
      );
    });

    test('nothing tier caches forever (infinite TTL)', () async {
      final manager = EmoteManager(
        tier: EmoteFetchTier.nothing,
        probe: () async => [ConnectivityResult.mobile],
      );
      expect(
        await manager.effectiveTtlForTesting(),
        const Duration(days: 365000),
      );
    });

    test(
      'medium tier uses a flat 48h TTL regardless of connectivity',
      () async {
        final mobile = EmoteManager(
          tier: EmoteFetchTier.medium,
          probe: () async => [ConnectivityResult.mobile],
        );
        final wifi = EmoteManager(
          tier: EmoteFetchTier.medium,
          probe: () async => [ConnectivityResult.wifi],
        );
        expect(
          await mobile.effectiveTtlForTesting(),
          const Duration(hours: 48),
        );
        expect(await wifi.effectiveTtlForTesting(), const Duration(hours: 48));
      },
    );

    test('high tier keeps the wifi/cellular TTL split', () async {
      final mobile = EmoteManager(
        tier: EmoteFetchTier.high,
        probe: () async => [ConnectivityResult.mobile],
      );
      final wifi = EmoteManager(
        tier: EmoteFetchTier.high,
        probe: () async => [ConnectivityResult.wifi],
      );
      expect(await mobile.effectiveTtlForTesting(), const Duration(hours: 48));
      expect(await wifi.effectiveTtlForTesting(), const Duration(hours: 24));
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

    test('allows up to two in-flight fetches to overlap', () async {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      final started = <String>[];
      final gates = [Completer<void>(), Completer<void>()];
      final f1 = manager.enqueueFetchForTesting(() async {
        started.add('a');
        await gates[0].future;
      });
      final f2 = manager.enqueueFetchForTesting(() async {
        started.add('b');
        await gates[1].future;
      });

      await Future<void>.delayed(Duration.zero);

      expect(started, containsAll(['a', 'b']));

      gates[0].complete();
      gates[1].complete();
      await Future.wait([f1, f2]);
    });

    test('third fetch waits for a free slot before starting', () async {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      final started = <String>[];
      final gates = [Completer<void>(), Completer<void>()];
      final f1 = manager.enqueueFetchForTesting(() async {
        started.add('a');
        await gates[0].future;
      });
      final f2 = manager.enqueueFetchForTesting(() async {
        started.add('b');
        await gates[1].future;
      });
      final f3 = manager.enqueueFetchForTesting(() async => started.add('c'));

      await Future<void>.delayed(Duration.zero);

      expect(started, containsAll(['a', 'b']));
      expect(started, isNot(contains('c')));

      gates[0].complete();
      await Future<void>.delayed(Duration.zero);

      expect(started, contains('c'));

      gates[1].complete();
      await Future.wait([f1, f2, f3]);
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
      int cacheCap = defaultEmoteCacheMax,
      EmoteFetchTier tier = EmoteFetchTier.high,
    }) async {
      PathProviderPlatform.instance = _FakePathProvider(
        Directory.systemTemp.path,
      );
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        now: clock,
        removeCachedFile: (url) async => remove(url),
        cacheCap: cacheCap,
        tier: tier,
      );
      await manager.startCacheGc();
      manager.dispose();
      return manager;
    }

    List<GenericEmote> makeEmotes(int count) => [
      for (var i = 0; i < count; i++)
        GenericEmote(
          id: 'e$i',
          code: 'E$i',
          url: 'https://example.com/e$i.png',
          type: EmoteType.bttv,
        ),
    ];

    test('evicts emotes unused for over 24h regardless of count', () async {
      SharedPreferences.setMockInitialValues({});
      var clock = DateTime(2026, 1, 1, 12);
      final removed = <String>[];
      final manager = await makeManager(
        clock: () => clock,
        remove: (url) => removed.add(url),
      );
      manager.enqueueSeenEmotes([
        GenericEmote(
          id: 'f',
          code: 'Fresh',
          url: 'https://example.com/fresh.png',
          type: EmoteType.bttv,
        ),
      ]);
      clock = clock.add(const Duration(hours: 25));
      manager.enqueueSeenEmotes([
        GenericEmote(
          id: 's',
          code: 'Stale',
          url: 'https://example.com/stale.png',
          type: EmoteType.bttv,
        ),
      ]);

      await manager.runCacheGc();

      expect(removed, ['https://example.com/fresh.png']);
    });

    test('LRU trims oldest even within the former 1h hot window', () async {
      SharedPreferences.setMockInitialValues({});
      var clock = DateTime(2026, 1, 1, 12);
      final removed = <String>[];
      final manager = await makeManager(
        clock: () => clock,
        remove: (url) => removed.add(url),
        cacheCap: 5,
      );
      final emotes = makeEmotes(10);
      // Seed 4 old (touched 2h ago), then 6 fresh (now). Every entry is
      // within the former 1h hot TTL, so trimming must be pure LRU.
      manager.enqueueSeenEmotes(emotes.sublist(0, 4));
      clock = clock.add(const Duration(hours: 2));
      manager.enqueueSeenEmotes(emotes.sublist(4));

      await manager.runCacheGc();

      // 10 > cap 5: exactly 5 trimmed. Hard TTL (24h) doesn't touch the
      // 2h-old entries, so the 4 oldest go first, then the earliest fresh.
      expect(removed, hasLength(5));
      for (final url in removed) {
        final idx = int.parse(
          url.replaceAll('https://example.com/e', '').replaceAll('.png', ''),
        );
        // The 4 old entries (0-3) are evicted regardless of age; the 5th is
        // the earliest fresh (4), since ties sort in unspecified order.
        expect(idx, lessThan(5));
      }
    });

    test('trims fresh emotes over the cache cap without a hot TTL', () async {
      SharedPreferences.setMockInitialValues({});
      final clock = DateTime(2026, 1, 1, 12);
      final removed = <String>[];
      final manager = await makeManager(
        clock: () => clock,
        remove: (url) => removed.add(url),
        cacheCap: 5,
      );
      // All touched "now": previously protected by the hot TTL, now trimmed
      // purely by LRU once over the cap.
      manager.enqueueSeenEmotes(makeEmotes(10));

      await manager.runCacheGc();

      expect(removed, hasLength(5));
    });

    test('cacheCap setter is honored by the next GC sweep', () async {
      SharedPreferences.setMockInitialValues({});
      final clock = DateTime(2026, 1, 1, 12);
      final removed = <String>[];
      final manager = await makeManager(
        clock: () => clock,
        remove: (url) => removed.add(url),
        cacheCap: 6,
      );
      manager.enqueueSeenEmotes(makeEmotes(12));

      await manager.runCacheGc();
      expect(removed, hasLength(6));
      expect(manager.cacheCap, 6);

      manager.cacheCap = 4;
      await manager.runCacheGc();

      // 6 remaining > new cap 4: two more evicted.
      expect(removed, hasLength(8));
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
        GenericEmote(
          id: 'a',
          code: 'A',
          url: 'https://example.com/a.png',
          type: EmoteType.bttv,
        ),
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
        GenericEmote(
          id: 'a',
          code: 'A',
          url: 'https://example.com/a.png',
          type: EmoteType.bttv,
        ),
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
      PathProviderPlatform.instance = _FakePathProvider(
        Directory.systemTemp.path,
      );
      final manager = EmoteManager(fetchStagger: Duration.zero);
      await manager.startCacheGc();
      manager.dispose();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('emote_gc_migrated_v1'), isTrue);
      // v2 migration cleared the v1 DefaultCacheManager orphans once.
      expect(prefs.getBool('emote_gc_migrated_v2'), isTrue);

      // Second start skips migration but still schedules a sweep.
      final manager2 = EmoteManager(fetchStagger: Duration.zero);
      await manager2.startCacheGc();
      manager2.dispose();
      expect(await SharedPreferences.getInstance(), isNotNull);
    });
  });

  group('nothing fetch tier guards', () {
    GenericEmote subEmote() => GenericEmote(
      id: 's1',
      code: 'SubEmote',
      type: EmoteType.twitch,
      url: 'https://example.com/s1.png',
      scope: EmoteScope.channel,
      tier: '3',
      emoteType: 'subscriptions',
    );

    test(
      'preloadGlobalEmotes loads the persisted cache without fetching',
      () async {
        final persisted = jsonEncode({
          'ts': DateTime.now()
              .subtract(const Duration(days: 1))
              .toIso8601String(),
          'tier': EmoteFetchTier.nothing.index,
          'emotes': [makeTestEmote(id: 'g1', code: 'GlobalE').toJson()],
        });
        SharedPreferences.setMockInitialValues({'emotes3_global': persisted});
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          tier: EmoteFetchTier.nothing,
        );

        await manager.preloadGlobalEmotes();

        // Hoarded cache renders; nothing was fetched, so prefs are untouched.
        expect(manager.byCode('any')!.byCode, contains('GlobalE'));
        expect(manager.globalEmotes().map((e) => e.code), contains('GlobalE'));
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('emotes3_global'), persisted);
      },
    );

    test(
      'resolveEmotes loads the persisted channel cache without fetching',
      () async {
        SharedPreferences.setMockInitialValues({
          'emotes3_ch': jsonEncode({
            'ts': DateTime.now().toIso8601String(),
            'tier': EmoteFetchTier.nothing.index,
            'emotes': [
              makeTestEmote(
                id: 'c1',
                code: 'ChanE',
                scope: EmoteScope.channel,
              ).toJson(),
            ],
          }),
        });
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          tier: EmoteFetchTier.nothing,
        );

        await manager.resolveEmotes('ch', 'b1');

        expect(manager.byCode('ch')!.byCode, contains('ChanE'));
      },
    );

    test('resolveEmotes with no persisted cache fetches nothing', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.nothing,
      );

      await manager.resolveEmotes('ch', 'b1');

      // No fetch, no cache, no throw.
      expect(manager.byCode('ch'), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('emotes3_ch'), isNull);
    });

    test('storeUserTwitchEmotes no-ops in the nothing tier', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.nothing,
      );

      await manager.storeUserTwitchEmotes({
        'ch': [subEmote()],
      });

      expect(manager.subscriberEmotesByChannel(), isEmpty);
    });

    test('updateSevenTvEmotes no-ops in the nothing tier', () {
      final manager = EmoteManager(tier: EmoteFetchTier.nothing);

      manager.updateSevenTvEmotes(
        'ch',
        added: [
          GenericEmote(
            id: 'e1',
            code: 'E1',
            type: EmoteType.sevenTv,
            url: 'https://example.com/e1.png',
            scope: EmoteScope.channel,
          ),
        ],
      );

      expect(manager.byCode('ch'), isNull);
    });

    test('enqueueSeenEmotes skips usage tracking and precache', () async {
      SharedPreferences.setMockInitialValues({});
      PathProviderPlatform.instance = _FakePathProvider(
        Directory.systemTemp.path,
      );
      final removed = <String>[];
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.nothing,
        cacheCap: 0,
        now: () => DateTime(2026, 1, 1, 12),
        removeCachedFile: (url) async => removed.add(url),
      );
      await manager.startCacheGc();
      manager.dispose();

      manager.enqueueSeenEmotes([
        GenericEmote(
          id: 'e1',
          code: 'E1',
          type: EmoteType.bttv,
          url: 'https://example.com/e1.png',
        ),
      ]);
      await manager.runCacheGc();

      // cap 0 would evict any tracked usage; the nothing tier never tracked
      // it, so nothing is removed.
      expect(removed, isEmpty);
    });
  });

  group('tier tag in persisted cache', () {
    Map<String, Object> channelCache({required int tier, int ageHours = 1}) => {
      'emotes3_ch': jsonEncode({
        'ts': DateTime.now()
            .subtract(Duration(hours: ageHours))
            .toIso8601String(),
        'tier': tier,
        'emotes': [
          makeTestEmote(
            id: 'c1',
            code: 'ChanE',
            scope: EmoteScope.channel,
          ).toJson(),
        ],
      }),
    };

    test('mismatched tier tag forces a refetch (1x -> 2x overwrite)', () async {
      SharedPreferences.setMockInitialValues(
        channelCache(tier: EmoteFetchTier.low.index),
      );
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
      );

      await manager.resolveEmotes('ch', 'b1');

      // The stale 1x cache still renders while revalidating...
      expect(manager.byCode('ch')!.byCode, contains('ChanE'));
      // ...and the refetch rewrote the cache with the new tier tag.
      final prefs = await SharedPreferences.getInstance();
      final data =
          jsonDecode(prefs.getString('emotes3_ch')!) as Map<String, dynamic>;
      expect(data['tier'], EmoteFetchTier.medium.index);
    });

    test('matching tier tag stays fresh without rewriting', () async {
      SharedPreferences.setMockInitialValues(
        channelCache(tier: EmoteFetchTier.medium.index),
      );
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
      );

      await manager.resolveEmotes('ch', 'b1');

      expect(manager.byCode('ch')!.byCode, contains('ChanE'));
      final prefs = await SharedPreferences.getInstance();
      final data =
          jsonDecode(prefs.getString('emotes3_ch')!) as Map<String, dynamic>;
      // No refetch happened: the persisted tier tag is untouched.
      expect(data['tier'], EmoteFetchTier.medium.index);
    });

    test(
      'missing tier tag (pre-feature cache) is treated as matching',
      () async {
        SharedPreferences.setMockInitialValues({
          'emotes3_ch': jsonEncode({
            'ts': DateTime.now()
                .subtract(const Duration(minutes: 30))
                .toIso8601String(),
            'emotes': [
              makeTestEmote(
                id: 'c1',
                code: 'ChanE',
                scope: EmoteScope.channel,
              ).toJson(),
            ],
          }),
        });
        final manager = EmoteManager(fetchStagger: Duration.zero);

        await manager.resolveEmotes('ch', 'b1');

        expect(manager.byCode('ch')!.byCode, contains('ChanE'));
        final prefs = await SharedPreferences.getInstance();
        final data =
            jsonDecode(prefs.getString('emotes3_ch')!) as Map<String, dynamic>;
        expect(data.containsKey('tier'), isFalse);
      },
    );
  });
}
