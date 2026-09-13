import 'dart:async';

import '../models/emote_fetch_tier.dart';
import '../emotes/emote.dart';
import '../chat/chat.dart';
import '../util/connectivity.dart';
import '../util/data_usage.dart';
import '../util/prefs.dart';
import '../util/log.dart';
import 'emote_manager.dart';
import 'emote_signals.dart';
import 'seven_tv_event_client.dart';
import 'twitch_api.dart';
import 'twitch_auth.dart';
import 'twitch_badge_service.dart';

// Emote daemon control: persisted tier/auto/cache-cap prefs, post-auth
// refresh, and manual reload/nuke.
class EmoteController {
  EmoteController({
    required this.emoteManager,
    required this.twitchApi,
    required this.twitchAuth,
    required this.chat,
    required this.badgeService,
    required this.connectivityService,
    required this.signals,
    required this.getChannelUserIds,
    required this.sevenTvClient,
    required this.applyAnimationsEnabled,
    required this.clearImageCache,
  });

  final EmoteManager emoteManager;
  final TwitchApi twitchApi;
  final TwitchAuth twitchAuth;
  final Chat chat;
  final TwitchBadgeService badgeService;
  final ConnectivityService connectivityService;
  final EmoteSignals signals;
  final SevenTvEventClient sevenTvClient;

  /// Render-side port: toggles emote animation playback.
  final void Function(bool enabled) applyAnimationsEnabled;

  /// Render-side port: drops the Flutter image cache after a nuke.
  final void Function() clearImageCache;

  /// Live open-channel -> broadcaster-id map, read at use time.
  final Map<String, String> Function() getChannelUserIds;

  StreamSubscription<SevenTvEntitlementEvent>? _entitlementSub;

  /// Boot entry point: persisted prefs, cache GC, the 7TV entitlement stream,
  /// and the first account prime. The shell calls this once.
  void start() {
    unawaited(loadPrefs());
    primeForAccount();
    unawaited(emoteManager.startCacheGc());
    _entitlementSub ??= sevenTvClient.onEntitlement.listen(
      emoteManager.applySevenTvEntitlement,
    );
  }

  /// Sets the account token + viewer id and kicks off the initial fetches.
  void primeForAccount() {
    emoteManager.accessToken = twitchAuth.accessToken;
    emoteManager.viewerTwitchId = twitchAuth.userId;
    unawaited(emoteManager.preloadGlobalEmotes());
    unawaited(emoteManager.loadViewerPersonalSevenTvSets());
  }

  /// Auth changed without an account switch: re-prime and refetch.
  Future<void> onAuthChanged() async {
    primeForAccount();
    await refreshAfterAuth();
  }

  /// Account switch: drop the previous account's emote state, then re-prime
  /// and refetch for the new account.
  Future<void> onAccountChanged() async {
    emoteManager.resetUserEmoteState();
    primeForAccount();
    await refreshAfterAuth();
  }

  /// Cancels the entitlement listener. The provider owns teardown.
  void dispose() {
    _entitlementSub?.cancel();
    _entitlementSub = null;
  }

  int manualTierIndex = EmoteFetchTier.high.index;
  EmoteFetchAutoMode autoMode = defaultEmoteFetchAutoMode;

  // Reads the persisted manual tier, auto mode, and disk-cache cap, then
  // applies them to the emote manager. Runs first in initState so emotes
  // resolve at the right tier; a persisted effective tier other than the
  // default high re-resolves caches because connect() may already have
  // fetched at the default.
  Future<void> loadPrefs() async {
    try {
      final prefs = await Prefs.load();
      manualTierIndex = prefs.emoteFetchTier;
      final autoIndex = prefs.emoteFetchAuto;
      // A corrupt/out-of-range persisted index would throw RangeError at
      // startup; fall back to the default instead.
      autoMode = autoIndex >= 0 && autoIndex < EmoteFetchAutoMode.values.length
          ? EmoteFetchAutoMode.values[autoIndex]
          : defaultEmoteFetchAutoMode;
      applyCacheCap(prefs.emoteCacheMax);
      applyAnimationsEnabled(prefs.animateGifs);
      await _applyConnectivityContext();
      reconcileTier();
    } catch (e) {
      logDebug('loadPrefs failed: $e');
    }
  }

  Future<void> _applyConnectivityContext() async {
    // The service seeds itself in init() and corrects on later events, so
    // here we just seed the data-usage context from its cached state.
    DataUsageStats.I.setContext(isMobile: connectivityService.isMobile);
  }

  // Computes the effective tier from the manual tier + auto mode and applies
  // it if it changed. Called at launch, on manual/auto setting changes, and
  // on connectivity changes.
  void reconcileTier() {
    final effective = effectiveEmoteFetchTier(
      manual: EmoteFetchTier.values[manualTierIndex],
      auto: autoMode,
      isMobile: connectivityService.isMobile,
    );
    if (effective == emoteManager.tier) return;
    _applyTier(effective);
  }

  void setManualTier(int index) {
    manualTierIndex = index;
    reconcileTier();
  }

  void applyAutoMode(EmoteFetchAutoMode mode) {
    autoMode = mode;
    reconcileTier();
  }

  void _applyTier(EmoteFetchTier tier) {
    final oldTier = emoteManager.tier;
    try {
      emoteManager.tier = tier;
      DataUsageStats.I.setContext(
        tier: tier,
        isMobile: connectivityService.isMobile,
      );
      if (tier == EmoteFetchTier.nothing) {
        // Nothing tier: the resolution is null, so no new fetches happen, but we
        // must NOT evict the in-memory registry. Cached emotes keep rendering
        // from disk; wiping would force a full re-resolve (and its rebuild
        // storm) on every toggle.
        emoteManager.notifyConfigChanged();
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
        for (final c in chat.names) {
          emoteManager.resolveEmotes(
            c,
            chat.channelFor(c)?.info.broadcasterId,
            force: needsDiff,
          );
        }
        if (needsDiff) {
          // Sub sets and personal sets are keyed by fetched id, so the
          // force fetch above skips them; re-pull at the new resolution.
          unawaited(
            emoteManager.reloadUserEmoteSets(twitchAuth, getChannelUserIds()),
          );
          unawaited(emoteManager.loadViewerPersonalSevenTvSets(force: true));
        }
        emoteManager.notifyConfigChanged();
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
      for (final channel in chat.names) {
        final userId = await twitchApi.getUserId(twitchAuth, channel);
        if (userId != null) {
          chat.channelFor(channel)?.info.setBroadcasterId(userId);
        }
      }
      // No evict here: a force fetch replaces the caches wholesale and the
      // per-provider lists retain the previous data when a provider fails.
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
      for (final channel in chat.names) {
        final userId = chat.channelFor(channel)?.info.broadcasterId;
        if (userId != null) {
          badgeService.fetchChannelBadges(twitchAuth, userId, channel);
        }
      }
      await Future.wait(
        chat.names.map(
          (c) => emoteManager.resolveEmotes(
            c,
            chat.channelFor(c)?.info.broadcasterId,
            force: force,
          ),
        ),
      );
      emoteManager.notifyConfigChanged();
      return true;
    } catch (e) {
      logDebug('refreshAfterAuth failed: $e');
      emoteManager.notifyConfigChanged();
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
    signals.busy.emit(true);
    // Discard failures from before this refresh so the report below only
    // reflects fetches this refresh triggered.
    emoteManager.takeFetchFailures();
    try {
      if (nuke) {
        await emoteManager.wipePersisted();
        emoteManager.evictGlobal();
        for (final channel in chat.names) {
          emoteManager.evictChannel(channel);
        }
        await emoteManager.clearImageCache();
        clearImageCache();
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
            getChannelUserIds(),
          );
        } catch (e) {
          subFailed = true;
          logDebug('runRefresh: sub emote reload failed: $e');
        }
      }
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
      signals.snack.emit(message);
    } finally {
      signals.busy.emit(false);
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
      getChannelUserIds(),
    );
  }

  // Re-join may have opened channels whose sub-emote owners were previously
  // unknown; heal their labels in the emote daemon (no re-fetch needed).
  Future<void> refreshSubEmoteOwners() async {
    if (twitchAuth.isConfigured) {
      unawaited(
        emoteManager.loadUserEmoteSets([], twitchAuth, getChannelUserIds()),
      );
    }
  }
}
