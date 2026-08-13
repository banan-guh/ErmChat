import 'generic_emote.dart';

/// Emote-fetching behavior tier, adjustable in the Emotes settings screen.
enum EmoteFetchTier {
  /// Render only whatever is already cached; fetch nothing at all.
  nothing,

  /// Fetch rakes + subscriber emotes at 1x, cache forever.
  low,

  /// Fetch rakes + subscriber emotes at 2x, refresh every 48h.
  medium,

  /// 2x with on-demand 3x assets, refresh every 24h (current behavior).
  high,
}

extension EmoteFetchTierX on EmoteFetchTier {
  String get label => switch (this) {
    EmoteFetchTier.nothing => 'Nothing',
    EmoteFetchTier.low => 'Low',
    EmoteFetchTier.medium => 'Medium',
    EmoteFetchTier.high => 'High',
  };

  String get subtitle => switch (this) {
    EmoteFetchTier.nothing => 'Show only already-cached emotes, never fetch',
    EmoteFetchTier.low => 'Low-res 1x emotes, cached forever (data saver)',
    EmoteFetchTier.medium => '2x emotes, normal updates',
    EmoteFetchTier.high => '2x emotes with 3x sheet detail, freshest',
  };

  /// Image resolution used when this tier fetches. Null for `nothing`.
  EmoteResolution? get resolution => switch (this) {
    EmoteFetchTier.nothing => null,
    EmoteFetchTier.low => EmoteResolution.low,
    EmoteFetchTier.medium => EmoteResolution.medium,
    EmoteFetchTier.high => EmoteResolution.high,
  };
}

const emoteFetchTierPrefsKey = 'emote_fetch_tier';
const emoteCacheMaxPrefsKey = 'emote_cache_max';
const emoteFetchAutoPrefsKey = 'emote_fetch_auto';
const defaultEmoteCacheMax = 500;
const minEmoteCacheMax = 0;
const maxEmoteCacheMax = 1500;

/// Default auto mode when nothing is persisted: pick by connectivity.
const defaultEmoteFetchAutoMode = EmoteFetchAutoMode.balanced;

/// Auto tier selection: pick a tier from connectivity instead of the manual
/// slider. Off keeps the manual tier; the others pick Wi-Fi vs cellular.
enum EmoteFetchAutoMode { off, balanced, aggressive }

extension EmoteFetchAutoModeX on EmoteFetchAutoMode {
  String get label => switch (this) {
    EmoteFetchAutoMode.off => 'Off',
    EmoteFetchAutoMode.balanced => 'Balanced',
    EmoteFetchAutoMode.aggressive => 'Aggressive',
  };

  String get subtitle => switch (this) {
    EmoteFetchAutoMode.off => 'Always use the selected tier',
    EmoteFetchAutoMode.balanced => 'High on Wi-Fi, Low on cellular',
    EmoteFetchAutoMode.aggressive => 'Medium on Wi-Fi, nothing on cellular',
  };
}

/// Effective tier for a connectivity state. Manual tier applies when auto is
/// off; otherwise the mode picks per `isMobile` (true = cellular data).
EmoteFetchTier effectiveEmoteFetchTier({
  required EmoteFetchTier manual,
  required EmoteFetchAutoMode auto,
  required bool isMobile,
}) {
  if (auto == EmoteFetchAutoMode.off) return manual;
  return switch (auto) {
    EmoteFetchAutoMode.balanced =>
      isMobile ? EmoteFetchTier.low : EmoteFetchTier.high,
    EmoteFetchAutoMode.aggressive =>
      isMobile ? EmoteFetchTier.nothing : EmoteFetchTier.medium,
    EmoteFetchAutoMode.off => manual,
  };
}
