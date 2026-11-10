import 'dart:async';

import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';
import '../models/emote_fetch_tier.dart';
import '../chat/chat.dart';
import '../util/connectivity.dart';
import '../util/data_usage.dart';
import '../util/prefs.dart';
import '../util/log.dart';
import '../util/settings.dart';
import '../util/signal.dart';
import 'emote_manager.dart';
import 'seven_tv_event_client.dart';
import 'twitch_api.dart';
import 'twitch_auth.dart';
import 'twitch_badge_service.dart';

/// Output ports the emote controller pushes at the shell: a user-facing
/// notice and the manual-refresh busy flag.
class EmoteSignals {
  final ChatSignal<String> snack = ChatSignal<String>();
  final ChatSignal<bool> busy = ChatSignal<bool>();

  /// Full reload progress, from 0 to 1. Null when no full reload runs.
  final ValueNotifier<double?> progress = ValueNotifier<double?>(null);

  void dispose() {
    snack.clear();
    busy.clear();
    progress.dispose();
  }
}

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
    AppLocalizations Function()? strings,
  }) : _strings = strings ?? englishStrings;

  final AppLocalizations Function() _strings;

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
  bool _disposed = false;

  /// Boot entry point: persisted prefs, cache GC, the 7TV entitlement stream,
  /// and the first account prime. The shell calls this once.
  void start() {
    unawaited(loadPrefs());
    primeForAccount();
    unawaited(emoteManager.startCacheGc());
    _entitlementSub ??= sevenTvClient.onEntitlement.listen(_onEntitlement);
  }

  void _onEntitlement(SevenTvEntitlementEvent event) {
    unawaited(emoteManager.applySevenTvEntitlement(event));
    // A granted personal set's contents (renames, adds) reach the socket
    // only while subscribed.
    if (event.cosmeticKind == 'EMOTE_SET' &&
        event.kind != 'entitlement.delete') {
      sevenTvClient.subscribeEmoteSet(event.cosmeticId);
    }
  }

  /// Loads the viewer's personal sets, then subscribes to their live edits.
  Future<void> _loadViewerPersonalSets() async {
    await emoteManager.loadViewerPersonalSevenTvSets();
    for (final setId in emoteManager.viewerPersonalSetIds) {
      sevenTvClient.subscribeEmoteSet(setId);
    }
  }

  /// Sets the account token + viewer id and kicks off the initial fetches.
  void primeForAccount() {
    emoteManager.accessToken = twitchAuth.accessToken;
    emoteManager.viewerTwitchId = twitchAuth.userId;
    unawaited(emoteManager.preloadGlobalEmotes());
    unawaited(_loadViewerPersonalSets());
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
    _disposed = true;
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
      await Prefs.load();
      final tierIndex = Settings.emoteFetchTier.value;
      final autoIndex = Settings.emoteFetchAuto.value;
      // A corrupt/out-of-range persisted index would throw RangeError at
      // startup; fall back to the default instead.
      if (tierIndex >= 0 && tierIndex < EmoteFetchTier.values.length) {
        manualTierIndex = tierIndex;
      }
      autoMode = autoIndex >= 0 && autoIndex < EmoteFetchAutoMode.values.length
          ? EmoteFetchAutoMode.values[autoIndex]
          : defaultEmoteFetchAutoMode;
      applyCacheCap(Settings.emoteCacheMb.value);
      applyAnimationsEnabled(Settings.animateGifs.value);
      await _applyConnectivityContext();
      reconcileTier();
    } catch (e) {
      logDebug('loadPrefs failed: $e');
    }
  }

  Future<void> _applyConnectivityContext() async {
    // The service seeds itself in init() and corrects on later events, so
    // here we just seed the data-usage context from its cached state.
    DataUsageStats.I.setMobile(connectivityService.isMobile);
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
    try {
      emoteManager.tier = tier;
      DataUsageStats.I.setMobile(connectivityService.isMobile);
      emoteManager.notifyConfigChanged();
    } catch (e) {
      logDebug('_applyTier failed: $e');
    }
  }

  void applyCacheCap(int capMb) {
    emoteManager.cacheCapMb = capMb;
  }

  Future<bool> refreshAfterAuth({
    bool force = false,
    void Function()? onFetchSettled,
    void Function()? onStep,
  }) async {
    try {
      for (final channel in chat.names) {
        // Known ids skip the lookup; it runs one channel at a time.
        if (chat.channelFor(channel)?.info.broadcasterId != null) continue;
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
      await emoteManager.preloadGlobalEmotes(
        force: force,
        onFetchSettled: onFetchSettled,
      );
      emoteManager.viewerTwitchId = twitchAuth.userId;
      await _loadViewerPersonalSets();
      onStep?.call();
      badgeService.resetCaches();
      await badgeService.fetchGlobalBadges(twitchAuth);
      onStep?.call();
      // Badges and emote lists run side by side, like before the progress
      // hooks; the badge futures just settle their own progress slots.
      final badges = <Future<void>>[
        for (final channel in chat.names)
          if (chat.channelFor(channel)?.info.broadcasterId case final userId?)
            badgeService
                .fetchChannelBadges(twitchAuth, userId, channel)
                .whenComplete(() => onStep?.call())
          else
            Future<void>.sync(() {
              onStep?.call();
            }),
      ];
      final emotes = <Future<void>>[];
      for (final channel in chat.names) {
        final userId = chat.channelFor(channel)?.info.broadcasterId;
        if (userId == null) {
          // A channel without an id fetches nothing; settle its four slots.
          for (var i = 0; i < 4; i++) {
            onFetchSettled?.call();
          }
          continue;
        }
        emotes.add(
          emoteManager.resolveEmotes(
            channel,
            userId,
            force: force,
            onFetchSettled: onFetchSettled,
          ),
        );
      }
      await Future.wait([...badges, ...emotes]);
      emoteManager.notifyConfigChanged();
      return true;
    } catch (e) {
      logDebug('refreshAfterAuth failed: $e');
      emoteManager.notifyConfigChanged();
      return false;
    }
  }

  /// Manual "Reload emotes": diff refresh for the selected channel only.
  /// Force bypasses the fresh-cache short-circuits so third-party catalogues
  /// (7TV/BTTV/FFZ) are pulled again, not just Twitch.
  Future<void> reloadChannel(String channel) =>
      runRefresh(nuke: false, channel: channel);

  /// Manual "Reload all emotes": diff refresh for every open channel.
  Future<void> reload() => runRefresh(nuke: false);

  // Nuke (emotes settings): destroy everything, then refetch from the
  // network. Besides the in-memory state this also drops the persisted
  // metadata and the image caches, so emotes visibly re-buffer instead of
  // being instantly restored from disk.
  Future<void> runRefresh({required bool nuke, String? channel}) {
    // An overlapping request joins the run in flight, whose busy flag and
    // failure report it would otherwise corrupt.
    return _refreshing ??= _runRefresh(
      nuke: nuke,
      channel: channel,
    ).whenComplete(() => _refreshing = null);
  }

  Future<void>? _refreshing;

  Future<void> _runRefresh({required bool nuke, String? channel}) async {
    signals.busy.emit(true);
    // Discard failures from before this refresh so the report below only
    // reflects fetches this refresh triggered.
    emoteManager.takeFetchFailures();
    final channels = channel == null ? chat.names : [channel];
    // A nuke empties everything first, so only a reload reports a delta.
    final before = nuke ? null : emoteManager.loadedEmoteKeys(channels);
    final progress = signals.progress;
    // Global providers, personal sets, global badges, channel badges, channel
    // providers and the account's own emotes.
    final total = channel == null ? 7 + 5 * chat.names.length : 0;
    var settled = 0;
    void setProgress(double? value) {
      if (!_disposed) progress.value = value;
    }

    void step() {
      if (total == 0) return;
      settled++;
      setProgress((settled / total).clamp(0.0, 1.0));
    }

    // The channel reload uses the normal busy spinner; the full reload uses
    // the determinate bar.
    setProgress(channel == null ? 0 : null);
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
        emoteManager.notifyCatalogChanged();
      }
      if (channel != null) {
        final ok = await _reloadChannelOnly(channel);
        final failed = emoteManager.takeFetchFailures();
        signals.snack.emit(
          !ok
              ? _strings().emoteReloadFailed
              : failed.isEmpty
              ? _reloadedMessage(before, channels)
              : _strings().emotesFailedFor(failed.join(', ')),
        );
        return;
      }
      final ok = await refreshAfterAuth(
        force: true,
        onFetchSettled: step,
        onStep: step,
      );
      // The account's own emotes aren't covered by the global/channel
      // refresh; re-fetch them.
      var subFailed = false;
      if (ok && twitchAuth.isConfigured) {
        try {
          await emoteManager.reloadUserEmotes(twitchAuth, getChannelUserIds());
        } catch (e) {
          subFailed = true;
          logDebug('runRefresh: sub emote reload failed: $e');
        }
      }
      step();
      String message;
      if (!ok) {
        message = _strings().emoteReloadFailed;
      } else {
        final failed = emoteManager.takeFetchFailures();
        if (subFailed) failed.add(_strings().emoteSubEmotes);
        message = failed.isEmpty
            ? _reloadedMessage(before, channels)
            : _strings().emotesFailedFor(failed.join(', '));
      }
      signals.snack.emit(message);
    } finally {
      if (channel == null) setProgress(1);
      // Drop the busy state before clearing progress, so the full bar fades
      // out instead of flipping back to the indeterminate spinner.
      signals.busy.emit(false);
      if (channel == null) setProgress(null);
    }
  }

  /// Reloads one channel's provider lists without touching global or account
  /// emotes. Leaves progress null so the shell shows its normal spinner.
  Future<bool> _reloadChannelOnly(String channel) async {
    var broadcasterId = chat.channelFor(channel)?.info.broadcasterId;
    if (broadcasterId == null) {
      broadcasterId = await twitchApi.getUserId(twitchAuth, channel);
      if (broadcasterId != null) {
        chat.channelFor(channel)?.info.setBroadcasterId(broadcasterId);
      }
    }
    if (broadcasterId == null) return false;
    await emoteManager.resolveEmotes(channel, broadcasterId, force: true);
    emoteManager.notifyConfigChanged();
    return true;
  }

  String _reloadedMessage(Set<String>? before, Iterable<String> channels) {
    if (before == null) return _strings().emotesReloaded;
    final after = emoteManager.loadedEmoteKeys(channels);
    final added = after.difference(before).length;
    final removed = before.difference(after).length;
    return added == 0 && removed == 0
        ? _strings().emotesReloadedNoChange
        : _strings().emotesReloadedDelta(added, removed);
  }

  // Re-join may have opened channels whose sub-emote owners were previously
  // unknown; heal their labels in the emote daemon (no re-fetch needed).
  Future<void> refreshSubEmoteOwners() async {
    if (twitchAuth.isConfigured) {
      unawaited(emoteManager.loadUserEmotes(twitchAuth, getChannelUserIds()));
    }
  }
}
