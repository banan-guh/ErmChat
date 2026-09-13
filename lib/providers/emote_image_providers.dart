import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/emote_images.dart';
import 'emote_owner_providers.dart';

/// App-scope image byte owner. Uses the usage registry as its eviction policy
/// and follows the provider-owned cache cap.
final emoteImagesProvider = Provider<EmoteImages>((ref) {
  final images = EmoteImages(policy: ref.watch(emoteUsageRegistryProvider));
  images.cacheCap = ref.read(emoteCacheCapProvider);
  final capSub = ref.listen(
    emoteCacheCapProvider,
    (_, next) => images.cacheCap = next,
  );
  ref.onDispose(capSub.close);
  ref.onDispose(images.dispose);
  return images;
});
