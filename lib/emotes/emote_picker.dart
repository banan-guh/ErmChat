import '../models/emote_fetch_tier.dart';
import 'emote.dart';

/// Where an emote is being rendered. Each surface has its own scale
/// preference, and the detail card may fetch a larger asset than chat.
enum EmoteSurface { chat, grid, card }

/// Pure scale policy shared by every renderer and the fetch layer. Providers
/// own which URLs exist per scale; this owns which one is shown or fetched.
///
/// Rules:
/// - The tier picks the download when nothing better is cached.
/// - A cached scale at least as good as the download target wins (a cached 2x
///   satisfies a 1x requirement).
/// - A worse cached scale is shown only while the target loads.
/// - `nothing` downloads nothing: cached scale or null.
class EmotePicker {
  const EmotePicker._();

  /// Most-preferred first. Chat and grid cap at 2x and fall back to 4x over
  /// 1x; the card wants the largest.
  static const Map<EmoteSurface, List<EmoteScale>> preferences = {
    EmoteSurface.chat: [EmoteScale.medium, EmoteScale.large, EmoteScale.small],
    EmoteSurface.grid: [EmoteScale.medium, EmoteScale.large, EmoteScale.small],
    EmoteSurface.card: [EmoteScale.large, EmoteScale.medium, EmoteScale.small],
  };

  /// Quality rank: higher is a larger asset.
  static int quality(EmoteScale scale) => switch (scale) {
    EmoteScale.small => 0,
    EmoteScale.medium => 1,
    EmoteScale.large => 2,
  };

  static EmoteScale? scaleOf(Emote emote, String url) {
    for (final entry in emote.scales.entries) {
      if (entry.value == url) return entry.key;
    }
    return null;
  }

  /// The scale the chat surface would fetch when nothing is cached, or null
  /// for nothing tier. Used by precache and usage tracking.
  static String? chatDownloadUrl(Emote emote, EmoteFetchTier tier) =>
      downloadTarget(emote, EmoteSurface.chat, tier);

  /// Most preferred scale URL for chat ignoring the tier, or null. Used where
  /// no tier is available (usage on send).
  static String? chatPreferredUrl(Emote emote) {
    for (final scale in preferences[EmoteSurface.chat]!) {
      final url = emote.urlFor(scale);
      if (url != null) return url;
    }
    return null;
  }

  /// URL the surface should fetch when no acceptable cached scale exists, or
  /// null when downloads are disabled (nothing tier) or the emote is empty.
  static String? downloadTarget(
    Emote emote,
    EmoteSurface surface,
    EmoteFetchTier tier,
  ) {
    final scale = surface == EmoteSurface.card && tier.allowsLargeDownload
        ? EmoteScale.large
        : tier.downloadScale;
    if (scale == null) return null;
    final direct = emote.urlFor(scale);
    if (direct != null) return direct;
    // Target scale absent: fall back to the most preferred available.
    for (final candidate in preferences[surface]!) {
      final url = emote.urlFor(candidate);
      if (url != null) return url;
    }
    return null;
  }

  /// Resolves the URL to render and an optional placeholder for while the
  /// target loads. Null means render the code as text (nothing cached on
  /// nothing tier, or the emote has no URLs).
  static ({String url, String? placeholder})? resolve(
    Emote emote,
    EmoteSurface surface,
    EmoteFetchTier tier,
    bool Function(String url) isCached,
  ) {
    final pref = preferences[surface]!;
    String? bestCached;
    EmoteScale? bestCachedScale;
    for (final scale in pref) {
      final url = emote.urlFor(scale);
      if (url != null && isCached(url)) {
        bestCached = url;
        bestCachedScale = scale;
        break;
      }
    }

    final target = downloadTarget(emote, surface, tier);
    if (target == null) {
      return bestCached == null ? null : (url: bestCached, placeholder: null);
    }
    final targetScale = scaleOf(emote, target);
    if (bestCached != null &&
        bestCachedScale != null &&
        targetScale != null &&
        quality(bestCachedScale) >= quality(targetScale)) {
      return (url: bestCached, placeholder: null);
    }
    return (url: target, placeholder: bestCached);
  }

  /// Cached URLs that can never be picked once a better scale exists. Only
  /// `small` is ever dominated; medium and large each have a surface.
  static List<String> dominatedScaleUrls(Emote emote) {
    final small = emote.urlFor(EmoteScale.small);
    if (small == null) return const [];
    if (emote.urlFor(EmoteScale.medium) != null ||
        emote.urlFor(EmoteScale.large) != null) {
      return [small];
    }
    return const [];
  }
}
