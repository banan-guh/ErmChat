import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/emote_persistence.dart';
import '../services/emote_usage_registry.dart';
import '../services/seven_tv_personal_sets.dart';
import '../services/twitch_emote_sets.dart';
import 'app_providers.dart';

/// App-scope emote owners. [EmoteManager] constructs and disposes them; these
/// providers expose them to any consumer that needs a narrower doorway than
/// the manager facade.
final emoteUsageRegistryProvider = Provider<EmoteUsageRegistry>(
  (ref) => ref.watch(emoteManagerProvider).usage,
);

final sevenTvPersonalSetsProvider = Provider<SevenTvPersonalSets>(
  (ref) => ref.watch(emoteManagerProvider).personalSets,
);

final twitchEmoteSetsProvider = Provider<TwitchEmoteSets>(
  (ref) => ref.watch(emoteManagerProvider).twitchSets,
);

final emotePersistenceProvider = Provider<EmotePersistence>(
  (ref) => ref.watch(emoteManagerProvider).persistence,
);
