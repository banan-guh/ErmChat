import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/emote_images.dart';
import '../services/emote_url_provider.dart';
import 'app_providers.dart';

/// App-scope image byte owner. The manager constructs and disposes it; this
/// provider exposes it to the render path and installs the process default
/// used by providers constructed without an explicit owner.
final emoteImagesProvider = Provider<EmoteImages>((ref) {
  final images = ref.watch(emoteManagerProvider).images;
  EmoteUrlProvider.installDefaultImages(images);
  return images;
});
