import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/emote_fetch_tier.dart';

void main() {
  group('EmoteFetchAutoMode helpers', () {
    test('effectiveEmoteFetchTier with auto off returns the manual tier', () {
      for (final tier in EmoteFetchTier.values) {
        expect(
          effectiveEmoteFetchTier(
            manual: tier,
            auto: EmoteFetchAutoMode.off,
            isMobile: false,
          ),
          tier,
        );
        expect(
          effectiveEmoteFetchTier(
            manual: tier,
            auto: EmoteFetchAutoMode.off,
            isMobile: true,
          ),
          tier,
        );
      }
    });

    test('balanced picks high on wifi, low on cellular', () {
      bool isMobile = false;
      expect(
        effectiveEmoteFetchTier(
          manual: EmoteFetchTier.medium,
          auto: EmoteFetchAutoMode.balanced,
          isMobile: isMobile,
        ),
        EmoteFetchTier.high,
      );
      isMobile = true;
      expect(
        effectiveEmoteFetchTier(
          manual: EmoteFetchTier.medium,
          auto: EmoteFetchAutoMode.balanced,
          isMobile: isMobile,
        ),
        EmoteFetchTier.low,
      );
    });

    test('aggressive picks medium on wifi, nothing on cellular', () {
      bool isMobile = false;
      expect(
        effectiveEmoteFetchTier(
          manual: EmoteFetchTier.high,
          auto: EmoteFetchAutoMode.aggressive,
          isMobile: isMobile,
        ),
        EmoteFetchTier.medium,
      );
      isMobile = true;
      expect(
        effectiveEmoteFetchTier(
          manual: EmoteFetchTier.high,
          auto: EmoteFetchAutoMode.aggressive,
          isMobile: isMobile,
        ),
        EmoteFetchTier.nothing,
      );
    });

    test('labels and subtitles cover every mode', () {
      expect(EmoteFetchAutoMode.values.length, 3);
      expect(EmoteFetchAutoMode.off.label, 'Off');
      expect(EmoteFetchAutoMode.balanced.label, 'Balanced');
      expect(EmoteFetchAutoMode.aggressive.label, 'Aggressive');
      for (final mode in EmoteFetchAutoMode.values) {
        expect(mode.subtitle, isNotEmpty);
      }
    });

    test('prefs keys are distinct', () {
      expect(emoteFetchAutoPrefsKey, isNot(emoteFetchTierPrefsKey));
      expect(emoteFetchAutoPrefsKey, isNot(emoteCacheMaxPrefsKey));
    });

    test('default auto mode is balanced', () {
      expect(defaultEmoteFetchAutoMode, EmoteFetchAutoMode.balanced);
    });
  });
}
