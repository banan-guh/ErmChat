import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/emote_fetch_tier.dart';
import '../services/emote_controller.dart';
import '../services/emote_fetcher.dart';
import '../services/emote_images.dart';
import '../services/emote_meta_store.dart';
import '../services/emote_persistence.dart';
import '../services/emote_store.dart';
import '../services/emote_usage_registry.dart';
import '../services/emote_visibility.dart';
import '../services/seven_tv_personal_sets.dart';
import '../services/twitch_emote_sets.dart';
import '../widgets/emote_url_provider.dart';
import 'app_providers.dart';
import 'feature_providers.dart';

/// Snapshot of the emote catalog version plus the change that produced it.
/// [change] is null only for the initial state.
class EmoteState {
  const EmoteState(this.version, this.change);

  final int version;
  final EmoteChange? change;
}

final emoteStoreProvider = Provider<EmoteStore>((ref) {
  final store = EmoteStore();
  ref.onDispose(store.dispose);
  return store;
});

/// Bridges the store's typed [EmoteChange] stream to Riverpod so widgets
/// observe it with `ref.listen` instead of a manual listener. The store owns
/// no resources beyond its listener list, so teardown just detaches.
class EmoteStoreNotifier extends Notifier<EmoteState> {
  @override
  EmoteState build() {
    final store = ref.watch(emoteStoreProvider);
    void onChange(EmoteChange change) {
      state = EmoteState(store.version, change);
    }

    store.addListener(onChange);
    ref.onDispose(() => store.removeListener(onChange));
    return EmoteState(store.version, store.lastChange);
  }
}

final emoteStateProvider = NotifierProvider<EmoteStoreNotifier, EmoteState>(
  EmoteStoreNotifier.new,
);

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

/// Disk-cache cap for emote images in MB. Written by the settings path,
/// read by the image owner; the usage registry tracks it in entry units.
class EmoteCacheCapNotifier extends Notifier<int> {
  @override
  int build() => defaultEmoteCacheMb;

  void set(int value) {
    final clamped = value.clamp(minEmoteCacheMb, maxEmoteCacheMb).toInt();
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
    capacity: () =>
        emoteEntriesForCap(ref.read(emoteCacheCapProvider) * bytesPerMb),
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
    notifyChanged: () => store.notifyCatalogChanged(),
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

/// App-scope image byte owner. Uses the usage registry as its eviction policy
/// and follows the provider-owned cache cap.
final emoteImagesProvider = Provider<EmoteImages>((ref) {
  final images = EmoteImages(policy: ref.watch(emoteUsageRegistryProvider));
  images.cacheCapMb = ref.read(emoteCacheCapProvider);
  images.setTier(ref.read(emoteFetchTierProvider));
  final capSub = ref.listen(
    emoteCacheCapProvider,
    (_, next) => images.cacheCapMb = next,
  );
  final tierSub = ref.listen(
    emoteFetchTierProvider,
    (_, next) => images.setTier(next),
  );
  ref.onDispose(capSub.close);
  ref.onDispose(tierSub.close);
  ref.onDispose(images.dispose);
  return images;
});

/// Provider-owned output ports the emote controller pushes at the shell.
final emoteSignalsProvider = Provider<EmoteSignals>((ref) {
  final signals = EmoteSignals();
  ref.onDispose(signals.dispose);
  return signals;
});

/// App-scope emote daemon control (tier/auto/cache prefs, post-auth refresh,
/// manual reload/nuke) plus the emote lifecycle (boot priming, cache GC, and
/// the 7TV entitlement stream). Owns the entitlement listener; teardown
/// cancels it.
final emoteControllerProvider = Provider<EmoteController>((ref) {
  final controller = EmoteController(
    emoteManager: ref.read(emoteManagerProvider),
    twitchApi: ref.read(twitchApiProvider),
    twitchAuth: ref.read(twitchAuthProvider),
    chat: ref.read(chatProvider),
    badgeService: ref.read(badgeServiceProvider),
    connectivityService: ref.read(connectivityServiceProvider),
    signals: ref.read(emoteSignalsProvider),
    getChannelUserIds: ref.read(channelUserIdsProvider),
    sevenTvClient: ref.read(sevenTvClientProvider),
    applyAnimationsEnabled: EmoteUrlProvider.applyGifsEnabled,
    clearImageCache: () {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    },
  );
  ref.onDispose(controller.dispose);
  return controller;
});
