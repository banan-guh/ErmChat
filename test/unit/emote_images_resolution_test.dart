import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/emotes/emote_picker.dart';
import 'package:ermchat/models/emote_fetch_tier.dart';
import 'package:ermchat/services/emote_cache_manager.dart';
import 'package:ermchat/services/emote_images.dart';
import 'package:ermchat/services/emote_usage_registry.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

const _small = 'https://cdn.test/small.png';
const _medium = 'https://cdn.test/medium.png';
const _large = 'https://cdn.test/large.png';

const _allScales = {
  EmoteScale.small: _small,
  EmoteScale.medium: _medium,
  EmoteScale.large: _large,
};

Emote _emote(Map<EmoteScale, String> scales) =>
    Emote(id: 'emote', code: 'Test', meta: const BttvMeta(), scales: scales);

class _FakeFileInfo extends Fake implements FileInfo {}

class _FakeCacheManager extends Fake implements EmoteCacheManager {
  _FakeCacheManager(this.cached);

  final Set<String> cached;
  final probes = <String>[];

  @override
  set policy(EmoteImagePolicy? value) {}

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    probes.add(key);
    return cached.contains(key) ? _FakeFileInfo() : null;
  }
}

EmoteImages _images(_FakeCacheManager cache) {
  final images = EmoteImages(
    cacheManager: cache,
    now: () => DateTime(2026, 1, 1),
  );
  addTearDown(images.dispose);
  return images;
}

List<String> _expectedProbes(
  Emote emote,
  EmoteSurface surface,
  Set<String> cached,
) {
  final probes = <String>[];
  for (final scale in EmotePicker.preferences[surface]!) {
    final url = emote.urlFor(scale);
    if (url == null) continue;
    probes.add(url);
    if (cached.contains(url)) break;
  }
  return probes;
}

void main() {
  test(
    'async resolve probes in preference order and stops at the first hit',
    () async {
      for (final surface in EmoteSurface.values) {
        final preferences = EmotePicker.preferences[surface]!;
        for (var hit = 0; hit < preferences.length; hit++) {
          final cachedScale = preferences[hit];
          final cache = _FakeCacheManager({_allScales[cachedScale]!});
          final images = _images(cache)..setTier(EmoteFetchTier.nothing);

          final result = await images.resolve(_emote(_allScales), surface);

          expect(cache.probes, [
            for (final scale in preferences.take(hit + 1)) _allScales[scale]!,
          ], reason: '${surface.name} hit ${cachedScale.name}');
          expect(result, (
            url: _allScales[cachedScale]!,
            placeholder: null,
          ), reason: '${surface.name} hit ${cachedScale.name}');
        }
      }
    },
  );

  test(
    'async resolve preserves picker results for every tier and surface',
    () async {
      final scaleMaps = <String, Map<EmoteScale, String>>{
        'all scales': _allScales,
        'only small': const {EmoteScale.small: _small},
        'no medium': const {EmoteScale.small: _small, EmoteScale.large: _large},
        'no scales': const {},
      };
      final cachedSets = <String, Set<String>>{
        'none': const {},
        'small': const {_small},
        'medium': const {_medium},
        'large': const {_large},
        'medium and large': const {_medium, _large},
        'all': const {_small, _medium, _large},
      };

      for (final surface in EmoteSurface.values) {
        for (final tier in EmoteFetchTier.values) {
          for (final entry in scaleMaps.entries) {
            final emote = _emote(entry.value);
            for (final cachedEntry in cachedSets.entries) {
              final cached = cachedEntry.value;
              final cache = _FakeCacheManager(cached);
              final images = _images(cache)..setTier(tier);
              final reason =
                  '${surface.name}/${tier.name}/${entry.key}/${cachedEntry.key}';
              final expected = EmotePicker.resolve(
                emote,
                surface,
                tier,
                cached.contains,
              );

              final result = await images.resolve(emote, surface);

              expect(result, expected, reason: reason);
              expect(
                cache.probes,
                _expectedProbes(emote, surface, cached),
                reason: reason,
              );
            }
          }
        }
      }
    },
  );

  test('resolveSync still requires every scale to be memoized', () async {
    final cache = _FakeCacheManager({_medium});
    final images = _images(cache);
    final emote = _emote(_allScales);

    expect(await images.resolve(emote, EmoteSurface.chat), (
      url: _medium,
      placeholder: null,
    ));
    expect(cache.probes, [_medium]);
    expect(images.resolveSync(emote, EmoteSurface.chat), isNull);

    expect(await images.resolve(emote, EmoteSurface.card), (
      url: _large,
      placeholder: _medium,
    ));
    expect(cache.probes, [_medium, _large]);
    await images.isCached(_small);
    expect(cache.probes, [_medium, _large, _small]);
    expect(images.resolveSync(emote, EmoteSurface.card), (
      url: _large,
      placeholder: _medium,
    ));

    cache.probes.clear();
    expect(images.resolveSync(emote, EmoteSurface.chat), (
      url: _medium,
      placeholder: null,
    ));
    expect(cache.probes, isEmpty);
  });
}
