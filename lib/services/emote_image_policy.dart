/// Eviction-priority contract the image byte cache reads.
///
/// Implemented by the emote usage registry. The image module depends only on
/// this interface, never on the registry type, so bytes -> policy is a
/// one-way dependency.
abstract interface class EmoteImagePolicy {
  /// Keep-priority score for [url], or null when the URL has no history.
  double? score(String url);

  /// Last-use time for [url], or null when the URL has no history.
  DateTime? lastUsedAt(String url);
}
