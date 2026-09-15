import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/emotes/emote_picker.dart';
import 'package:ermchat/models/emote_fetch_tier.dart';
import 'package:flutter_test/flutter_test.dart';

const _small = 'https://example.com/small.png';
const _medium = 'https://example.com/medium.png';
const _large = 'https://example.com/large.png';

Emote _emote({bool small = true, bool medium = true, bool large = true}) =>
    Emote(
      id: 'e1',
      code: 'E1',
      meta: const BttvMeta(),
      scales: {
        if (small) EmoteScale.small: _small,
        if (medium) EmoteScale.medium: _medium,
        if (large) EmoteScale.large: _large,
      },
    );

bool Function(String) _cached(Set<String> urls) => urls.contains;

void main() {
  group('EmotePicker.resolve chat', () {
    test('caps at cached medium even when a cached large exists', () {
      final result = EmotePicker.resolve(
        _emote(),
        EmoteSurface.chat,
        EmoteFetchTier.high,
        _cached({_small, _medium, _large}),
      );
      expect(result, isNotNull);
      expect(result!.url, _medium);
      expect(result.placeholder, isNull);
    });

    test('prefers cached medium over downloading small at low tier', () {
      final result = EmotePicker.resolve(
        _emote(),
        EmoteSurface.chat,
        EmoteFetchTier.low,
        _cached({_medium}),
      );
      expect(result, isNotNull);
      expect(result!.url, _medium);
      expect(result.placeholder, isNull);
    });

    test('downloads medium with the small cached as placeholder', () {
      final result = EmotePicker.resolve(
        _emote(),
        EmoteSurface.chat,
        EmoteFetchTier.medium,
        _cached({_small}),
      );
      expect(result, isNotNull);
      expect(result!.url, _medium);
      expect(result.placeholder, _small);
    });
  });

  group('EmotePicker.resolve card', () {
    test('targets large at high tier when nothing is cached', () {
      final result = EmotePicker.resolve(
        _emote(),
        EmoteSurface.card,
        EmoteFetchTier.high,
        _cached({}),
      );
      expect(result, isNotNull);
      expect(result!.url, _large);
      expect(result.placeholder, isNull);
    });

    test('uses a cached large with no placeholder', () {
      final result = EmotePicker.resolve(
        _emote(),
        EmoteSurface.card,
        EmoteFetchTier.high,
        _cached({_large}),
      );
      expect(result, isNotNull);
      expect(result!.url, _large);
      expect(result.placeholder, isNull);
    });
  });

  group('EmotePicker.resolve nothing tier', () {
    test('returns null when nothing is cached', () {
      final result = EmotePicker.resolve(
        _emote(),
        EmoteSurface.chat,
        EmoteFetchTier.nothing,
        _cached({}),
      );
      expect(result, isNull);
    });

    test('returns the cached scale when one exists', () {
      final result = EmotePicker.resolve(
        _emote(),
        EmoteSurface.chat,
        EmoteFetchTier.nothing,
        _cached({_small}),
      );
      expect(result, isNotNull);
      expect(result!.url, _small);
      expect(result.placeholder, isNull);
    });
  });

  group('EmotePicker.dominatedScaleUrls', () {
    test('returns small when medium exists', () {
      expect(EmotePicker.dominatedScaleUrls(_emote(large: false)), [_small]);
    });

    test('returns small when large exists', () {
      expect(EmotePicker.dominatedScaleUrls(_emote(medium: false)), [_small]);
    });

    test('returns nothing when small is the only scale', () {
      expect(
        EmotePicker.dominatedScaleUrls(_emote(medium: false, large: false)),
        isEmpty,
      );
    });

    test('returns nothing when small is absent', () {
      expect(EmotePicker.dominatedScaleUrls(_emote(small: false)), isEmpty);
    });
  });
}
