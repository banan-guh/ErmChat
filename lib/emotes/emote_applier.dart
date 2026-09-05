import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../composer/composer_controller.dart';
import '../models/emote_fetch_tier.dart';
import '../models/generic_emote.dart';
import '../services/chat_store.dart';
import '../services/connectivity_service.dart';
import '../services/data_usage.dart';
import '../services/emote_cache_manager.dart';
import '../services/emote_manager.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_badge_service.dart';
import '../util/log.dart';
import '../widgets/emote_image_provider.dart';

// Shell-owned state the emote applier reads but does not own.
abstract class EmoteApplierHost extends ShellState {
  bool isMounted();
  void markDirty();
  void showSnack(String message);
}

// Emote daemon control: persisted tier/auto/cache-cap prefs, the fps-cap
// provider state, post-auth refresh, and manual reload/nuke.
class EmoteApplier {
  EmoteApplier({
    required this.emoteManager,
    required this.twitchApi,
    required this.twitchAuth,
    required this.chatStore,
    required this.badgeService,
    required this.connectivityService,
    required this.isMobile,
    required this.networkBusy,
    required this.host,
  });

  final EmoteManager emoteManager;
  final TwitchApi twitchApi;
  final TwitchAuth twitchAuth;
  final ChatStore chatStore;
  final TwitchBadgeService badgeService;
  final ConnectivityService connectivityService;
  final ValueNotifier<bool> isMobile;
  final ValueNotifier<bool> networkBusy;
  final EmoteApplierHost host;

  int manualTierIndex = EmoteFetchTier.high.index;
  EmoteFetchAutoMode autoMode = defaultEmoteFetchAutoMode;

  // Reads the persisted manual tier, auto mode, and disk-cache cap, then
  // applies them to the emote manager. Runs first in initState so emotes
  // resolve at the right tier; a persisted effective tier other than the
  // default high re-resolves caches because connect() may already have
  // fetched at the default.
  Future<void> loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      manualTierIndex =
          prefs.getInt(emoteFetchTierPrefsKey) ?? EmoteFetchTier.high.index;
      final autoIndex =
          prefs.getInt(emoteFetchAutoPrefsKey) ??
          defaultEmoteFetchAutoMode.index;
      // A corrupt/out-of-range persisted index would throw RangeError at
      // startup; fall back to the default instead.
      autoMode = autoIndex >= 0 && autoIndex < EmoteFetchAutoMode.values.length
          ? EmoteFetchAutoMode.values[autoIndex]
          : defaultEmoteFetchAutoMode;
      final loadedCacheCap =
          prefs.getInt(emoteCacheMaxPrefsKey) ?? defaultEmoteCacheMax;
      applyCacheCap(loadedCacheCap);
      final capEmoteFps = prefs.getBool('emote_cap_fps') ?? false;
      if (capEmoteFps) {
        EmoteUrlProvider.applyFpsCap(prefs.getInt('emote_fps_cap') ?? 30);
        EmoteUrlProvider.applyAdaptiveThrottle(
          prefs.getBool('emote_auto_throttle') ?? true,
        );
        EmoteUrlProvider.alwaysAnimatePanel =
            prefs.getBool('always_animate_emote_panel') ?? true;
      } else {
        // Uncapped: 60 fps is effectively native on a 60 Hz display.
        EmoteUrlProvider.applyFpsCap(60);
        EmoteUrlProvider.applyAdaptiveThrottle(false);
        EmoteUrlProvider.alwaysAnimatePanel = true;
      }
      EmoteUrlProvider.applyGifsEnabled(prefs.getBool('animate_gifs') ?? true);
      await refreshConnectivity();
      reconcileTier();
    } catch (e) {
      logDebug('_loadEmotePrefs failed: $e');
    }
  }

  /// Applies emote frame-rate provider state when the master 'Cap emote FPS'
  /// toggle changes.  When off, emotes run uncapped (fpsCap 60 ~= native 60 Hz)
  /// with adaptive throttling disabled; the three sub-settings are hidden.
  void setCapFps(bool enabled) {
    SharedPreferences.getInstance().then((prefs) {
      if (enabled) {
        EmoteUrlProvider.applyFpsCap(prefs.getInt('emote_fps_cap') ?? 30);
        EmoteUrlProvider.applyAdaptiveThrottle(
          prefs.getBool('emote_auto_throttle') ?? true,
        );
        EmoteUrlProvider.alwaysAnimatePanel =
            prefs.getBool('always_animate_emote_panel') ?? true;
      } else {
        EmoteUrlProvider.applyFpsCap(60);
        EmoteUrlProvider.applyAdaptiveThrottle(false);
        EmoteUrlProvider.alwaysAnimatePanel = true;
      }
    });
  }

  Future<void> refreshConnectivity() async {
    // The service seeds itself in init() and corrects on later events, so
    // here we just read its cached state (avoiding a redundant plugin probe).
    isMobile.value = connectivityService.isMobile;
  }

  // Computes the effective tier from the manual tier + auto mode and applies
  // it if it changed. Called at launch, on manual/auto setting changes, and
  // on connectivity changes.
  void reconcileTier() {
    final effective = effectiveEmoteFetchTier(
      manual: EmoteFetchTier.values[manualTierIndex],
      auto: autoMode,
      isMobile: isMobile.value,
    );
    if (effective == emoteManager.tier) return;
    applyTierTo(effective);
  }

  void applyTier(int index) {
    manualTierIndex = index;
    reconcileTier();
  }

  void applyAutoMode(EmoteFetchAutoMode mode) {
    autoMode = mode;
    reconcileTier();
  }

  void applyTierTo(EmoteFetchTier tier) {
    final oldTier = emoteManager.tier;
    try {
      emoteManager.tier = tier;
      DataUsageStats.I.setContext(tier: tier, isMobile: isMobile.value);
      if (tier == EmoteFetchTier.nothing) {
        // Nothing tier: the resolution is null, so no new fetches happen, but we
        // must NOT evict the in-memory registry. Cached emotes keep rendering
        // from disk; wiping would force a full re-resolve (and its rebuild
        // storm) on every toggle.
        if (host.isMounted()) host.markDirty();
      } else {
        // A "no-diff -> diff" switch (e.g. low -> high) introduces resolutions
        // the old tier never fetched, so force-fetch the new emote URLs. A
        // switch that stays within already-fetched resolutions (e.g. high ->
        // medium) reuses the cached tier instead of re-downloading. No evict:
        // successful fetches replace the caches wholesale, and evicting
        // mid-session breaks the connected 7TV WS client's delta state
        // (same hazard as the reload path).
        final needsDiff = _tierAddsResolution(oldTier, tier);
        emoteManager.preloadGlobalEmotes(force: needsDiff);
        for (final c in chatStore.channels) {
          emoteManager.resolveEmotes(
            c,
            chatStore.channelUserIds[c],
            force: needsDiff,
          );
        }
        if (host.isMounted()) host.markDirty();
      }
    } catch (e) {
      logDebug('_applyTier failed: $e');
    }
  }

  /// True when [neu] fetches resolutions [old] did not, i.e. a manual switch
  /// from a no-diff tier to a diff tier that requires re-fetching emote URLs.
  bool _tierAddsResolution(EmoteFetchTier old, EmoteFetchTier neu) {
    final oldSet = _tierResolutions(old);
    return _tierResolutions(neu).any((r) => !oldSet.contains(r));
  }

  Set<EmoteResolution> _tierResolutions(EmoteFetchTier tier) => switch (tier) {
    EmoteFetchTier.nothing => const {},
    EmoteFetchTier.low => const {EmoteResolution.low},
    EmoteFetchTier.medium => const {EmoteResolution.medium},
    EmoteFetchTier.high => const {EmoteResolution.medium, EmoteResolution.high},
  };

  void applyCacheCap(int cap) {
    emoteManager.cacheCap = cap;
  }

  Future<bool> refreshAfterAuth({bool force = false}) async {
    try {
      for (final channel in chatStore.channels) {
        final userId = await twitchApi.getUserId(twitchAuth, channel);
        if (userId != null) {
          chatStore.channelUserIds[channel] = userId;
        }
      }
      // No evict here: a force fetch replaces the caches wholesale and the
      // per-provider stashes retain the previous data when a provider fails.
      // Evicting mid-session wrecked live state instead: the connected 7TV
      // WS client kept applying deltas, and updateSevenTvEmotes rebuilt a
      // null cache from a single delta's added list, which _reapplyLiveSevenTv
      // then propagated over every later rebuild.
      // Await so global emote metadata is present before the post-refresh
      // rebuild; unawaited left a window where global emotes rendered as text.
      await emoteManager.preloadGlobalEmotes(force: force);
      emoteManager.viewerTwitchId = twitchAuth.userId;
      await emoteManager.loadViewerPersonalSevenTvSets();
      badgeService.resetCaches();
      await badgeService.fetchGlobalBadges(twitchAuth);
      for (final channel in chatStore.channels) {
        final userId = chatStore.channelUserIds[channel];
        if (userId != null) {
          badgeService.fetchChannelBadges(twitchAuth, userId, channel);
        }
      }
      await Future.wait(
        chatStore.channels.map(
          (c) => emoteManager.resolveEmotes(
            c,
            chatStore.channelUserIds[c],
            force: force,
          ),
        ),
      );
      if (host.isMounted()) host.markDirty();
      return true;
    } catch (e) {
      logDebug('_refreshEmotesAfterAuth failed: $e');
      if (host.isMounted()) host.markDirty();
      return false;
    }
  }

  // Manual "Reload emotes": diff refresh. Re-fetches emote metadata
  // (catalogues + subs) for all channels without touching in-memory state,
  // so live 7TV WS deltas and cached images stay valid. Force bypasses the
  // fresh-cache short-circuits so third-party catalogues (7TV/BTTV/FFZ) are
  // pulled again, not just Twitch.
  Future<void> reload() => runRefresh(nuke: false);

  // Nuke (emotes settings): destroy everything, then refetch from the
  // network. Besides the in-memory state this also drops the persisted
  // metadata and the image caches, so emotes visibly re-buffer instead of
  // being instantly restored from disk.
  Future<void> runRefresh({required bool nuke}) async {
    networkBusy.value = true;
    // Discard failures from before this refresh so the report below only
    // reflects fetches this refresh triggered.
    emoteManager.takeFetchFailures();
    try {
      if (nuke) {
        await emoteManager.wipePersisted();
        emoteManager.evictGlobal();
        for (final channel in chatStore.channels) {
          emoteManager.evictChannel(channel);
        }
        await EmoteCacheManager().emptyCache();
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        // Rebuild now, while everything is empty, so the nuke is visible
        // instead of being instantly papered over by the refetch.
        emoteManager.notifyStateCleared();
      }
      final ok = await refreshAfterAuth(force: true);
      // Subscriber emotes aren't covered by the global/channel refresh; re-fetch
      // the sets already known from a prior USERSTATE.
      var subFailed = false;
      if (ok && twitchAuth.isConfigured) {
        try {
          await emoteManager.reloadUserEmoteSets(
            twitchAuth,
            chatStore.channelUserIds,
          );
        } catch (e) {
          subFailed = true;
          logDebug('_reloadEmotes: sub emote reload failed: $e');
        }
      }
      if (!host.isMounted()) return;
      String message;
      if (!ok) {
        message = 'Emote reload failed';
      } else {
        final failed = emoteManager.takeFetchFailures();
        if (subFailed) failed.add('sub emotes');
        message = failed.isEmpty
            ? 'Emotes reloaded'
            : 'Emotes failed to load for ${failed.join(', ')}';
      }
      host.showSnack(message);
    } finally {
      networkBusy.value = false;
    }
  }

  // Loads the account's subscriber emotes from the IRC emote-sets tag
  // (GLOBALUSERSTATE/USERSTATE), the authoritative source of which emote sets
  // the account can use (the Helix /chat/emotes/user endpoint omits certain
  // grants, e.g. bot accounts). USERSTATE is channel-scoped; GLOBALUSERSTATE
  // (null channel) is the account-wide union. The actual fetch, owner-login
  // resolution, and per-channel storage all live in EmoteManager (the emote
  // daemon); this is a thin forwarder so HomeScreen stays out of emote state.
  Future<void> loadUserEmoteSets(
    String? channel,
    List<String> emoteSetIds,
  ) async {
    if (!twitchAuth.isConfigured) return;
    await emoteManager.loadUserEmoteSets(
      emoteSetIds,
      twitchAuth,
      chatStore.channelUserIds,
    );
  }

  // Re-join may have opened channels whose sub-emote owners were previously
  // unknown; heal their labels in the emote daemon (no re-fetch needed).
  Future<void> refreshSubEmoteOwners() async {
    if (twitchAuth.isConfigured) {
      unawaited(
        emoteManager.loadUserEmoteSets(
          [],
          twitchAuth,
          chatStore.channelUserIds,
        ),
      );
    }
  }
}
