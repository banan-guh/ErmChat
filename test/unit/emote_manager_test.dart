import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ermchat/models/emote_fetch_tier.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/services/emote_cache_manager.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/emote_providers/seven_tv_emotes.dart';
import '../helpers.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String tempDir;
  _FakePathProvider(this.tempDir);

  @override
  Future<String?> getTemporaryPath() async => tempDir;

  @override
  Future<String?> getApplicationSupportPath() async => tempDir;
}

/// A cache manager with a no-op repo and an in-memory file system, so unit
/// tests exercise the cap/priority wiring without touching path_provider.
EmoteCacheManager testCacheManager() => EmoteCacheManager.forTesting(
  Config(
    'test',
    repo: NonStoringObjectProvider(),
    fileSystem: MemoryCacheSystem(),
  ),
);

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

    test('round-trips url1x/url3x', () {
      final original = GenericEmote(
        id: 'id-url',
        code: 'Emote',
        type: EmoteType.bttv,
        url: 'https://example.com/2x.png',
        url1x: 'https://example.com/1x.png',
        url3x: 'https://example.com/3x.png',
      );
      final restored = GenericEmote.fromJson(original.toJson());
      expect(restored.url1x, original.url1x);
      expect(restored.url3x, original.url3x);
    });

    test('url1x/url3x are null when not provided', () {
      final e = GenericEmote(
        id: '1',
        code: 'Test',
        type: EmoteType.bttv,
        url: 'https://example.com/1x.png',
      );
      expect(e.url1x, isNull);
      expect(e.url3x, isNull);
    });

    test('recovers url3x from the legacy urlLarge key', () {
      final legacy = {
        'id': 'legacy-1',
        'code': 'Legacy',
        'type': 'sevenTv',
        'url': 'https://example.com/2x.png',
        'urlLarge': 'https://example.com/3x.png',
        'isAnimated': false,
        'scope': 'global',
        'relativeScale': 1.0,
        'aspectRatio': 1.0,
      };
      final restored = GenericEmote.fromJson(legacy);
      expect(restored.url1x, isNull);
      expect(restored.url3x, 'https://example.com/3x.png');
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

    GenericEmote sevenTv(String id, String code) => GenericEmote(
      id: id,
      code: code,
      type: EmoteType.sevenTv,
      url: 'https://example.com/$id.png',
      scope: EmoteScope.channel,
    );

    test('incremental adds keep the suggestions code-sorted', () {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      manager.updateSevenTvEmotes(
        'ch',
        added: [sevenTv('a', 'Alpha'), sevenTv('c', 'Charlie')],
      );
      manager.updateSevenTvEmotes('ch', added: [sevenTv('b', 'Bravo')]);

      final codes = manager
          .byCode('ch')!
          .suggestions
          .map((e) => e.code)
          .toList();
      expect(codes, ['Alpha', 'Bravo', 'Charlie']);
    });

    test('incremental removes drop the entry and keep sorting', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        removeCachedFile: (url) async {},
      );
      manager.updateSevenTvEmotes(
        'ch',
        added: [
          sevenTv('a', 'Alpha'),
          sevenTv('b', 'Bravo'),
          sevenTv('c', 'Charlie'),
        ],
      );
      manager.updateSevenTvEmotes('ch', removedIds: ['b']);
      await pumpEventQueue();

      final emotes = manager.byCode('ch')!;
      expect(emotes.byCode.keys, ['Alpha', 'Charlie']);
      expect(emotes.suggestions.map((e) => e.code).toList(), [
        'Alpha',
        'Charlie',
      ]);
    });

    test('rename re-sorts the renamed emote into place', () {
      final manager = EmoteManager(fetchStagger: Duration.zero);
      manager.updateSevenTvEmotes(
        'ch',
        added: [
          sevenTv('a', 'Alpha'),
          sevenTv('b', 'Bravo'),
          sevenTv('c', 'Charlie'),
        ],
      );
      manager.updateSevenTvEmotes(
        'ch',
        renamed: {'c': (newName: 'Aaron', oldName: 'Charlie')},
      );

      final codes = manager
          .byCode('ch')!
          .suggestions
          .map((e) => e.code)
          .toList();
      expect(codes, ['Aaron', 'Alpha', 'Bravo']);
    });

    test('consumeChangedCodes returns the touched codes per delta', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        removeCachedFile: (url) async {},
      );
      manager.updateSevenTvEmotes(
        'ch',
        added: [sevenTv('a', 'Alpha'), sevenTv('b', 'Bravo')],
      );
      expect(manager.consumeChangedCodes('ch'), {'Alpha', 'Bravo'});

      manager.updateSevenTvEmotes('ch', removedIds: ['a']);
      await pumpEventQueue();
      expect(manager.consumeChangedCodes('ch'), {'Alpha'});

      manager.updateSevenTvEmotes(
        'ch',
        renamed: {'b': (newName: 'Beta', oldName: 'Bravo')},
      );
      expect(manager.consumeChangedCodes('ch'), {'Bravo', 'Beta'});
      expect(manager.consumeChangedCodes('ch'), isNull);
    });

    test('consumeChangedCodes is null after a non-7TV notify', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(fetchStagger: Duration.zero);
      await manager.storeUserTwitchEmotes({
        'ch': [
          GenericEmote(
            id: 's1',
            code: 'SubEmote',
            type: EmoteType.twitch,
            url: 'https://example.com/s1.png',
            scope: EmoteScope.channel,
            tier: '3',
            emoteType: 'subscriptions',
          ),
        ],
      });

      expect(manager.consumeChangedCodes('ch'), isNull);
    });

    test('removed emote is evicted from disk when unused elsewhere', () async {
      SharedPreferences.setMockInitialValues({});
      final removed = <String>[];
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        removeCachedFile: (url) async => removed.add(url),
      );
      manager.updateSevenTvEmotes(
        'ch',
        added: [sevenTv('a', 'Alpha'), sevenTv('b', 'Bravo')],
      );

      manager.updateSevenTvEmotes('ch', removedIds: ['a']);
      await pumpEventQueue();

      expect(removed, contains('https://example.com/a.png'));
      expect(removed, isNot(contains('https://example.com/b.png')));
    });

    test(
      'removed emote stays on disk when another channel still uses it',
      () async {
        SharedPreferences.setMockInitialValues({});
        final removed = <String>[];
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          removeCachedFile: (url) async => removed.add(url),
        );
        manager.updateSevenTvEmotes('ch1', added: [sevenTv('a', 'Alpha')]);
        manager.updateSevenTvEmotes('ch2', added: [sevenTv('a', 'Alpha')]);

        manager.updateSevenTvEmotes('ch1', removedIds: ['a']);
        await pumpEventQueue();

        expect(removed, isEmpty);
      },
    );

    test('a 7TV delta does not bump the span-cache version', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        removeCachedFile: (url) async {},
      );
      final before = manager.version;

      manager.updateSevenTvEmotes('ch', added: [sevenTv('a', 'Alpha')]);
      expect(manager.version, before);

      // Non-delta notifies (full refetches) still bump, so cached spans
      // recompute against the fresh data.
      await manager.storeUserTwitchEmotes({'ch': []});
      expect(manager.version, greaterThan(before));
    });

    test('a no-op delta still counts as a delta, not a refetch', () {
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        removeCachedFile: (url) async {},
      );
      manager.updateSevenTvEmotes('ch', added: [sevenTv('a', 'Alpha')]);

      // Renaming an emote that isn't cached changes nothing, but the event
      // is still a live delta: callers must not treat it as a full refetch.
      manager.updateSevenTvEmotes(
        'ch',
        renamed: {'missing': (newName: 'X', oldName: 'Y')},
      );

      final codes = manager.consumeChangedCodes('ch');
      expect(codes, isNotNull);
      expect(codes, isEmpty);
    });

    test('a fetch re-load re-applies live 7TV deltas', () async {
      SharedPreferences.setMockInitialValues({
        'emotes3_ch': jsonEncode({
          'ts': DateTime.now().toIso8601String(),
          'tier': EmoteFetchTier.high.index,
          'emotes': [
            sevenTv('old', 'Old7tv').toJson(),
            makeTestEmote(id: 'n1', code: 'NonTwitch').toJson(),
          ],
        }),
      });
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        removeCachedFile: (url) async {},
      );
      await manager.resolveEmotes('ch', 'b1');

      // Live deltas: remove the persisted 7TV emote, add a new one.
      manager.updateSevenTvEmotes('ch', removedIds: ['old']);
      manager.updateSevenTvEmotes('ch', added: [sevenTv('live', 'LiveEmote')]);
      await pumpEventQueue();

      // Re-loading the still-fresh persisted cache must not clobber the
      // live state.
      await manager.resolveEmotes('ch', 'b1');

      final codes = manager
          .byCode('ch')!
          .suggestions
          .map((e) => e.code)
          .toList();
      expect(codes, contains('LiveEmote'));
      expect(codes, isNot(contains('Old7tv')));
      expect(codes, contains('NonTwitch'));
    });
  });

  group('7TV startup reconcile', () {
    GenericEmote sevenTv(String id, String code) => GenericEmote(
      id: id,
      code: code,
      type: EmoteType.sevenTv,
      url: 'https://example.com/$id.png',
      scope: EmoteScope.channel,
    );

    Map<String, Object> cache(List<GenericEmote> emotes) => {
      'emotes3_ch': jsonEncode({
        'ts': DateTime.now()
            .subtract(const Duration(hours: 1))
            .toIso8601String(),
        'emotes': emotes.map((e) => e.toJson()).toList(),
      }),
    };

    test('applies add/remove/rename deltas against the loaded cache', () async {
      SharedPreferences.setMockInitialValues(
        cache([
          sevenTv('a', 'Alpha'),
          sevenTv('b', 'Bravo'),
          sevenTv('c', 'Charlie'),
        ]),
      );
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async => SevenTvChannelResponse(
          emotes: [
            sevenTv('b', 'Bravo'),
            sevenTv('c', 'Charlee'),
            sevenTv('d', 'Delta'),
          ],
          emoteSetId: 'set1',
          userId: 'u1',
        ),
      );

      await manager.resolveEmotes('ch', 'b1');
      await pumpEventQueue();

      final codes = manager
          .byCode('ch')!
          .suggestions
          .map((e) => e.code)
          .toList();
      expect(codes, ['Bravo', 'Charlee', 'Delta']);
      expect(manager.getSevenTvEmoteSetId('ch'), 'set1');
      expect(manager.getSevenTvUserId('ch'), 'u1');
    });

    test('skips the reconcile in the low tier', () async {
      SharedPreferences.setMockInitialValues(cache([sevenTv('a', 'Alpha')]));
      var fetched = false;
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.low,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async {
          fetched = true;
          return SevenTvChannelResponse(emotes: [sevenTv('b', 'Bravo')]);
        },
      );

      await manager.resolveEmotes('ch', 'b1');
      await pumpEventQueue();

      expect(fetched, isFalse);
      expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Alpha']);
    });

    test('skips the reconcile without a broadcaster id', () async {
      SharedPreferences.setMockInitialValues(cache([sevenTv('a', 'Alpha')]));
      var fetched = false;
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async {
          fetched = true;
          return SevenTvChannelResponse(emotes: [sevenTv('b', 'Bravo')]);
        },
      );

      await manager.resolveEmotes('ch', null);
      await pumpEventQueue();

      expect(fetched, isFalse);
    });

    test('a failed reconcile leaves the cache untouched', () async {
      SharedPreferences.setMockInitialValues(cache([sevenTv('a', 'Alpha')]));
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.medium,
        removeCachedFile: (url) async {},
        sevenTvChannelFetcher: (id, resolution) async =>
            throw Exception('boom'),
      );

      await manager.resolveEmotes('ch', 'b1');
      await pumpEventQueue();

      expect(manager.byCode('ch')!.suggestions.map((e) => e.code), ['Alpha']);
    });
  });

  group('EmoteManager refresh policy', () {
    test('cellular connection gets the longer 24h TTL', () async {
      final manager = EmoteManager(
        probe: () async => [ConnectivityResult.mobile],
      );
      expect(await manager.effectiveTtlForTesting(), const Duration(hours: 24));
    });

    test('wifi connection gets the 12h TTL', () async {
      final manager = EmoteManager(
        probe: () async => [ConnectivityResult.wifi],
      );
      expect(await manager.effectiveTtlForTesting(), const Duration(hours: 12));
    });

    test('probe failure falls back to the 12h wifi TTL', () async {
      final manager = EmoteManager(
        probe: () async => throw Exception('probe failed'),
      );
      expect(await manager.effectiveTtlForTesting(), const Duration(hours: 12));
    });

    test('no probe configured falls back to the 12h wifi TTL', () async {
      final manager = EmoteManager();
      expect(await manager.effectiveTtlForTesting(), const Duration(hours: 12));
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
      'medium tier uses a flat 24h TTL regardless of connectivity',
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
          const Duration(hours: 24),
        );
        expect(await wifi.effectiveTtlForTesting(), const Duration(hours: 24));
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
      expect(await mobile.effectiveTtlForTesting(), const Duration(hours: 24));
      expect(await wifi.effectiveTtlForTesting(), const Duration(hours: 12));
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

    test('storing the same sub emotes twice does not duplicate them', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(fetchStagger: Duration.zero);
      final emote = subEmote();

      await manager.storeUserTwitchEmotes({
        'ch': [emote],
      });
      await manager.storeUserTwitchEmotes({
        'ch': [emote],
      });

      final subs = manager.subscriberEmotesByChannel()['ch']!;
      expect(subs.length, 1);
      expect(subs.single.code, 'SubEmote');
    });

    test('groups subs by ownerChannel instead of storage channel', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(fetchStagger: Duration.zero);
      final emote = GenericEmote(
        id: 's1',
        code: 'SubEmote',
        type: EmoteType.twitch,
        url: 'https://example.com/s1.png',
        scope: EmoteScope.channel,
        tier: '3',
        emoteType: 'subscriptions',
        ownerChannel: 'alpha',
      );

      // The account-wide union fans into every open channel's store.
      await manager.storeUserTwitchEmotes({
        'a': [emote],
        'b': [emote],
      });

      final byChannel = manager.subscriberEmotesByChannel();
      expect(byChannel.keys, ['alpha']);
      expect(byChannel['alpha']!.length, 1);
      expect(byChannel['alpha']!.single.code, 'SubEmote');
    });

    test(
      'falls back to the storage channel when the owner is unknown',
      () async {
        SharedPreferences.setMockInitialValues({});
        final manager = EmoteManager(fetchStagger: Duration.zero);
        await manager.storeUserTwitchEmotes({
          'ch': [subEmote()],
        });

        final byChannel = manager.subscriberEmotesByChannel();
        expect(byChannel.keys, ['ch']);
        expect(byChannel['ch']!.single.code, 'SubEmote');
      },
    );

    test('a fresh store replaces stale sub emotes for the channel', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(fetchStagger: Duration.zero);
      final old = GenericEmote(
        id: 's1',
        code: 'OldEmote',
        type: EmoteType.twitch,
        url: 'https://example.com/s1.png',
        scope: EmoteScope.channel,
        tier: '3',
        emoteType: 'subscriptions',
      );
      final fresh = GenericEmote(
        id: 's1',
        code: 'FreshEmote',
        type: EmoteType.twitch,
        url: 'https://example.com/s1.png',
        scope: EmoteScope.channel,
        tier: '3',
        emoteType: 'subscriptions',
      );

      await manager.storeUserTwitchEmotes({
        'ch': [old],
      });
      await manager.storeUserTwitchEmotes({
        'ch': [fresh],
      });

      final subs = manager.subscriberEmotesByChannel()['ch']!;
      expect(subs.length, 1);
      expect(subs.single.code, 'FreshEmote');
    });

    test('groups subs alphabetically by owner channel', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(fetchStagger: Duration.zero);
      GenericEmote subOf(String id, String code, String owner) => GenericEmote(
        id: id,
        code: code,
        type: EmoteType.twitch,
        url: 'https://example.com/$id.png',
        scope: EmoteScope.channel,
        tier: '3',
        emoteType: 'subscriptions',
        ownerChannel: owner,
      );

      // The union fans both owners into every open channel's store; the
      // first-seen order inside the first storage channel is zeta before
      // alpha, which must not leak into the group order.
      await manager.storeUserTwitchEmotes({
        'm': [
          subOf('z1', 'ZetaEmote', 'zeta'),
          subOf('a1', 'AlphaEmote', 'alpha'),
        ],
        'n': [
          subOf('a1', 'AlphaEmote', 'alpha'),
          subOf('z1', 'ZetaEmote', 'zeta'),
        ],
      });

      final byChannel = manager.subscriberEmotesByChannel();
      expect(byChannel.keys, ['alpha', 'zeta']);
    });
  });

  group('cache cap + usage registry', () {
    Future<EmoteManager> makeManager({
      required DateTime Function() clock,
      int cacheCap = defaultEmoteCacheMax,
      EmoteFetchTier tier = EmoteFetchTier.high,
      EmoteCacheManager? cache,
    }) async {
      PathProviderPlatform.instance = _FakePathProvider(
        Directory.systemTemp.path,
      );
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        now: clock,
        cacheCap: cacheCap,
        tier: tier,
        usageFlushDelay: Duration.zero,
        cacheManager: cache ?? testCacheManager(),
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

    test('cacheCap setter forwards the cap to the cache manager', () async {
      SharedPreferences.setMockInitialValues({});
      final cache = testCacheManager();
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        cacheManager: cache,
      );
      manager.cacheCap = 123;
      expect(manager.cacheCap, 123);
      expect(cache.maxObjects, 123);
    });

    test('cacheCap setter clamps to the allowed range', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        cacheManager: testCacheManager(),
      );
      manager.cacheCap = 999999;
      expect(manager.cacheCap, maxEmoteCacheMax);
      manager.cacheCap = -5;
      expect(manager.cacheCap, minEmoteCacheMax);
    });

    test('markEmoteViewed records usage in the registry', () async {
      SharedPreferences.setMockInitialValues({});
      final clock = DateTime(2026, 1, 1, 12);
      final manager = await makeManager(clock: () => clock);
      manager.markEmoteViewed(makeEmotes(1)[0]);
      await pumpEventQueue();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('emote_usage'),
        contains('https://example.com/e0.png'),
      );
    });

    test('usage registry persists across manager instances', () async {
      SharedPreferences.setMockInitialValues({});
      final clock = DateTime(2026, 1, 1, 12);
      final manager = await makeManager(clock: () => clock);
      manager.markEmoteViewed(makeEmotes(1)[0]);
      await pumpEventQueue();

      // A fresh instance loads the same registry and surfaces it through the
      // cache manager's priority source.
      final cache = testCacheManager();
      await makeManager(clock: () => clock, cache: cache);
      final lastUsed = cache.lastUsedAt!('https://example.com/e0.png');
      expect(lastUsed, clock);
    });

    test('markEmoteViewed flushes are debounced', () async {
      SharedPreferences.setMockInitialValues({});
      PathProviderPlatform.instance = _FakePathProvider(
        Directory.systemTemp.path,
      );
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        usageFlushDelay: const Duration(milliseconds: 50),
        now: () => DateTime(2026, 1, 1, 12),
        cacheManager: testCacheManager(),
      );
      await manager.startCacheGc();
      manager.dispose();

      final emotes = makeEmotes(3);
      manager.markEmoteViewed(emotes[0]);
      // Immediately after the first touch, nothing is persisted yet.
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('emote_usage'), isNull);

      // A burst of touches within the debounce window lands as one write.
      manager.markEmoteViewed(emotes[1]);
      manager.markEmoteViewed(emotes[2]);
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('emote_usage'), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      prefs = await SharedPreferences.getInstance();
      final persisted = prefs.getString('emote_usage');
      expect(persisted, contains('https://example.com/e0.png'));
      expect(persisted, contains('https://example.com/e1.png'));
      expect(persisted, contains('https://example.com/e2.png'));
    });

    test('enqueueSeenEmotes skips precache when the cap is zero', () async {
      SharedPreferences.setMockInitialValues({});
      final capped = EmoteManager(
        fetchStagger: Duration.zero,
        cacheCap: 0,
        usageFlushDelay: Duration.zero,
        now: () => DateTime(2026, 1, 1, 12),
        cacheManager: testCacheManager(),
      );
      capped.enqueueSeenEmotes(makeEmotes(7));
      expect(capped.precacheQueueLengthForTesting, 0);

      final uncapped = EmoteManager(
        fetchStagger: Duration.zero,
        usageFlushDelay: Duration.zero,
        now: () => DateTime(2026, 1, 1, 12),
        cacheManager: testCacheManager(),
      );
      uncapped.enqueueSeenEmotes(makeEmotes(7));
      // 7 emotes, 5 dequeued by the first step: 2 remain queued.
      expect(uncapped.precacheQueueLengthForTesting, 2);
    });

    test('one-time migration sets the flag once', () async {
      SharedPreferences.setMockInitialValues({});
      PathProviderPlatform.instance = _FakePathProvider(
        Directory.systemTemp.path,
      );
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        cacheManager: testCacheManager(),
      );
      await manager.startCacheGc();
      manager.dispose();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('emote_gc_migrated_v1'), isTrue);
      // v2 migration cleared the v1 DefaultCacheManager orphans once.
      expect(prefs.getBool('emote_gc_migrated_v2'), isTrue);

      // Second start skips migration and enforces the cap once more.
      final manager2 = EmoteManager(
        fetchStagger: Duration.zero,
        cacheManager: testCacheManager(),
      );
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
        expect(
          manager.globalEmotesByProvider().values.expand((e) => e),
          contains(predicate((GenericEmote e) => e.code == 'GlobalE')),
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('emotes3_global'), persisted);
      },
    );

    test(
      'globalEmotesByProvider groups by provider in display order',
      () async {
        final persisted = jsonEncode({
          'ts': DateTime.now()
              .subtract(const Duration(days: 1))
              .toIso8601String(),
          'tier': EmoteFetchTier.nothing.index,
          'emotes': [
            makeTestEmote(
              id: 'g1',
              code: 'A_Ffz',
              type: EmoteType.ffz,
            ).toJson(),
            makeTestEmote(
              id: 'g2',
              code: 'B_Bttv',
              type: EmoteType.bttv,
            ).toJson(),
            makeTestEmote(
              id: 'g3',
              code: 'C_Twitch',
              type: EmoteType.twitch,
            ).toJson(),
            makeTestEmote(
              id: 'g4',
              code: 'D_SevenTv',
              type: EmoteType.sevenTv,
            ).toJson(),
            makeTestEmote(
              id: 'g5',
              code: 'A_SevenTv',
              type: EmoteType.sevenTv,
            ).toJson(),
          ],
        });
        SharedPreferences.setMockInitialValues({'emotes3_global': persisted});
        final manager = EmoteManager(
          fetchStagger: Duration.zero,
          tier: EmoteFetchTier.nothing,
        );

        await manager.preloadGlobalEmotes();

        final byProvider = manager.globalEmotesByProvider();
        expect(byProvider.keys.toList(), [
          'SevenTV',
          'Twitch',
          'BetterTTV',
          'FrankerFaceZ',
        ]);
        // Each group is sorted by code.
        expect(byProvider['SevenTV']!.map((e) => e.code).toList(), [
          'A_SevenTv',
          'D_SevenTv',
        ]);
        expect(byProvider['Twitch']!.single.code, 'C_Twitch');
        expect(byProvider['BetterTTV']!.single.code, 'B_Bttv');
        expect(byProvider['FrankerFaceZ']!.single.code, 'A_Ffz');
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
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.nothing,
        now: () => DateTime(2026, 1, 1, 12),
        cacheManager: testCacheManager(),
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
      await pumpEventQueue();

      // The nothing tier never tracks usage or precaches.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('emote_usage'), isNull);
      expect(manager.precacheQueueLengthForTesting, 0);
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

  group('EmoteUsageRecord scoring', () {
    // Unix hour for a fixed date.
    final hour = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch ~/ 3600000;
    final now = DateTime(2026, 1, 1, 12);

    EmoteUsageRecord record({
      required DateTime lastUsedAt,
      List<int>? buckets,
      int? base,
    }) => EmoteUsageRecord(
      lastUsedAt: lastUsedAt,
      bucketBase: base ?? hour,
      buckets: buckets ?? List.filled(24, 0),
    );

    test('a just-used emote scores high even with a single view', () {
      final r = EmoteUsageRecord.bumped(
        record(lastUsedAt: now),
        hour,
        now: now,
      );
      expect(r.score(now, hour: hour), greaterThan(0.9));
    });

    test('steady daily use outranks a one-hour spam burst', () {
      // Steady: 40 uses spread evenly over the day, last use 3h ago.
      final steady = record(
        lastUsedAt: now.subtract(const Duration(hours: 3)),
        buckets: List.filled(24, 1)..[hour % 24] = 17,
      );
      // Burst: 100 uses all in one hour, 8h ago, silent since.
      final burst = record(
        lastUsedAt: now.subtract(const Duration(hours: 8)),
        buckets: List.filled(24, 0)..[(hour - 8) % 24] = 100,
      );
      final steadyScore = steady.score(now, hour: hour);
      final burstScore = burst.score(now, hour: hour);
      expect(steadyScore, greaterThan(burstScore));
      // The burst's entropy collapses its steady term to zero.
      expect(burstScore, lessThan(0.5));
    });

    test('an emote unused for a day scores near zero', () {
      // Views happened 25h ago (base anchored there); the 24h window has
      // rolled past every bucket, so only the recency term remains - and it
      // has decayed to nothing.
      final r = EmoteUsageRecord.rolledForward(
        EmoteUsageRecord(
          lastUsedAt: now.subtract(const Duration(hours: 25)),
          bucketBase: hour - 25,
          buckets: List.filled(24, 1),
        ),
        hour,
      );
      expect(r.score(now, hour: hour), lessThan(0.05));
    });

    test('uniform distribution scores higher than a clustered one', () {
      final uniform = record(
        lastUsedAt: now.subtract(const Duration(hours: 1)),
        buckets: List.filled(24, 4),
      );
      final clustered = record(
        lastUsedAt: now.subtract(const Duration(hours: 1)),
        buckets: List.filled(24, 0)
          ..[hour % 24] = 48
          ..[(hour - 1) % 24] = 48,
      );
      expect(
        uniform.score(now, hour: hour),
        greaterThan(clustered.score(now, hour: hour)),
      );
    });

    test('bumping rolls the window forward and ages out stale buckets', () {
      var r = record(lastUsedAt: now);
      r = EmoteUsageRecord.bumped(r, hour, now: now);
      // The roll on the hour+1 bump moves the window, so that hour's views
      // land in bucket 0.
      r = EmoteUsageRecord.bumped(
        r,
        hour + 1,
        now: now.add(const Duration(hours: 1)),
      );
      r = EmoteUsageRecord.bumped(
        r,
        hour + 1,
        now: now.add(const Duration(hours: 1)),
      );
      expect(r.buckets[0], 2);
      expect(r.bucketBase, hour + 1);
      // 25 hours later, everything has rolled out of the window.
      r = EmoteUsageRecord.rolledForward(r, hour + 25);
      expect(r.bucketBase, hour + 25);
      expect(r.buckets.every((b) => b == 0), isTrue);
    });

    test('json round-trip preserves buckets and last use', () {
      final r = record(
        lastUsedAt: now.subtract(const Duration(hours: 2)),
        buckets: List.filled(24, 0)..[hour % 24] = 5,
      );
      final parsed = EmoteUsageRecord.fromJson(r.toJson())!;
      expect(parsed.lastUsedAt, r.lastUsedAt);
      expect(parsed.bucketBase, r.bucketBase);
      expect(parsed.buckets, r.buckets);
      expect(parsed.score(now, hour: hour), r.score(now, hour: hour));
    });
  });
}
