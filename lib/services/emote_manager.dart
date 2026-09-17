import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../emotes/emote.dart';
import '../emotes/emote_catalog.dart';
import '../emotes/emote_picker.dart';
import '../models/emote_fetch_tier.dart';
import '../models/twitch_message.dart';
import '../util/log.dart';
import 'emote_cache_manager.dart';
import 'emote_fetcher.dart';
import 'emote_images.dart';
import 'emote_meta_store.dart';
import 'emote_persistence.dart';
import 'emote_providers/seven_tv_emotes.dart';
import 'emote_store.dart';
import 'emote_usage_registry.dart';
import 'emote_visibility.dart';
import 'seven_tv_event_client.dart';
import 'seven_tv_personal_sets.dart';
import 'twitch_auth.dart';
import 'twitch_emote_sets.dart';

export 'emote_usage_registry.dart' show EmoteUsageRecord;

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

  /// Frozen emote tokens for [msg], or null when it has no snapshot (system
  /// rows). Tokens are captured the first time and reused, so live deltas do
  /// not change them; a catalog version change recomputes them.
  List<EmoteToken>? resolvedEmotesFor(
    TwitchMessage msg, {
    required String lookupChannel,
  });
}

/// Coordinator and single doorway for the emote area.
///
/// Owns the fetch policy ([EmoteFetcher]), the catalog state ([EmoteStore]),
/// and small owners for usage/recents ([EmoteUsageRegistry]), personal 7TV
/// sets ([SevenTvPersonalSets]), Twitch account sets ([TwitchEmoteSets]),
/// catalog persistence ([EmotePersistence]), and image bytes ([EmoteImages]).
/// Lookups join the store with the personal/sub overlays here because the
/// manager holds both sides.
class EmoteManager implements EmoteLookupSource {
  final DateTime Function() _now;
  final EmoteMetaStore _metaStore;

  // Network fetching and fetch policy live in the fetcher; the manager feeds
  // the store and owns the flow orchestration.
  late final EmoteFetcher _fetcher;
  late final bool _ownsFetcher;

  // Catalog state, commits, and lookups live in the store; the manager feeds
  // it fetches and coordinates the per-account overlays.
  final EmoteStore _store;
  final bool _ownsStore;

  /// Per-message frozen emote resolutions, keyed by the message object. Weak,
  /// so evicting a message drops its snapshot; stale against [version].
  final Expando<_ResolvedMessageEmotes> _resolvedMessages =
      Expando<_ResolvedMessageEmotes>();

  /// Image byte black box (disk cache, precache, migrations).
  late final EmoteImages _images;
  late final bool _ownsImages;

  /// Usage history plus recents; also the image eviction policy.
  late final EmoteUsageRegistry _usage;
  late final bool _ownsUsage;

  /// Viewer and foreign 7TV personal sets.
  late final SevenTvPersonalSets _personalSets;

  /// Twitch account emote sets (subs plus unlocks).
  late final TwitchEmoteSets _twitchSets;

  /// Global/channel catalog persistence.
  late final EmotePersistence _persistence;

  /// Provider visibility config; the manager mirrors it into the store.
  late final EmoteVisibility _visibility;
  late final bool _ownsVisibility;

  // Effective fetch tier. Injected owners supply [readTier]/[writeTier] wired
  // to the tier provider; the local field is the compat path for direct tests.
  EmoteFetchTier _localTier;
  late final EmoteFetchTier Function() _readTier;
  final void Function(EmoteFetchTier)? _tierWriter;
  final void Function(int)? _cacheCapWriter;

  EmoteManager({
    EmoteStore? store,
    EmoteVisibility? visibility,
    EmoteFetcher? fetcher,
    EmoteImages? images,
    EmoteUsageRegistry? usage,
    SevenTvPersonalSets? personalSets,
    TwitchEmoteSets? twitchSets,
    EmotePersistence? persistence,
    Future<List<ConnectivityResult>> Function()? probe,
    Duration fetchStagger = defaultEmoteFetchStagger,
    Future<void> Function(String url)? removeCachedFile,
    DateTime Function()? now,
    EmoteFetchTier tier = EmoteFetchTier.high,
    EmoteFetchTier Function()? readTier,
    void Function(EmoteFetchTier)? writeTier,
    int cacheCap = defaultEmoteCacheMax,
    void Function(int)? writeCacheCap,
    Duration usageFlushDelay = const Duration(milliseconds: 250),
    Future<SevenTvChannelResponse> Function(String channelId)?
    sevenTvChannelFetcher,
    Future<List<Emote>> Function()? sevenTvGlobalFetcher,
    Future<List<String>> Function(String twitchId)? sevenTvOwnedSetIdsFetcher,
    Future<List<Emote>> Function(String setId)? sevenTvEmoteSetFetcher,
    EmoteCacheManager? cacheManager,
    EmoteMetaStore? metaStore,
    Future<Map<String, String>> Function(TwitchAuth auth, List<String> ids)?
    resolveOwnerLogins,
    Future<Map<String, List<Emote>>> Function(
      List<String> setIds, {
      String? accessToken,
    })?
    fetchUserEmoteSets,
    this.getChannelUserIds,
  }) : _store = store ?? EmoteStore(),
       _ownsStore = store == null,
       _metaStore = metaStore ?? EmoteMetaStore.I,
       _now = now ?? DateTime.now,
       _localTier = tier,
       _tierWriter = writeTier,
       _cacheCapWriter = writeCacheCap {
    _visibility = visibility ?? EmoteVisibility();
    _ownsVisibility = visibility == null;
    _readTier = readTier ?? () => _localTier;
    _applyVisibility();
    _visibility.addListener(_applyVisibility);

    // Owners are optional. When omitted (direct construction in tests) the
    // manager builds the full local graph for compatibility.
    _usage =
        usage ??
        EmoteUsageRegistry(
          capacity: () => _images.cacheCap,
          now: _now,
          flushDelay: usageFlushDelay,
        );
    _ownsUsage = usage == null;

    _images =
        images ??
        EmoteImages(
          policy: _usage,
          cacheManager: cacheManager,
          removeCachedFile: removeCachedFile,
          now: _now,
        );
    _ownsImages = images == null;

    _fetcher =
        fetcher ??
        EmoteFetcher(
          now: _now,
          tier: () => tier,
          isProviderEnabled: (type) => _visibility.isProviderEnabled(type),
          accessToken: () => _twitchSets.accessToken,
          probe: probe,
          fetchStagger: fetchStagger,
          sevenTvChannelFetcher: sevenTvChannelFetcher,
          sevenTvGlobalFetcher: sevenTvGlobalFetcher,
          sevenTvOwnedSetIds: sevenTvOwnedSetIdsFetcher,
          sevenTvEmoteSetFetcher: sevenTvEmoteSetFetcher,
          resolveOwnerLogins: resolveOwnerLogins,
          fetchUserEmoteSets: fetchUserEmoteSets,
        );
    _ownsFetcher = fetcher == null;

    _personalSets =
        personalSets ??
        SevenTvPersonalSets(
          fetcher: _fetcher,
          metaStore: _metaStore,
          tier: () => tier,
          isProviderEnabled: (type) => _visibility.isProviderEnabled(type),
          notifyChanged: _store.notifyResolutionChanged,
          now: _now,
        );
    _twitchSets =
        twitchSets ??
        TwitchEmoteSets(
          fetcher: _fetcher,
          store: _store,
          tier: () => tier,
          getChannelUserIds: getChannelUserIds,
        );
    _persistence =
        persistence ??
        EmotePersistence(
          tier: () => tier,
          isAccountUnlock: (id) =>
              _twitchSets.isAccountUnlocked(id) ||
              _twitchSets.isCatalogUnlocked(id),
          metaStore: _metaStore,
        );
    _images.cacheCap = cacheCap;
    // A landed precache download can make a lower scale redundant.
    _images.onStored = (emote) => unawaited(_discardDominatedScales([emote]));
  }

  /// Catalog store backing lookups and commits.
  EmoteStore get store => _store;

  /// Image byte owner consumed by the render path.
  @override
  EmoteImages get images => _images;

  /// Usage history plus recents; also the image eviction policy.
  EmoteUsageRegistry get usage => _usage;

  /// Viewer and foreign 7TV personal sets.
  SevenTvPersonalSets get personalSets => _personalSets;

  /// Twitch account emote sets (subs plus unlocks).
  TwitchEmoteSets get twitchSets => _twitchSets;

  /// Global/channel catalog persistence.
  EmotePersistence get persistence => _persistence;

  /// Fetching tier controlling resolution, cache TTL, and 7TV reconcile gating.
  /// Delegates to the injected provider when present.
  EmoteFetchTier get tier => _readTier();

  set tier(EmoteFetchTier value) {
    if (value == _readTier()) return;
    final writer = _tierWriter;
    if (writer != null) {
      writer(value);
    } else {
      _localTier = value;
    }
    _store.notifyStateCleared();
  }

  /// Max emote image files the disk cache keeps (default [defaultEmoteCacheMax],
  /// clamped to [minEmoteCacheMax]..[maxEmoteCacheMax]).
  int get cacheCap => _images.cacheCap;

  set cacheCap(int value) {
    final writer = _cacheCapWriter;
    if (writer != null) {
      writer(value);
      return;
    }
    _images.cacheCap = value;
  }

  /// Live open-channel -> broadcaster-id source, injected by the app layer and
  /// read at store time. Late-resolving ids must still receive fetched subs;
  /// null in unit tests, which pass explicit maps instead.
  final Map<String, String> Function()? getChannelUserIds;

  /// Whether a subscriber-emote fetch is currently in flight. The subs tab
  /// shows a spinner (not the empty text) while true.
  bool get subEmoteFetchInFlight => _twitchSets.subEmoteFetchInFlight;

  /// Current emote-data version. Forwards the store so message span caches
  /// detect stale spans lazily; live 7TV deltas do not advance it.
  @override
  int get version => _store.version;

  // Targets whose emote fetch failed since the last take (channel names, or
  // 'global emotes'), so a manual reload can surface partial failures instead
  // of reporting success.
  final Set<String> _fetchFailures = {};

  /// Targets (channel names, or 'global emotes') whose emote fetch failed
  /// since the last call; sorted, empty afterwards.
  List<String> takeFetchFailures() {
    final failed = _fetchFailures.toList()..sort();
    _fetchFailures.clear();
    return failed;
  }

  set accessToken(String? value) => _twitchSets.accessToken = value;

  // Merged emotes: channel overrides global, personal 7TV merges everywhere.
  // The store owns the cache; the manager supplies the account overlays.
  EmoteLookup? byCode(String channel) => _store.byCode(
    channel,
    personal: _personalSets.viewerEmotes,
    unlocks: _twitchSets.unlockedEmotes,
  );

  /// Twitch emotes that need sender proof: they render only from the IRC
  /// `emotes` tag, never from a bare word match. Covers sub, follower, and
  /// bits tiers. Globals and unlockables stay word-matchable.
  static bool isTwitchLocked(Emote e) => EmoteStore.isTwitchLocked(e);

  /// Fallback image URL for a Twitch emote id the API map does not contain.
  static String twitchFallbackUrl(String id) =>
      EmoteStore.twitchFallbackUrl(id);

  /// Shared tokenizer: Twitch positional emotes first, then word matches.
  /// Locked Twitch emotes never match by word; everything else does.
  static List<EmoteToken> tokenize({
    required String text,
    required List<EmotePosition>? positions,
    required Map<String, Emote> byCode,
  }) => EmoteStore.tokenize(text: text, positions: positions, byCode: byCode);

  /// What the viewer can type in [channel]: the merged, visibility-filtered
  /// suggestion list. Owned subs are already fanned into every channel, and
  /// follower emotes only exist in their home channel, so no extra merge.
  List<Emote> sendableEmotes(String channel) => _store.sendableEmotes(
    channel,
    personal: _personalSets.viewerEmotes,
    unlocks: _twitchSets.unlockedEmotes,
  );

  /// Recents resolved to [channel]-local codes; dead ids are dropped.
  Future<List<Emote>> recentsForChannel(String channel) async {
    final recents = await _usage.recentEmotes(emoteById);
    final suggestions = byCode(channel)?.suggestions;
    if (suggestions == null) return recents;
    return _usage.resolveRecentsForChannel(recents, suggestions);
  }

  /// Subscriber emotes grouped by owner, with [pinnedChannel] first.
  Map<String, List<Emote>> subsGrouped({String? pinnedChannel}) =>
      _store.subsGrouped(pinnedChannel: pinnedChannel);

  /// Channel picker tab: slice of the same base mixer chat renders from.
  /// Status-gated Twitch emotes (subs, followers, bitstier) live in the subs
  /// tab instead: they only render from the IRC tag.
  List<Emote> channelTabEmotes(String channel) => _store.channelTabEmotes(
    channel,
    personal: _personalSets.viewerEmotes,
    unlocks: _twitchSets.unlockedEmotes,
  );

  /// Emotes found in [text] for precache: tag emotes by id plus word
  /// matches under the sender-proof rule, deduped by id.
  List<Emote> matchEmotes({
    required String channel,
    required String text,
    required List<EmotePosition>? positions,
    String? senderTwitchId,
  }) => _store.matchEmotes(
    channel: channel,
    text: text,
    positions: positions,
    senderTwitchId: senderTwitchId,
    personal: _personalSets.viewerEmotes,
    unlocks: _twitchSets.unlockedEmotes,
    foreign: _personalSets.foreignFor(senderTwitchId),
  );

  /// Viewer Twitch user id for matching personal 7TV grants. Cleared logout.
  set viewerTwitchId(String? value) => _personalSets.viewerTwitchId = value;

  /// Bootstrap: fetch the viewer's owned 7TV sets and their emotes.
  Future<void> loadViewerPersonalSevenTvSets({bool force = false}) async {
    await _personalSets.loadViewerPersonalSevenTvSets(force: force);
  }

  /// Live personal 7TV grant/revoke from the entitlement stream.
  Future<void> applySevenTvEntitlement(SevenTvEntitlementEvent event) =>
      _personalSets.applyEntitlement(event);

  /// Map for one message: channel sets plus the sender's personal 7TV emotes
  /// underneath. Foreign codes never leak into other senders' messages.
  EmoteLookup? byCodeForSender(String channel, String? senderTwitchId) =>
      _store.byCodeForSender(
        channel,
        personal: _personalSets.viewerEmotes,
        unlocks: _twitchSets.unlockedEmotes,
        foreign: _personalSets.foreignFor(senderTwitchId),
      );

  /// [EmoteLookupSource] view: the sender-scoped lookup the render path uses.
  @override
  EmoteLookup? lookup(String channel, String? senderTwitchId) =>
      byCodeForSender(channel, senderTwitchId);

  /// Frozen emote tokens for [msg]. Computed once per catalog version and
  /// lookup channel, then reused, so a live 7TV delta never changes them; a
  /// version change (full refetch, personal set, visibility) recomputes. A
  /// changed lookup channel also recomputes, so a shared-chat message stamped
  /// before its source channel resolved heals once the source data lands.
  /// Only emote tokens are kept: text stays on the message. System rows
  /// return null so the renderer falls back.
  @override
  List<EmoteToken>? resolvedEmotesFor(
    TwitchMessage msg, {
    required String lookupChannel,
  }) {
    if (msg.isSystem) return null;
    final cached = _resolvedMessages[msg];
    if (cached != null &&
        cached.version == version &&
        cached.channel == lookupChannel) {
      return cached.tokens;
    }
    final byCode = byCodeForSender(lookupChannel, msg.userId)?.byCode;
    final tokens = byCode == null
        ? const <EmoteToken>[]
        : <EmoteToken>[
            for (final token in tokenize(
              text: msg.text,
              positions: msg.emotePositions,
              byCode: byCode,
            ))
              if (token.isEmote) token,
          ];
    _resolvedMessages[msg] = _ResolvedMessageEmotes(
      version,
      lookupChannel,
      tokens,
    );
    return tokens;
  }

  /// Maps foreign users to a personal set from a socket entitlement grant.
  Future<void> trackForeignPersonalGrant(
    Iterable<String> userTwitchIds,
    String setId,
  ) => _personalSets.trackForeignGrant(userTwitchIds, setId);

  /// Drops a foreign user's personal-set grant (entitlement.delete).
  void dropForeignPersonalGrant(Iterable<String> userTwitchIds, String setId) =>
      _personalSets.dropForeignGrant(userTwitchIds, setId);

  /// Placeholder for a personal set announced over the socket.
  void trackForeignPersonalSet(String setId) => _personalSets.trackSet(setId);

  /// Applies a socket emote_set.update to a tracked foreign personal set.
  void applyForeignPersonalSetUpdate({
    required String setId,
    required List<Emote> added,
    required List<String> removedIds,
    required Map<String, String> renamed,
  }) => _personalSets.applyForeignSetUpdate(
    setId: setId,
    added: added,
    removedIds: removedIds,
    renamed: renamed,
  );

  @visibleForTesting
  Future<void> flushPersonalSetsForTest() => _personalSets.flushForTest();

  /// Restores persisted personal sets (cold-start seed).
  Future<void> loadPersistedPersonalSets() => _personalSets.loadPersisted();

  // Global emotes by provider, in display order, sorted by code.
  Map<String, List<Emote>> globalEmotesByProvider() =>
      _store.globalEmotesByProvider(
        personal: _personalSets.viewerEmotes,
        unlocks: _twitchSets.unlockedEmotes,
      );

  /// Whether [channel]'s cache exists (stale is fine).
  bool hasChannelCache(String channel) => _store.hasChannelCache(channel);

  /// Whether the global emote cache has been resolved at least once.
  bool get hasGlobalCache => _store.hasGlobalCache;

  Map<String, List<Emote>> subscriberEmotesByChannel() =>
      _store.subscriberEmotesByChannel();

  // ── Provider visibility toggles ─────────────────────────────────────
  // Mirrors the visibility owner into the store snapshot; the owner owns the
  // prefs load/save.
  void _applyVisibility() {
    _store.setProviderVisibility(
      _visibility.disabledProviders,
      _visibility.allowUnlisted7tv,
    );
  }

  /// Whether [type] is fetched and rendered (sync view).
  bool isProviderEnabled(EmoteType type) => _visibility.isProviderEnabled(type);

  /// Current enabled providers, awaiting the persisted load first.
  Future<Set<EmoteType>> enabledProviders() => _visibility.enabledProviders();

  Future<void> setProviderEnabled(EmoteType type, bool enabled) async {
    final changed = await _visibility.setProviderEnabled(type, enabled);
    if (changed) _store.notifyVisibilityChanged();
  }

  /// Whether unlisted 7TV emotes render (sync view).
  bool get allowUnlisted7tv {
    if (!_visibility.isLoaded) unawaited(_visibility.ensureLoaded());
    return _visibility.allowUnlisted7tv;
  }

  Future<void> setAllowUnlisted7tv(bool allowed) async {
    final changed = await _visibility.setAllowUnlisted(allowed);
    if (changed) _store.notifyVisibilityChanged();
  }

  bool _hasGlobalList(EmoteType type) =>
      _store.globalCatalog.listFor(EmoteScope.global, type).isNotEmpty;

  bool _hasChannelList(String channel, EmoteType type) =>
      _store
          .channelCatalog(channel)
          ?.listFor(EmoteScope.channel, type)
          .isNotEmpty ??
      false;

  /// Refetches globals + channels for types with no retained catalog list.
  Future<void> ensureStashed(Set<EmoteType> types) async {
    await _visibility.ensureLoaded();
    if (_registryFrozen || tier == EmoteFetchTier.nothing || types.isEmpty) {
      return;
    }
    final targets = [
      for (final t in types)
        if (_isProviderOn(t)) t,
    ];
    if (targets.isEmpty) return;
    var fetched = false;
    await _fetcher.enqueue(() async {
      final globalEpoch = _store.globalEpoch;
      for (final type in targets.where((t) => !_hasGlobalList(t))) {
        try {
          final fetch = await _fetcher.fetchGlobalForProvider(type);
          if (fetch.byProvider.isNotEmpty) {
            _commitGlobal(globalEpoch, fetch);
            fetched = true;
          }
        } catch (e) {
          logDebug(
            '[EmoteManager] catalog refetch failed for ${type.name}: $e',
          );
        }
      }
      for (final channel in _store.channelNames) {
        final broadcasterId = _channelBroadcasterIds[channel];
        if (broadcasterId == null) continue;
        final missing = [
          for (final t in targets)
            if (!_hasChannelList(channel, t)) t,
        ];
        if (missing.isEmpty) continue;
        final channelEpoch = _store.channelEpoch(channel);
        final byProvider = <EmoteType, List<Emote>>{};
        String? sevenTvSetId;
        String? sevenTvUserId;
        for (final type in missing) {
          try {
            final fetch = await _fetcher.fetchChannelForProvider(
              type,
              broadcasterId,
              channelName: channel,
            );
            if (fetch.byProvider.isNotEmpty) {
              byProvider.addAll(fetch.byProvider);
              fetched = true;
            }
            sevenTvSetId ??= fetch.sevenTvSetId;
            sevenTvUserId ??= fetch.sevenTvUserId;
          } catch (e) {
            logDebug(
              '[EmoteManager] catalog refetch failed for '
              '${type.name}@$channel: $e',
            );
          }
        }
        _commitChannel(
          channel,
          channelEpoch,
          ChannelEmoteFetch(
            byProvider: byProvider,
            sevenTvSetId: sevenTvSetId,
            sevenTvUserId: sevenTvUserId,
          ),
        );
      }
    });
    if (fetched) _store.notifyVisibilityChanged();
  }

  // Last seen broadcaster id per channel, so targeted provider refetches can
  // run without the caller re-supplying it.
  final _channelBroadcasterIds = <String, String>{};

  /// Recently used emote ids (most recent first), used to boost autocomplete
  /// ranking.
  Set<String> get recentEmoteIds => _usage.recentEmoteIds;

  /// Resolve an emote by ID across all caches, then the personal and account
  /// unlock overlays.
  Emote? emoteById(String id) => _store.emoteById(
    id,
    personal: _personalSets.viewerEmotes,
    unlocks: _twitchSets.unlockedEmotes,
  );

  Future<void> markEmoteUsed(Emote emote) => _usage.markEmoteUsed(emote);

  /// Records emote display for cache eviction scoring.
  void markEmoteViewed(Emote emote) {
    if (tier == EmoteFetchTier.nothing) return;
    final url = EmotePicker.chatDownloadUrl(emote, tier);
    if (url != null) _usage.touch(url);
  }

  Future<List<Emote>> recentEmotes() => _usage.recentEmotes(emoteById);

  /// Resolves recents to channel-local codes via [suggestions].
  List<Emote> resolveRecentsForChannel(
    List<Emote> recents,
    List<Emote> suggestions,
  ) => _usage.resolveRecentsForChannel(recents, suggestions);

  /// Loads global emotes. [force] skips cache, fetches from network.
  Future<void> preloadGlobalEmotes({bool force = false}) async {
    final epoch = force ? _store.bumpGlobalEpoch() : _store.globalEpoch;
    await _visibility.ensureLoaded();
    if (_store.hasGlobalCache && !force) return;
    final ttl = await _fetcher.effectiveTtl();
    if (!force) {
      final loaded = await _persistence.load('emotes5_global', ttl);
      final cached = loaded.catalog;
      if (cached != null) {
        if (!_store.seedGlobalFromCache(epoch, cached)) return;
        if (loaded.fresh || _registryFrozen || tier == EmoteFetchTier.nothing) {
          // Fresh cache: render, then background-refresh Twitch globals.
          if (!_skipTwitchBackgroundRefresh) {
            unawaited(
              _fetcher
                  .enqueue(_fetcher.refreshTwitchGlobal)
                  .then((fetch) {
                    if (fetch != null) _commitGlobal(epoch, fetch);
                  })
                  .catchError((Object _) {}),
            );
          }
          return;
        }
      }
      // Stale: keep stale data, revalidate below.
    }
    // Fetch every enabled provider.
    if (tier == EmoteFetchTier.nothing) return;
    final loaded = await _persistence.load('emotes5_global', ttl);
    if (loaded.catalog != null) {
      // Seed provider lists a wiped catalog would otherwise lose to a flaky
      // fetch (429/5xx/timeout), without clobbering in-memory data.
      if (!_store.fillMissingGlobal(epoch, loaded.catalog!)) return;
    }
    final fetch = await _fetcher.enqueue(_fetcher.fetchAllGlobal);
    if (_commitGlobal(epoch, fetch)) {
      await _persistence.save('emotes5_global', _store.globalCatalog, ttl);
    }
    _store.notifyStateCleared();
  }

  Future<void> storeUserTwitchEmotes(Map<String, List<Emote>> perChannel) =>
      _twitchSets.storeUserTwitchEmotes(perChannel);

  /// Loads subscriber emotes: fetch, resolve owners, fan into channels.
  Future<void> loadUserEmoteSets(
    List<String> emoteSetIds,
    TwitchAuth auth,
    Map<String, String> openChannelUserIds,
  ) => _twitchSets.loadUserEmoteSets(emoteSetIds, auth, openChannelUserIds);

  /// Clears per-account emote state (account switch).
  void resetUserEmoteState() {
    _personalSets.reset();
    _twitchSets.resetUserEmoteState();
  }

  /// Re-fetches subscriber emotes for the ids already known from a prior
  /// USERSTATE/GLOBALUSERSTATE.
  Future<void> reloadUserEmoteSets(
    TwitchAuth auth,
    Map<String, String> openChannelUserIds,
  ) => _twitchSets.reloadUserEmoteSets(auth, openChannelUserIds);

  /// Loads channel emotes. [force] skips cache, fetches from network.
  Future<void> resolveEmotes(
    String channel,
    String? broadcasterId, {
    bool force = false,
  }) async {
    final epoch = force
        ? _store.bumpChannelEpoch(channel)
        : _store.channelEpoch(channel);
    await _visibility.ensureLoaded();
    if (broadcasterId != null) _channelBroadcasterIds[channel] = broadcasterId;
    final ttl = await _fetcher.effectiveTtl();
    if (force) {
      // Nothing tier: render cached only.
      if (tier == EmoteFetchTier.nothing) return;
      final loaded = await _persistence.load('emotes5_$channel', ttl);
      if (_store.channelEpoch(channel) != epoch) return;
      if (loaded.catalog != null) {
        _store.fillMissingChannel(channel, loaded.catalog!);
      }
      final fetch = await _fetcher.enqueue(
        () => _fetcher.fetchAllChannel(broadcasterId, channelName: channel),
      );
      if (_commitChannel(channel, epoch, fetch)) {
        await _persistence.save(
          'emotes5_$channel',
          _store.channelCatalog(channel)!,
          ttl,
        );
      }
      return;
    }
    final loaded = await _persistence.load(
      'emotes5_$channel',
      ttl,
      fetchTime: _store.channelFetchTime(channel),
    );
    final cached = loaded.catalog;
    if (cached != null) {
      if (_store.channelEpoch(channel) != epoch) return;
      // Stored subs are owned by storeUserTwitchEmotes (USERSTATE) and must
      // not leak across account switches through the disk cache.
      final existingSubs =
          _store.channelCatalog(channel)?.twitchSubs ?? const <Emote>[];
      _store.seedChannelFromCache(channel, cached, existingSubs);
      if (loaded.fresh || _registryFrozen || tier == EmoteFetchTier.nothing) {
        // Fresh: render, background-refresh Twitch channel emotes.
        if (!_skipTwitchBackgroundRefresh) {
          unawaited(
            _fetcher
                .enqueue(
                  () => _fetcher.refreshTwitchChannel(channel, broadcasterId),
                )
                .then((fetch) {
                  if (fetch != null) _commitChannel(channel, epoch, fetch);
                })
                .catchError((Object _) {}),
          );
        }
        // Reconcile 7TV deltas at startup: the fetched set is authoritative,
        // so stale live deltas are dropped rather than re-applied over it.
        if (broadcasterId != null &&
            tier.index >= EmoteFetchTier.medium.index) {
          unawaited(
            _fetcher
                .enqueue(
                  () => _fetcher.reconcileSevenTv(channel, broadcasterId),
                )
                .then((fetch) {
                  if (fetch == null) return;
                  if (fetch.byProvider[EmoteType.sevenTv] != null) {
                    _store.dropLiveSevenTv(channel);
                  }
                  _commitChannel(channel, epoch, fetch);
                })
                .catchError((Object _) {}),
          );
        }
        return;
      }
      // Stale: keep stale data, revalidate below.
    }
    // Nothing tier: render cached only.
    if (tier == EmoteFetchTier.nothing) return;
    final fetch = await _fetcher.enqueue(
      () => _fetcher.fetchAllChannel(broadcasterId, channelName: channel),
    );
    if (_commitChannel(channel, epoch, fetch)) {
      await _persistence.save(
        'emotes5_$channel',
        _store.channelCatalog(channel)!,
        ttl,
      );
    }
  }

  /// Applies one global fetch at [epoch]. A stale epoch is dropped so an
  /// in-flight fetch that lands after an evict or forced reload cannot
  /// overwrite newer state. Failed providers feed [takeFetchFailures].
  bool _commitGlobal(int epoch, GlobalEmoteFetch fetch) {
    if (epoch != _store.globalEpoch) return false;
    for (final _ in fetch.failed) {
      _fetchFailures.add('global emotes');
    }
    // Apply the account catalogue unlock ids here, not in the fetcher, so the
    // fetch stays pure.
    _twitchSets.applyCatalogUnlockIds(fetch.twitchCatalogUnlockIds);
    return _store.commitGlobal(epoch, fetch);
  }

  /// Applies one channel fetch at [epoch]. A stale epoch is dropped so an
  /// in-flight fetch that lands after an evict or forced resolve cannot
  /// resurrect the channel. Missing providers keep their retained list; the
  /// stored subs and 7TV identity are preserved.
  bool _commitChannel(String channel, int epoch, ChannelEmoteFetch fetch) {
    if (epoch != _store.channelEpoch(channel)) return false;
    for (final _ in fetch.failed) {
      _fetchFailures.add(channel);
    }
    return _store.commitChannel(channel, epoch, fetch);
  }

  /// Reconciles the channel's 7TV set against the server. Used when a live
  /// `user.update` switches the active set.
  Future<void> reconcileSevenTvChannel(String channel) async {
    await _visibility.ensureLoaded();
    final broadcasterId = _channelBroadcasterIds[channel];
    if (broadcasterId == null) return;
    final epoch = _store.channelEpoch(channel);
    final fetch = await _fetcher.enqueue(
      () => _fetcher.reconcileSevenTv(channel, broadcasterId),
    );
    if (fetch == null) return;
    // A fetched 7TV set is authoritative: drop stale live deltas. An empty
    // fetch keeps them, matching the old reconcile early return.
    if (fetch.byProvider[EmoteType.sevenTv] != null) {
      _store.dropLiveSevenTv(channel);
    }
    _commitChannel(channel, epoch, fetch);
  }

  void evictChannel(String channel) {
    _channelBroadcasterIds.remove(channel);
    _store.evictChannel(channel);
  }

  void evictGlobal() {
    _twitchSets.clearUnlocks();
    _store.evictGlobal();
  }

  void markEmotesResolved(String channel) => _store.markEmotesResolved(channel);

  bool emotesResolved(String channel) => _store.emotesResolved(channel);

  /// Bumps the version and notifies listeners with the current (possibly
  /// empty) state, so cached message spans are discarded immediately.
  void notifyStateCleared() => _store.notifyStateCleared();

  /// Notifies observers of a config-only change (tier, auto mode) without
  /// bumping the catalog version, so the UI refreshes and cached message
  /// spans stay valid.
  void notifyConfigChanged() => _store.notifyConfigChanged();

  void setSevenTvEmoteSetId(String channel, String emoteSetId) =>
      _store.setSevenTvEmoteSetId(channel, emoteSetId);

  String? getSevenTvEmoteSetId(String channel) =>
      _store.getSevenTvEmoteSetId(channel);

  String? getSevenTvUserId(String channel) => _store.getSevenTvUserId(channel);

  String? getChannelForSevenTvEmoteSet(String emoteSetId) =>
      _store.getChannelForSevenTvEmoteSet(emoteSetId);

  // Applies 7TV WS deltas in place; evicts unused from disk cache.
  void updateSevenTvEmotes(
    String channel, {
    List<Emote> added = const [],
    List<String> removedIds = const [],
    Map<String, ({String newName, String oldName})> renamed = const {},
  }) {
    if (tier == EmoteFetchTier.nothing) return;
    if (!_isProviderOn(EmoteType.sevenTv)) return;
    final unusedUrls = _store.updateSevenTvEmotes(
      channel,
      added: added,
      removedIds: removedIds,
      renamed: renamed,
    );
    if (unusedUrls.isNotEmpty) {
      unawaited(_evictEmoteImages(unusedUrls));
    }
  }

  Future<void> _evictEmoteImages(List<String> urls) async {
    await _usage.forgetUrls(urls);
    for (final url in urls) {
      if (url.isEmpty) continue;
      try {
        await _images.removeFile(url);
      } catch (_) {
        logDebug('[EmoteManager] failed to evict unused emote $url');
      }
    }
  }

  Future<void> _discardDominatedScales(List<Emote> emotes) async {
    for (final e in emotes) {
      final dominated = EmotePicker.dominatedScaleUrls(e);
      if (dominated.isEmpty) continue;
      final better = e.urlFor(EmoteScale.medium) ?? e.urlFor(EmoteScale.large);
      if (better != null && await _images.isCached(better)) {
        await _evictEmoteImages(dominated);
      }
    }
  }

  /// Low/nothing tiers: no Twitch background refresh (infinite TTL).
  bool get _skipTwitchBackgroundRefresh =>
      tier == EmoteFetchTier.low || tier == EmoteFetchTier.nothing;

  /// Low tier: frozen registries (seed fetch only, force bypasses).
  bool get _registryFrozen => tier == EmoteFetchTier.low;

  @visibleForTesting
  Future<Duration> effectiveTtlForTesting() => _fetcher.effectiveTtl();

  @visibleForTesting
  int get precacheQueueLengthForTesting => _images.precacheQueueLength;

  @visibleForTesting
  Future<void> enqueueFetchForTesting(Future<void> Function() action) =>
      _fetcher.enqueue(action);

  @visibleForTesting
  Future<void> flushUsageForTesting() => _usage.flushForTesting();

  @visibleForTesting
  int stashSizeForTesting({String? channel, required EmoteType type}) {
    if (channel == null) {
      return _store.globalCatalog.listFor(EmoteScope.global, type).length;
    }
    return _store
            .channelCatalog(channel)
            ?.listFor(EmoteScope.channel, type)
            .length ??
        0;
  }

  @visibleForTesting
  int foreignPersonalSetCountForTesting() => _personalSets.foreignSetCount;

  @visibleForTesting
  Future<GlobalEmoteFetch> fetchAllGlobalForTesting() async {
    await _visibility.ensureLoaded();
    return _fetcher.fetchAllGlobal();
  }

  @visibleForTesting
  Future<ChannelEmoteFetch> fetchAllChannelForTesting(
    String? broadcasterId, {
    String? channelName,
  }) async {
    await _visibility.ensureLoaded();
    return _fetcher.fetchAllChannel(broadcasterId, channelName: channelName);
  }

  /// Sync gate for fetch lambdas; callers must have awaited
  /// [_visibility.ensureLoaded] first.
  bool _isProviderOn(EmoteType type) => _visibility.isProviderEnabled(type);

  /// Prunes persisted registries for left channels.
  Future<void> pruneStaleChannels(Set<String> activeChannels) =>
      _persistence.pruneStaleChannels(activeChannels);

  /// Deletes all persisted emote metadata (global + per channel).
  Future<void> wipePersisted() => _persistence.wipePersisted();

  /// Empties the emote image disk cache (nuke).
  Future<void> clearImageCache() => _images.clear();

  void dispose() {
    _visibility.removeListener(_applyVisibility);
    if (_ownsFetcher) _fetcher.dispose();
    if (_ownsUsage) _usage.dispose();
    if (_ownsImages) _images.dispose();
    if (_ownsStore) _store.dispose();
    if (_ownsVisibility) _visibility.dispose();
  }

  // ── Cache init + migrations ─────────────────────────────────────────

  /// Loads usage history, runs cache migrations, and enforces the cap.
  Future<void> startCacheGc() async {
    await _usage.ensureLoaded();
    await _images.startCacheGc();
  }

  /// Queues seen [emotes] for usage tracking and background precache.
  void enqueueSeenEmotes(List<Emote> emotes) {
    // Nothing tier: skip fetch and usage tracking.
    if (tier == EmoteFetchTier.nothing) return;
    final fresh = _images.precache(emotes);
    if (fresh.isEmpty) return;
    _usage.touchAll(
      fresh
          .map((e) => EmotePicker.chatDownloadUrl(e, tier))
          .whereType<String>(),
    );
    _usage.scheduleFlush();
    unawaited(_discardDominatedScales(fresh));
  }
}

/// One message's frozen emote resolution, tagged with the catalog version
/// and lookup channel it was built from.
class _ResolvedMessageEmotes {
  const _ResolvedMessageEmotes(this.version, this.channel, this.tokens);

  final int version;
  final String channel;
  final List<EmoteToken> tokens;
}
