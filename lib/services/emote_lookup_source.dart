import '../emotes/emote_catalog.dart';
import 'emote_images.dart';

/// Read-only port over the emote catalog for the render path.
///
/// The message builder needs exactly three things: whether the catalog
/// changed (to invalidate cached spans), the merged lookup for a
/// channel+sender, and the image byte owner. [EmoteManager] implements it so
/// render-path consumers stop depending on the whole manager.
abstract interface class EmoteLookupSource {
  /// Catalog version used by message span caches. Live 7TV deltas do not
  /// advance it, so already-rendered messages stay frozen.
  int get version;

  /// Image byte owner consumed by the render path.
  EmoteImages get images;

  /// Merged emotes for [channel] plus [senderTwitchId]'s personal 7TV set.
  EmoteLookup? lookup(String channel, String? senderTwitchId);
}
