import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/emote_fetch_tier.dart';
import '../services/emote_fetcher.dart';
import '../services/emote_meta_store.dart';
import '../services/emote_persistence.dart';
import '../services/emote_usage_registry.dart';
import '../services/emote_visibility.dart';
import '../services/seven_tv_personal_sets.dart';
import '../services/twitch_emote_sets.dart';
import 'app_providers.dart';
import 'emote_store_providers.dart';
import 'feature_providers.dart';

/// App-scope emote owners and config. Each is constructed once at app scope;
/// [EmoteManager] receives the same instances through injection instead of
/// constructing them. Owners that hold resources register `ref.onDispose`.

/// Provider visibility plus unlisted-7TV rendering, loaded from prefs.
final emoteVisibilityProvider = Provider<EmoteVisibility>((ref) {
  final visibility = EmoteVisibility();
  ref.onDispose(visibility.dispose);
  return visibility;
});

/// Effective fetch tier. [EmoteController] computes it from the manual/auto
/// settings and connectivity; the fetcher and owners read it at call time.
class EmoteFetchTierNotifier extends Notifier<EmoteFetchTier> {
  @override
  EmoteFetchTier build() => EmoteFetchTier.high;

  void set(EmoteFetchTier value) {
    if (state == value) return;
    state = value;
  }
}

final emoteFetchTierProvider =
    NotifierProvider<EmoteFetchTierNotifier, EmoteFetchTier>(
      EmoteFetchTierNotifier.new,
    );

/// Disk-cache cap for emote images. Written by the settings path, read by the
/// image owner and the usage registry.
class EmoteCacheCapNotifier extends Notifier<int> {
  @override
  int build() => defaultEmoteCacheMax;

  void set(int value) {
    final clamped = value.clamp(minEmoteCacheMax, maxEmoteCacheMax).toInt();
    if (state == clamped) return;
    state = clamped;
  }
}

final emoteCacheCapProvider = NotifierProvider<EmoteCacheCapNotifier, int>(
  EmoteCacheCapNotifier.new,
);

/// Emote network fetching and fetch policy.
final emoteFetcherProvider = Provider<EmoteFetcher>((ref) {
  final fetcher = EmoteFetcher(
    now: DateTime.now,
    tier: () => ref.read(emoteFetchTierProvider),
    isProviderEnabled: (type) =>
        ref.read(emoteVisibilityProvider).isProviderEnabled(type),
    accessToken: () => ref.read(twitchAuthProvider).accessToken,
    probe: ref.read(connectivityServiceProvider).checkConnectivity,
  );
  ref.onDispose(fetcher.dispose);
  return fetcher;
});

/// Usage history plus recents; also the image eviction policy.
final emoteUsageRegistryProvider = Provider<EmoteUsageRegistry>((ref) {
  final usage = EmoteUsageRegistry(
    capacity: () => ref.read(emoteCacheCapProvider),
  );
  ref.onDispose(usage.dispose);
  return usage;
});

/// Viewer and foreign 7TV personal sets.
final sevenTvPersonalSetsProvider = Provider<SevenTvPersonalSets>((ref) {
  final store = ref.watch(emoteStoreProvider);
  return SevenTvPersonalSets(
    fetcher: ref.watch(emoteFetcherProvider),
    metaStore: EmoteMetaStore.I,
    tier: () => ref.read(emoteFetchTierProvider),
    isProviderEnabled: (type) =>
        ref.read(emoteVisibilityProvider).isProviderEnabled(type),
    notifyChanged: store.notifyStateCleared,
    viewerTwitchIdSource: () => ref.read(sessionProvider).userId,
  );
});

/// Twitch account emote sets (subs plus unlocks).
final twitchEmoteSetsProvider = Provider<TwitchEmoteSets>((ref) {
  return TwitchEmoteSets(
    fetcher: ref.watch(emoteFetcherProvider),
    store: ref.watch(emoteStoreProvider),
    tier: () => ref.read(emoteFetchTierProvider),
    getChannelUserIds: ref.read(channelUserIdsProvider),
  );
});

/// Global/channel catalog persistence.
final emotePersistenceProvider = Provider<EmotePersistence>((ref) {
  final twitchSets = ref.watch(twitchEmoteSetsProvider);
  return EmotePersistence(
    tier: () => ref.read(emoteFetchTierProvider),
    isAccountUnlock: (id) =>
        twitchSets.isAccountUnlocked(id) || twitchSets.isCatalogUnlocked(id),
    metaStore: EmoteMetaStore.I,
  );
});
