import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../emotes/emote.dart';
import '../emotes/emote_catalog.dart';
import '../models/emote_fetch_tier.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../util/log.dart';
import '../util/semaphore.dart';
import 'emote_providers/twitch_emotes.dart';
import 'emote_providers/bttv_emotes.dart';
import 'emote_providers/ffz_emotes.dart';
import 'emote_providers/seven_tv_emotes.dart';

/// Stagger before a fetch waits for a concurrency permit, so a burst of
/// refreshes never hits the network at once.
const defaultEmoteFetchStagger = Duration(milliseconds: 1500);

/// Provider emote lists produced by one global fetch, plus the providers that
/// failed and the account Twitch catalogue unlock ids. A provider with an
/// empty list is omitted so a commit keeps the retained list.
class GlobalEmoteFetch {
  const GlobalEmoteFetch({
    this.byProvider = const {},
    this.failed = const {},
    this.twitchCatalogUnlockIds = const {},
  });

  final Map<EmoteType, List<Emote>> byProvider;
  final Set<EmoteType> failed;

  /// Ids from the global unlockable Twitch catalogue (broadcaster_id=0). The
  /// global commit applies them to store state; the fetch stays pure.
  final Set<String> twitchCatalogUnlockIds;
}

/// Provider emote lists produced by one channel fetch, plus the 7TV identity
/// and the providers that failed. A provider with an empty list is omitted so
/// a commit keeps the retained list.
class ChannelEmoteFetch {
  const ChannelEmoteFetch({
    this.byProvider = const {},
    this.failed = const {},
    this.sevenTvSetId,
    this.sevenTvUserId,
  });

  final Map<EmoteType, List<Emote>> byProvider;
  final Set<EmoteType> failed;
  final String? sevenTvSetId;
  final String? sevenTvUserId;
}

/// Owns every emote network fetch and the fetch policy for [EmoteManager].
///
/// It is a pure producer: fetch methods only return typed results and never
/// mutate catalog or commit state. Mutable config the fetcher reads at call
/// time arrives through callbacks so the manager keeps single ownership of it.
class EmoteFetcher {
  // Refresh TTLs: emote caches are only refetched once they're older than
  // the TTL. Unmetered connections refresh every 12h; cellular gets 24h so
  // the rake uses less data.
  static const _wifiTtl = Duration(hours: 12);
  static const _mobileTtl = Duration(hours: 24);
  static const _connectivityProbeTtl = Duration(seconds: 60);
  static const _infiniteTtl = Duration(days: 365000);

  // Bounds in-flight provider fetches so a full refresh doesn't burst the
  // network, while letting more than one channel refresh at a time.
  static const _maxConcurrentFetches = 2;
  final _fetchGate = Semaphore(_maxConcurrentFetches);

  // Set on teardown so work queued behind the stagger or the gate is dropped
  // instead of retaining its closure until it runs.
  bool _disposed = false;

  late final DateTime Function() _now;
  late final EmoteFetchTier Function() _tier;
  late final bool Function(EmoteType) _isProviderEnabled;
  late final String? Function() _accessToken;

  final Future<List<ConnectivityResult>> Function()? _connectivityProbe;
  late final Duration _fetchStagger;
  ConnectivityResult _probeResult = ConnectivityResult.wifi;
  DateTime? _probeAt;

  final Future<SevenTvChannelResponse> Function(
    String channelId,
    EmoteResolution resolution,
  )
  _sevenTvChannelFetcher;
  final Future<List<Emote>> Function(EmoteResolution resolution)
  _sevenTvGlobalFetcher;
  final Future<List<String>> Function(String twitchId) _sevenTvOwnedSetIds;
  final Future<List<Emote>> Function(String setId, EmoteResolution resolution)
  _sevenTvEmoteSetFetcher;
  final Future<Map<String, String>> Function(TwitchAuth auth, List<String> ids)
  _resolveOwnerLogins;
  final Future<Map<String, List<Emote>>> Function(
    List<String> setIds, {
    String? accessToken,
    EmoteResolution? resolution,
  })
  _fetchUserEmoteSets;

  EmoteFetcher({
    required DateTime Function() now,
    required EmoteFetchTier Function() tier,
    required bool Function(EmoteType) isProviderEnabled,
    required String? Function() accessToken,
    Future<List<ConnectivityResult>> Function()? probe,
    Duration fetchStagger = defaultEmoteFetchStagger,
    Future<SevenTvChannelResponse> Function(
      String channelId,
      EmoteResolution resolution,
    )?
    sevenTvChannelFetcher,
    Future<List<Emote>> Function(EmoteResolution resolution)?
    sevenTvGlobalFetcher,
    Future<List<String>> Function(String twitchId)? sevenTvOwnedSetIds,
    Future<List<Emote>> Function(String setId, EmoteResolution resolution)?
    sevenTvEmoteSetFetcher,
    Future<Map<String, String>> Function(TwitchAuth auth, List<String> ids)?
    resolveOwnerLogins,
    Future<Map<String, List<Emote>>> Function(
      List<String> setIds, {
      String? accessToken,
      EmoteResolution? resolution,
    })?
    fetchUserEmoteSets,
  }) : _connectivityProbe = probe,
       _sevenTvChannelFetcher =
           sevenTvChannelFetcher ??
           ((String channelId, EmoteResolution resolution) =>
               SevenTvEmoteProvider.fetchChannelResponse(
                 channelId,
                 resolution: resolution,
               )),
       _sevenTvGlobalFetcher =
           sevenTvGlobalFetcher ??
           ((EmoteResolution resolution) =>
               SevenTvEmoteProvider.fetchGlobal(resolution: resolution)),
       _sevenTvOwnedSetIds =
           sevenTvOwnedSetIds ?? SevenTvEmoteProvider.fetchOwnedSetIds,
       _sevenTvEmoteSetFetcher =
           sevenTvEmoteSetFetcher ??
           ((String setId, EmoteResolution resolution) =>
               SevenTvEmoteProvider.fetchEmoteSet(
                 setId,
                 resolution: resolution,
               )),
       _resolveOwnerLogins =
           resolveOwnerLogins ?? TwitchApi().getUserLoginsByIds,
       _fetchUserEmoteSets =
           fetchUserEmoteSets ??
           ((
             List<String> ids, {
             String? accessToken,
             EmoteResolution? resolution,
           }) => TwitchEmoteProvider.fetchEmoteSets(
             ids,
             accessToken: accessToken,
             resolution: resolution ?? EmoteResolution.high,
           )) {
    _now = now;
    _tier = tier;
    _isProviderEnabled = isProviderEnabled;
    _accessToken = accessToken;
    _fetchStagger = fetchStagger;
  }

  /// Runs [action] behind the shared fetch gate after the configured stagger.
  /// The stagger wait runs before acquiring a permit so sleeping fetches never
  /// hold gate slots. Callers control the enqueue boundary when they batch
  /// several producer calls under one permit. Work still queued at teardown
  /// is dropped without running.
  Future<T> enqueue<T>(Future<T> Function() action) {
    if (_disposed) {
      return Future<T>.error(StateError('EmoteFetcher disposed'));
    }
    Future<void> stagger() => Future<void>.delayed(_fetchStagger);

    return stagger().then((_) {
      if (_disposed) {
        throw StateError('EmoteFetcher disposed');
      }
      return _fetchGate.withPermit(() {
        if (_disposed) {
          throw StateError('EmoteFetcher disposed');
        }
        return action();
      });
    });
  }

  /// Drops queued work and marks the fetcher unusable.
  void dispose() {
    _disposed = true;
  }

  /// Fetches every enabled global provider list plus the catalogue unlock ids.
  Future<GlobalEmoteFetch> fetchAllGlobal() async {
    final results = <EmoteType, List<Emote>>{};
    var unlockIds = const <String>{};
    final providers = <EmoteType, Future<List<Emote>> Function()>{
      EmoteType.twitch: () async {
        if (!_isProviderEnabled(EmoteType.twitch)) return [];
        final twitch = await _fetchTwitchGlobal(_tier().resolution!);
        unlockIds = twitch.unlockIds;
        // Empty fetch: keep the retained catalog list.
        if (twitch.emotes.isNotEmpty) {
          results[EmoteType.twitch] = twitch.emotes;
        }
        return twitch.emotes;
      },
      EmoteType.bttv: () async {
        if (!_isProviderEnabled(EmoteType.bttv)) return [];
        final emotes = await BttvEmoteProvider.fetchGlobal(
          resolution: _tier().resolution!,
        );
        if (emotes.isNotEmpty) results[EmoteType.bttv] = emotes;
        return emotes;
      },
      EmoteType.ffz: () async {
        if (!_isProviderEnabled(EmoteType.ffz)) return [];
        final emotes = await FfzEmoteProvider.fetchGlobal(
          resolution: _tier().resolution!,
        );
        if (emotes.isNotEmpty) results[EmoteType.ffz] = emotes;
        return emotes;
      },
      EmoteType.sevenTv: () async {
        if (!_isProviderEnabled(EmoteType.sevenTv)) return [];
        final emotes = await _sevenTvGlobalFetcher(_tier().resolution!);
        if (emotes.isNotEmpty) results[EmoteType.sevenTv] = emotes;
        return emotes;
      },
    };
    final failed = await _fetchConcurrent(providers, maxConcurrent: 2);
    return GlobalEmoteFetch(
      byProvider: results,
      failed: failed,
      twitchCatalogUnlockIds: unlockIds,
    );
  }

  /// Fetches every enabled channel provider list plus the 7TV identity.
  Future<ChannelEmoteFetch> fetchAllChannel(
    String? broadcasterId, {
    String? channelName,
  }) async {
    if (broadcasterId == null) {
      // No broadcaster id: nothing to fetch; the commit keeps retained lists.
      return const ChannelEmoteFetch();
    }
    final results = <EmoteType, List<Emote>>{};
    String? sevenTvSetId;
    String? sevenTvUserId;
    final providers = <EmoteType, Future<List<Emote>> Function()>{
      EmoteType.twitch: () async {
        if (!_isProviderEnabled(EmoteType.twitch)) return [];
        final fetched = await TwitchEmoteProvider.fetchChannel(
          broadcasterId,
          accessToken: _accessToken(),
          channelName: channelName,
          resolution: _tier().resolution!,
        );
        final nonSub = fetched.where((e) => !isTwitchSub(e)).toList();
        // Empty fetch: keep the retained catalog entry so a silent non-200
        // cannot clobber it.
        if (nonSub.isNotEmpty) results[EmoteType.twitch] = nonSub;
        return nonSub;
      },
      EmoteType.bttv: () async {
        if (!_isProviderEnabled(EmoteType.bttv)) return [];
        final emotes = await BttvEmoteProvider.fetchChannel(
          broadcasterId,
          resolution: _tier().resolution!,
        );
        if (emotes.isNotEmpty) results[EmoteType.bttv] = emotes;
        return emotes;
      },
      EmoteType.ffz: () async {
        if (!_isProviderEnabled(EmoteType.ffz)) return [];
        final emotes = await FfzEmoteProvider.fetchChannel(
          broadcasterId,
          resolution: _tier().resolution!,
        );
        if (emotes.isNotEmpty) results[EmoteType.ffz] = emotes;
        return emotes;
      },
      EmoteType.sevenTv: () async {
        if (!_isProviderEnabled(EmoteType.sevenTv)) return [];
        final resp = await _sevenTvChannelFetcher(
          broadcasterId,
          _tier().resolution!,
        );
        sevenTvSetId = resp.emoteSetId;
        sevenTvUserId = resp.userId;
        if (resp.emotes.isNotEmpty) results[EmoteType.sevenTv] = resp.emotes;
        return resp.emotes;
      },
    };
    final failed = await _fetchConcurrent(providers, maxConcurrent: 3);
    return ChannelEmoteFetch(
      byProvider: results,
      failed: failed,
      sevenTvSetId: sevenTvSetId,
      sevenTvUserId: sevenTvUserId,
    );
  }

  /// Produces a Twitch-only global refresh. Null on skip or failure.
  Future<GlobalEmoteFetch?> refreshTwitchGlobal() async {
    if (!_isProviderEnabled(EmoteType.twitch)) return null;
    try {
      final twitch = await _fetchTwitchGlobal(_tier().resolution!);
      if (twitch.emotes.isEmpty) return null;
      return GlobalEmoteFetch(
        byProvider: {EmoteType.twitch: twitch.emotes},
        twitchCatalogUnlockIds: twitch.unlockIds,
      );
    } catch (e) {
      logDebug('[EmoteFetcher] twitch global refresh failed: $e');
      return null;
    }
  }

  /// Produces a Twitch-only channel refresh. Null on skip or failure, so a
  /// background refresh never counts as a reload failure.
  Future<ChannelEmoteFetch?> refreshTwitchChannel(
    String channel,
    String? broadcasterId,
  ) async {
    if (broadcasterId == null) return null;
    if (!_isProviderEnabled(EmoteType.twitch)) return null;
    try {
      final emotes = await TwitchEmoteProvider.fetchChannel(
        broadcasterId,
        accessToken: _accessToken(),
        channelName: channel,
        resolution: _tier().resolution!,
      );
      if (emotes.isEmpty) return null;
      final nonSub = emotes.where((e) => !isTwitchSub(e)).toList();
      if (nonSub.isEmpty) return null;
      return ChannelEmoteFetch(byProvider: {EmoteType.twitch: nonSub});
    } catch (e) {
      logDebug('[EmoteFetcher] twitch refresh failed for $channel: $e');
      return null;
    }
  }

  /// Produces the channel's current 7TV set for reconcile (medium/high).
  Future<ChannelEmoteFetch?> reconcileSevenTv(
    String channel,
    String broadcasterId,
  ) async {
    if (_tier().index < EmoteFetchTier.medium.index) return null;
    if (!_isProviderEnabled(EmoteType.sevenTv)) return null;
    try {
      final resp = await _sevenTvChannelFetcher(
        broadcasterId,
        _tier().resolution!,
      );
      return ChannelEmoteFetch(
        byProvider: _providerMap(EmoteType.sevenTv, resp.emotes),
        sevenTvSetId: resp.emoteSetId,
        sevenTvUserId: resp.userId,
      );
    } catch (e) {
      logDebug('[EmoteFetcher] 7TV reconcile failed for $channel: $e');
      return null;
    }
  }

  /// Fetches one provider's global emote list. Returns an empty fetch on an
  /// empty provider result so the commit retains the previous list.
  Future<GlobalEmoteFetch> fetchGlobalForProvider(
    EmoteType type,
    EmoteResolution resolution,
  ) async {
    switch (type) {
      case EmoteType.twitch:
        final twitch = await _fetchTwitchGlobal(resolution);
        return GlobalEmoteFetch(
          byProvider: _providerMap(EmoteType.twitch, twitch.emotes),
          twitchCatalogUnlockIds: twitch.unlockIds,
        );
      case EmoteType.bttv:
        final emotes = await BttvEmoteProvider.fetchGlobal(
          resolution: resolution,
        );
        return GlobalEmoteFetch(
          byProvider: _providerMap(EmoteType.bttv, emotes),
        );
      case EmoteType.ffz:
        final emotes = await FfzEmoteProvider.fetchGlobal(
          resolution: resolution,
        );
        return GlobalEmoteFetch(
          byProvider: _providerMap(EmoteType.ffz, emotes),
        );
      case EmoteType.sevenTv:
        final emotes = await _sevenTvGlobalFetcher(resolution);
        return GlobalEmoteFetch(
          byProvider: _providerMap(EmoteType.sevenTv, emotes),
        );
    }
  }

  /// Fetches one provider's channel emote list plus the 7TV identity.
  Future<ChannelEmoteFetch> fetchChannelForProvider(
    EmoteType type,
    String broadcasterId, {
    String? channelName,
    required EmoteResolution resolution,
  }) async {
    switch (type) {
      case EmoteType.twitch:
        final fetched = await TwitchEmoteProvider.fetchChannel(
          broadcasterId,
          accessToken: _accessToken(),
          channelName: channelName,
          resolution: resolution,
        );
        // Subs live in the channel's twitchSubs list, not the provider lists.
        final nonSub = fetched.where((e) => !isTwitchSub(e)).toList();
        return ChannelEmoteFetch(
          byProvider: _providerMap(EmoteType.twitch, nonSub),
        );
      case EmoteType.bttv:
        final emotes = await BttvEmoteProvider.fetchChannel(
          broadcasterId,
          resolution: resolution,
        );
        return ChannelEmoteFetch(
          byProvider: _providerMap(EmoteType.bttv, emotes),
        );
      case EmoteType.ffz:
        final emotes = await FfzEmoteProvider.fetchChannel(
          broadcasterId,
          resolution: resolution,
        );
        return ChannelEmoteFetch(
          byProvider: _providerMap(EmoteType.ffz, emotes),
        );
      case EmoteType.sevenTv:
        final resp = await _sevenTvChannelFetcher(broadcasterId, resolution);
        return ChannelEmoteFetch(
          byProvider: _providerMap(EmoteType.sevenTv, resp.emotes),
          sevenTvSetId: resp.emoteSetId,
          sevenTvUserId: resp.userId,
        );
    }
  }

  /// Single-provider fetch map; an empty list yields an empty map so the commit
  /// retains the previous list.
  static Map<EmoteType, List<Emote>> _providerMap(
    EmoteType type,
    List<Emote> emotes,
  ) => emotes.isEmpty ? const {} : {type: emotes};

  /// TTL varies by tier and connectivity (longer on cellular).
  Future<Duration> effectiveTtl() async {
    switch (_tier()) {
      case EmoteFetchTier.low:
      case EmoteFetchTier.nothing:
        return _infiniteTtl;
      case EmoteFetchTier.medium:
        return const Duration(hours: 24);
      case EmoteFetchTier.high:
        final isMobile =
            await _probeConnectivity() == ConnectivityResult.mobile;
        return isMobile ? _mobileTtl : _wifiTtl;
    }
  }

  /// Fetches a 7TV emote set behind the shared gate. The manager's foreign
  /// personal-set fill uses this narrow entry rather than the raw gate.
  Future<List<Emote>> fetchSevenTvEmoteSet(
    String setId,
    EmoteResolution resolution,
  ) => _fetchGate.withPermit(() => _sevenTvEmoteSetFetcher(setId, resolution));

  /// Lists the 7TV sets owned by [twitchId] (viewer personal bootstrap).
  Future<List<String>> fetchSevenTvOwnedSetIds(String twitchId) =>
      _sevenTvOwnedSetIds(twitchId);

  /// Fetches Twitch emote sets by id (subscriber bootstrap).
  Future<Map<String, List<Emote>>> fetchUserEmoteSets(
    List<String> setIds, {
    String? accessToken,
    EmoteResolution? resolution,
  }) => _fetchUserEmoteSets(
    setIds,
    accessToken: accessToken,
    resolution: resolution,
  );

  /// Resolves sub-emote owner ids to Twitch logins.
  Future<Map<String, String>> resolveOwnerLogins(
    TwitchAuth auth,
    List<String> ids,
  ) => _resolveOwnerLogins(auth, ids);

  /// Defaults plus the global unlockable catalogue (broadcaster_id=0).
  /// The /global endpoint returns defaults only, so the picker and
  /// autocomplete miss Prime/Turbo/2FA/Hype Train emotes without this.
  /// Both fetches run in parallel with isolated errors: a defaults failure
  /// no longer aborts the unlockable fetch. A defaults throw still surfaces
  /// when nothing usable arrived, so fetch-failure reporting keeps working.
  Future<({List<Emote> emotes, Set<String> unlockIds})> _fetchTwitchGlobal(
    EmoteResolution resolution,
  ) async {
    List<Emote> defaults = const [];
    Object? defaultsError;
    List<Emote> unlockable = const [];
    Future<List<Emote>> getDefaults() async {
      try {
        return await TwitchEmoteProvider.fetchGlobal(
          accessToken: _accessToken(),
          resolution: resolution,
        );
      } catch (e) {
        defaultsError = e;
        return const [];
      }
    }

    Future<List<Emote>> getUnlockable() async {
      try {
        return await TwitchEmoteProvider.fetchGlobalUnlockable(
          accessToken: _accessToken(),
          resolution: resolution,
        );
      } catch (e) {
        logDebug('[EmoteFetcher] global unlockable emotes failed: $e');
        return const [];
      }
    }

    final results = await Future.wait([
      getDefaults(),
      getUnlockable(),
    ], eagerError: false);
    defaults = results[0];
    unlockable = results[1];
    if (defaultsError != null && defaults.isEmpty && unlockable.isEmpty) {
      throw defaultsError!;
    }
    final keys = emoteOverlayKeys(unlockable);
    if (unlockable.isEmpty) return (emotes: defaults, unlockIds: keys.ids);
    // Unlockable catalogue wins on code collision (limited-time rotations
    // reuse names with new ids); dedup by id too.
    final merged = <Emote>[
      for (final e in defaults)
        if (!overlayCollides(e, keys)) e,
      ...unlockable,
    ];
    final seen = <String>{};
    return (
      emotes: [
        for (final e in merged)
          if (e.id.isEmpty || seen.add(e.id)) e,
      ],
      unlockIds: keys.ids,
    );
  }

  /// Cached connectivity probe (avoids per-fetch platform calls).
  Future<ConnectivityResult> _probeConnectivity() async {
    final probe = _connectivityProbe;
    if (probe == null) return ConnectivityResult.wifi;
    final now = _now();
    final probedAt = _probeAt;
    if (probedAt != null && now.difference(probedAt) < _connectivityProbeTtl) {
      return _probeResult;
    }
    try {
      final results = await probe();
      _probeResult = results.contains(ConnectivityResult.mobile)
          ? ConnectivityResult.mobile
          : ConnectivityResult.wifi;
    } catch (e) {
      logDebug('[EmoteFetcher] connectivity probe failed, assuming wifi: $e');
      _probeResult = ConnectivityResult.wifi;
    }
    _probeAt = _now();
    return _probeResult;
  }

  /// Runs each provider, returning the types that threw. Per-provider errors
  /// are isolated so one provider cannot abort the rest.
  Future<Set<EmoteType>> _fetchConcurrent(
    Map<EmoteType, Future<List<Emote>> Function()> providers, {
    required int maxConcurrent,
  }) async {
    final sem = Semaphore(maxConcurrent);
    final failed = <EmoteType>{};
    final futures = <Future<void>>[];
    for (final entry in providers.entries) {
      futures.add(
        sem.withPermit(() async {
          try {
            await entry.value();
          } catch (e) {
            failed.add(entry.key);
            logDebug('[EmoteFetcher] ${entry.key.name} failed: $e');
          }
        }),
      );
    }
    await Future.wait(futures, eagerError: false);
    return failed;
  }
}
