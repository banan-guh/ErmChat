import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/emote_images.dart';
import 'app_providers.dart';

/// App-scope image byte owner. The manager constructs and disposes it; this
/// provider exposes it to the render path.
final emoteImagesProvider = Provider<EmoteImages>((ref) {
  return ref.watch(emoteManagerProvider).images;
});
