import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../models/emote_fetch_tier.dart';
import '../emotes/emote.dart';
import '../emotes/emote_catalog.dart';
import '../emotes/emote_meta.dart';
import '../models/twitch_message.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../util/log.dart';
import '../util/prefs.dart';
import '../util/semaphore.dart';
import 'emote_cache_manager.dart';
import 'emote_fetch.dart';
import 'emote_meta_store.dart';
import 'seven_tv_event_client.dart';
import 'emote_providers/twitch_emotes.dart';
import 'emote_providers/bttv_emotes.dart';
import 'emote_providers/ffz_emotes.dart';
import 'emote_providers/seven_tv_emotes.dart';

/// Another viewer's personal 7TV emotes, cached for sender-scoped render.

/// Per-URL usage history feeding the disk-cache eviction priority.
///
/// Tracks the last-use time plus a rolling 24-hour histogram of view counts
/// in hourly buckets, so the cache can keep emotes that are *steadily* used
/// over time and evict ones that were spammed in a single burst then went
/// quiet. The score combines:
///
///   recency r = exp(-hoursSinceLastUse / [_recencyHalfLife])
///   total   T = views in the last 24 hours
///   entropy H = normalized entropy of the bucket distribution (1 = spread
///               evenly across the day, 0 = all views in one hour)
///   steady  s = min(T / [_steadyRate], 1) * H
///   score   = r + [_steadyWeight] * s
///
/// Pure logic (no I/O); the [EmoteManager] owns persistence. The bucket
/// index is anchored at [_EmoteUsageRecord.bucketBase] (unix hour of the
/// oldest bucket) so advancing an hour never shifts the list.
class EmoteUsageRecord {
  EmoteUsageRecord({
    required this.lastUsedAt,
    required this.bucketBase,
    required List<int> buckets,
  }) : buckets = List.unmodifiable(buckets) {
    assert(buckets.length == _bucketCount);
  }

  /// Views within the last [Duration] window are counted in these buckets.
  static const int _bucketCount = 24;
  // A long, lax recency window for the usage score: it keeps the emote
  // priority score stable so the cache eviction admission check (see
  // EmoteCacheManager._evictLowest) does not thrash long-lived favorites for
  // one-off emotes.
  static const _recencyHalfLife = Duration(days: 3);
  static const _steadyRate = 50;
  static const _steadyWeight = 0.75;

  /// Unix hour of [buckets] index 0; buckets are zeroed as the window rolls
  /// past them, so older data simply ages out.
  final int bucketBase;

  final DateTime lastUsedAt;
  final List<int> buckets;

  /// Records a view at the given unix hour (0-23 UTC is not used; the hour is
  /// an absolute unix hour). Rolls the window forward first so stale buckets
  /// age out.
  static EmoteUsageRecord bumped(
    EmoteUsageRecord record,
    int hour, {
    required DateTime now,
  }) {
    final rolled = rolledForward(record, hour);
    final index = ((hour - rolled.bucketBase) % _bucketCount).toInt();
    final buckets = List<int>.of(rolled.buckets);
    buckets[index]++;
    return EmoteUsageRecord(
      lastUsedAt: now,
      buckets: buckets,
      bucketBase: rolled.bucketBase,
    );
  }

  /// Instance form of [bumped] for a just-created zero record.
  EmoteUsageRecord bumpedAt(int hour, {required DateTime now}) =>
      EmoteUsageRecord.bumped(this, hour, now: now);

  /// Returns a record whose window starts at (or covers) [hour], zeroing
  /// buckets that rolled out. Cheap for records that were just bumped; only
  /// stale records pay for the roll.
  static EmoteUsageRecord rolledForward(EmoteUsageRecord record, int hour) {
    var base = record.bucketBase;
    if (hour < base || hour - base >= _bucketCount) {
      // Clock moved backwards or the whole window is stale: rebuild empty.
      if (hour < base) return record;
      return EmoteUsageRecord(
        lastUsedAt: record.lastUsedAt,
        buckets: List.filled(_bucketCount, 0),
        bucketBase: hour,
      );
    }
    if (hour == base) return record;
    final buckets = List<int>.of(record.buckets);
    final advance = hour - base;
    // Bucket i covers hour (base + i), so hours that rolled out are exactly
    // buckets 0..advance-1 (the bucket list wraps, but the base never does).
    for (var i = 0; i < advance; i++) {
      buckets[i] = 0;
    }
    return EmoteUsageRecord(
      lastUsedAt: record.lastUsedAt,
      buckets: buckets,
      bucketBase: hour,
    );
  }

  /// Keep-priority score at [now]; higher means the emote should stay cached.
  /// Only meaningful for records whose window covers [now] (roll first).
  double score(DateTime now) {
    final hours = now.difference(lastUsedAt).inHours;
    final r = math.exp(-hours / _recencyHalfLife.inHours.toDouble());
    var total = 0;
    for (final b in buckets) {
      total += b;
    }
    if (total == 0) return r;
    final steady = (total / _steadyRate).clamp(0.0, 1.0) * _entropy();
    return r + _steadyWeight * steady;
  }

  double _entropy() {
    var total = 0;
    for (final b in buckets) {
      total += b;
    }
    if (total == 0) return 0;
    var entropy = 0.0;
    for (final b in buckets) {
      if (b == 0) continue;
      final p = b / total;
      entropy -= p * math.log(p);
    }
    return entropy / math.log(_bucketCount.toDouble());
  }

  Map<String, dynamic> toJson() => {
    't': lastUsedAt.millisecondsSinceEpoch,
    'h': bucketBase,
    'b': buckets.join(','),
  };

  static EmoteUsageRecord? fromJson(Map<String, dynamic> json) {
    final t = json['t'];
    final h = json['h'];
    final b = json['b'];
    if (t is! int || h is! int || b is! String) return null;
    final buckets = <int>[];
    for (final part in b.split(',')) {
      final v = int.tryParse(part);
      if (v == null || v < 0) return null;
      buckets.add(v);
    }
    if (buckets.length != _bucketCount) return null;
    return EmoteUsageRecord(
      lastUsedAt: DateTime.fromMillisecondsSinceEpoch(t),
      buckets: buckets,
      bucketBase: h,
    );
  }
}

class EmoteManager extends ChangeNotifier {
  // Refresh TTLs: emote caches are only refetched once they're older than
  // the TTL. Unmetered connections refresh every 12h; cellular gets 24h so
  // the rake uses less data.
  static const _wifiTtl = Duration(hours: 12);
  static const _mobileTtl = Duration(hours: 24);
  static const _connectivityProbeTtl = Duration(seconds: 60);
  static const _infiniteTtl = Duration(days: 365000);
  static const _defaultFetchStagger = Duration(milliseconds: 1500);

  // ── Disk-cache cap + usage registry ─────────────────────────────────
  // The emote image cache is capped inline by EmoteCacheManager (evicting the
  // least-recently-used extras once it grows past maxObjects). This manager
  // only owns the usage registry that feeds that priority, plus the one-time
  // migrations from the old cache layouts.
  static const _usageMinEntries = 300;

  EmoteFetchTier _tier = EmoteFetchTier.high;
  int _cacheCap = defaultEmoteCacheMax;

  late final Future<void> Function(String url) _removeCachedFile;
  final DateTime Function() _now;
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
  final EmoteCacheManager? _injectedCacheManager;
  EmoteCacheManager? _cacheManagerInstance;
  final EmoteMetaStore _metaStore;
  final Map<String, EmoteUsageRecord> _emoteUsage = {};

  /// Resolved lazily so constructing an [EmoteManager] (e.g. in tests) never
  /// instantiates the path-provider-backed cache singleton until it's needed.
  EmoteCacheManager get _cacheManager =>
      _cacheManagerInstance ??= (_injectedCacheManager ?? EmoteCacheManager());
  bool _usageLoaded = false;
  bool _usageDirty = false;
  bool _migrationRan = false;
  bool _migrationRanV2 = false;
  bool _disposed = false;

  final Future<List<ConnectivityResult>> Function()? _connectivityProbe;
  final Duration _fetchStagger;
  ConnectivityResult _probeResult = ConnectivityResult.wifi;
  DateTime? _probeAt;
  // Bounds in-flight provider fetches so a full refresh doesn't burst the
  // network, while letting more than one channel refresh at a time.
  static const _maxConcurrentFetches = 2;
  final _fetchGate = Semaphore(_maxConcurrentFetches);

  // How long view-touch flushes wait for quiet before persisting. The emote
  // menu marks dozens of cells viewed on open; the debounce collapses that
  // burst into a single prefs write.
  static const _defaultUsageFlushDelay = Duration(milliseconds: 250);
  final Duration _usageFlushDelay;
  Timer? _usageFlushTimer;

  EmoteManager({
    Future<List<ConnectivityResult>> Function()? probe,
    this._fetchStagger = _defaultFetchStagger,
    Future<void> Function(String url)? removeCachedFile,
    DateTime Function()? now,
    EmoteFetchTier tier = EmoteFetchTier.high,
    int cacheCap = defaultEmoteCacheMax,
    this._usageFlushDelay = _defaultUsageFlushDelay,
    Future<SevenTvChannelResponse> Function(
      String channelId,
      EmoteResolution resolution,
    )?
    sevenTvChannelFetcher,
    Future<List<Emote>> Function(EmoteResolution resolution)?
    sevenTvGlobalFetcher,
    Future<List<String>> Function(String twitchId)? sevenTvOwnedSetIdsFetcher,
    Future<List<Emote>> Function(String setId, EmoteResolution resolution)?
    sevenTvEmoteSetFetcher,
    EmoteCacheManager? cacheManager,
    EmoteMetaStore? metaStore,
    Future<Map<String, String>> Function(TwitchAuth auth, List<String> ids)?
    resolveOwnerLogins,
    Future<Map<String, List<Emote>>> Function(
      List<String> setIds, {
      String? accessToken,
      EmoteResolution? resolution,
    })?
    fetchUserEmoteSets,
    this.getChannelUserIds,
  }) : _connectivityProbe = probe,
       _injectedCacheManager = cacheManager,
       _metaStore = metaStore ?? EmoteMetaStore.I,
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
           sevenTvOwnedSetIdsFetcher ?? SevenTvEmoteProvider.fetchOwnedSetIds,
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
           )),
       _now = now ?? DateTime.now {
    _removeCachedFile =
        removeCachedFile ?? ((String url) => _cacheManager.removeFile(url));
    _tier = tier;
    _cacheCap = cacheCap.clamp(minEmoteCacheMax, maxEmoteCacheMax).toInt();
  }

  /// Fetching tier controlling resolution, cache TTL, and 7TV reconcile gating.
  EmoteFetchTier get tier => _tier;

  set tier(EmoteFetchTier value) {
    if (value == _tier) return;
    _tier = value;
    _notify();
  }

  /// Max emote image files the disk cache keeps (default [defaultEmoteCacheMax],
  /// clamped to [minEmoteCacheMax]..[maxEmoteCacheMax]). Enforced inline by the
  /// [EmoteCacheManager] on the next fetch.
  int get cacheCap => _cacheCap;

  set cacheCap(int value) {
    _cacheCap = value.clamp(minEmoteCacheMax, maxEmoteCacheMax).toInt();
    final cache = _cacheManager;
    cache.maxObjects = _cacheCap;
    cache.priorityScore = _registryScore;
    cache.lastUsedAt = (url) => _emoteUsage[url]?.lastUsedAt;
  }

  // Global provider catalog plus a resolved flag. The catalog persists
  // list-for-list, so per-provider retention and toggle rebuilds need no
  // lossy reconstruction.
  EmoteCatalog _globalCatalog = EmoteCatalog();
  bool _globalResolved = false;
  // Epoch per scope: a forced refresh or evict bumps it, so a commit from an
  // older in-flight fetch is dropped instead of overwriting newer state.
  int _globalEpoch = 0;
  // Per-channel emote metadata (code maps, not image bytes: decoded pixels
  // and disk files are shared by URL across channels). One catalog per joined
  // channel; evictChannel frees it on leave, so no cap is kept.
  final _channelCatalogs = <String, EmoteCatalog>{};
  final _channelEpoch = <String, int>{};
  final _channelFetchTimes = <String, DateTime>{};
  final _emotesResolvedChannels = <String>{};

  /// Resolves sub-emote owner ids to logins (default: Helix /users). Injected
  /// for tests; the manager owns the cache so grouping never needs a parallel
  /// map and reconnect can re-resolve without re-fetching.
  final Future<Map<String, String>> Function(TwitchAuth auth, List<String> ids)
  _resolveOwnerLogins;

  /// Fetches emote sets by id (default: Twitch EmoteProvider). Injected for
  /// tests so the daemon's fetch + resolve + store path is fully exercised
  /// without network access.
  final Future<Map<String, List<Emote>>> Function(
    List<String> setIds, {
    String? accessToken,
    EmoteResolution? resolution,
  })
  _fetchUserEmoteSets;

  /// Live open-channel -> broadcaster-id source, injected by the app layer and
  /// read at store time. Late-resolving ids must still receive fetched subs;
  /// null in unit tests, which pass explicit maps instead.
  final Map<String, String> Function()? getChannelUserIds;

  /// Emote-set ids already fetched via the IRC emote-sets path, so repeated
  /// USERSTATE (per channel join / message send) doesn't refetch them. Owned
  /// by the manager now so the daemon is the single source of fetch state.
  final Set<String> _fetchedEmoteSetIds = {};

  /// Set ids currently in flight; dropped on failure so the next event retries.
  final Set<String> _inflightEmoteSetIds = {};

  /// Whether a subscriber-emote fetch is currently in flight. The subs tab
  /// shows a spinner (not the empty text) while true, so a slow fetch never
  /// reads as "no subscriber emotes".
  bool get subEmoteFetchInFlight => _inflightEmoteSetIds.isNotEmpty;

  /// owner id -> login, built up across resolves and reused between reconnects.
  final Map<String, String> _emoteOwnerLogins = {};

  /// Last fetched user sub-emote sets keyed by owner id. Kept in memory so a
  /// reconnect can re-stamp resolved logins and re-store without re-fetching.
  final Map<String, List<Emote>> _fetchedSubEmotesByOwner = {};
  final _sevenTvEmoteSetIds = <String, String>{};
  final _sevenTvUserIds = <String, String>{};
  // Last seen broadcaster id per channel, so targeted provider refetches can
  // run without the caller re-supplying it.
  final _channelBroadcasterIds = <String, String>{};
  // Owner-less Twitch unlocks from the IRC emote-sets path (per-account
  // Prime/Turbo/2FA/Hype Train emotes). Merged into the global lookup.
  final _unlockedTwitchEmotes = <String, Emote>{};
  // Ids from the global unlockable catalogue (broadcaster_id=0). Per-account
  // like the emote-set unlocks, so excluded from disk and pruned on reset.
  final _twitchCatalogUnlockIds = <String>{};
  String? _accessToken;
  // Viewer Twitch user id; personal 7TV grants are matched against it.
  String? _viewerTwitchId;
  // Owned 7TV set ids and their merged emotes (personal grants, usable in
  // every channel). Kept out of the persisted caches; rebuilt per account.
  final _personalSevenTvSetIds = <String>{};
  final _personalSevenTvSets = <String, List<Emote>>{};
  // Other viewers' personal 7TV sets, learned from the socket (chatterino7
  // parity): entitlement.create maps users to sets, emote_set.* fills the
  // contents. Sender-scoped: only that sender's messages render them. No
  // per-sender REST; unknown set contents fetch once per set id. These maps
  // hold metadata only (codes and URLs); image bytes stay centralized in the
  // URL-keyed disk and decoded caches, so a personal emote shared with a
  // channel set decodes once. Foreign sets are sparse (seen only when their
  // owner chats), so the 50-entry LRU below needs no churn handling.
  final _foreignPersonalSetOwners = <String, Set<String>>{};
  final _foreignPersonalUserSets = <String, Set<String>>{};
  final _foreignPersonalSetContents = <String, List<Emote>>{};
  final _foreignPersonalSetInflight = <String, Future<void>>{};
  final _foreignPersonalSets = <String, EmoteLookup>{};
  // Unmapped sets render for nobody; bound the contents map.
  // Eviction is least-recently-touched first (insertion order doubles as
  // recency: touches reinsert). Render lookups never touch; too hot.
  static const _maxForeignPersonalSets = 50;
  final _mergedCache = <String, EmoteLookup?>{};
  String? _changedChannel;
  // Monotonic counter bumped on every notify; message span caches compare
  // against it so stale spans can be detected lazily instead of clearing
  // every message's cached spans on each emote change.
  int _version = 0;

  /// Current emote-data version. Increments on every [notifyListeners]
  /// emission (tier/cache changes, global or per-channel emote updates).
  int get version => _version;

  // [bumpVersion] controls whether the span-cache version advances. Live 7TV
  // deltas skip it so already-rendered messages keep the emote state they
  // were built with (no retroactive re-rendering); full refetches bump it.
  void _notify({String? channel, bool bumpVersion = true}) {
    if (_disposed) return;
    if (bumpVersion) _version++;
    _emoteIndexDirty = true;
    _changedChannel = channel;
    if (channel != null) {
      _mergedCache.remove(channel);
    } else {
      _mergedCache.clear();
    }
    super.notifyListeners();
  }

  /// Channel whose emotes changed; cleared on read.
  String? consumeChangedChannel() {
    final c = _changedChannel;
    _changedChannel = null;
    return c;
  }

  // 7TV delta codes per channel; absent after non-delta notifies.
  final _lastChangedCodes = <String, Set<String>>{};

  /// Last 7TV delta codes for [channel]; null means full refetch.
  Set<String>? consumeChangedCodes(String channel) {
    return _lastChangedCodes.remove(channel);
  }

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

  // Live 7TV list; re-applied after fetch rebuilds to avoid clobbering.
  final _sevenTvLive = <String, List<Emote>>{};

  set accessToken(String? value) => _accessToken = value;

  // Merged emotes: channel overrides global, personal 7TV merges everywhere.
  // Cached until notify.
  EmoteLookup? byCode(String channel) {
    final cached = _mergedCache[channel];
    if (cached != null) return cached;
    final channelCatalog = _channelCatalogs[channel];
    final hasGlobalData =
        _globalResolved ||
        _unlockedTwitchEmotes.isNotEmpty ||
        _personalSevenTvSets.isNotEmpty;
    EmoteLookup? result;
    if (channelCatalog == null && !hasGlobalData) {
      result = null;
    } else {
      result = _buildLookup(
        global: _globalCatalog,
        channel: channelCatalog,
        personal: _personalEmotes,
      );
    }
    _mergedCache[channel] = result;
    return result;
  }

  // Viewer personal 7TV emotes in merge order (first set wins code conflicts).
  Iterable<Emote> get _personalEmotes sync* {
    for (final setEmotes in _personalSevenTvSets.values) {
      yield* setEmotes;
    }
  }

  // Catalog merge plus the per-account unlock overlay and visibility
  // filters. Callers cache the result in _mergedCache.
  EmoteLookup _buildLookup({
    required EmoteCatalog global,
    EmoteCatalog? channel,
    Iterable<Emote> personal = const [],
  }) => mergeEmoteLookup(
    global: global.copyWith(twitchGlobal: _withUnlocked(global.twitchGlobal)),
    channel: channel,
    personal: personal,
    disabledProviders: _disabledProviders,
    allowUnlisted7tv: _allowUnlisted7tv,
  );

  /// Twitch emotes that need sender proof: they render only from the IRC
  /// `emotes` tag, never from a bare word match. Covers sub, follower, and
  /// bits tiers. Globals and unlockables stay word-matchable.
  static bool isTwitchLocked(Emote e) =>
      e.meta is TwitchMeta &&
      (e.meta as TwitchMeta).kind != TwitchEmoteKind.standard;

  /// True subs are stored with the channel's Twitch list, not the provider
  /// stash or disk. Shared by every sub filter so they cannot drift apart.
  /// Follower/bitstier emotes are sender-proof like subs for rendering but
  /// stay word-matchable state in the stash.
  static bool _isTwitchSub(Emote e) =>
      e.meta is TwitchMeta &&
      (e.meta as TwitchMeta).kind == TwitchEmoteKind.sub;

  /// Fallback image URL for a Twitch emote id the API map does not contain.
  static String twitchFallbackUrl(String id) =>
      'https://static-cdn.jtvnw.net/emoticons/v2/$id/default/dark/3.0';

  /// Shared tokenizer: Twitch positional emotes first, then word matches.
  /// Locked Twitch emotes never match by word; everything else does.
  static List<EmoteToken> tokenize({
    required String text,
    required List<EmotePosition>? positions,
    required Map<String, Emote> byCode,
  }) {
    final tokens = <EmoteToken>[];
    final sortedPos = positions ?? const <EmotePosition>[];
    var twitchIdx = 0;

    EmotePosition? posAt(int i) {
      while (twitchIdx < sortedPos.length &&
          sortedPos[twitchIdx].endIndex <= i) {
        twitchIdx++;
      }
      if (twitchIdx < sortedPos.length &&
          i >= sortedPos[twitchIdx].startIndex) {
        return sortedPos[twitchIdx];
      }
      return null;
    }

    var i = 0;
    while (i < text.length) {
      final pos = posAt(i);
      if (pos != null) {
        final emote =
            byCode[pos.emoteCode] ??
            Emote(
              id: pos.emoteId,
              code: pos.emoteCode,
              meta: const TwitchMeta(kind: TwitchEmoteKind.standard),
              url: twitchFallbackUrl(pos.emoteId),
            );
        tokens.add(
          EmoteToken(
            emote: emote,
            text: text.substring(i, pos.endIndex),
            start: i,
            end: pos.endIndex,
          ),
        );
        i = pos.endIndex;
        continue;
      }

      if (text[i] == ' ' || text[i] == '\t' || text[i] == '\n') {
        final start = i;
        while (i < text.length &&
            (text[i] == ' ' || text[i] == '\t' || text[i] == '\n')) {
          i++;
        }
        tokens.add(
          EmoteToken(text: text.substring(start, i), start: start, end: i),
        );
        continue;
      }

      final start = i;
      while (i < text.length &&
          text[i] != ' ' &&
          text[i] != '\t' &&
          text[i] != '\n' &&
          posAt(i) == null) {
        i++;
      }
      final word = text.substring(start, i);
      final emote = byCode[word];
      if (emote != null && !isTwitchLocked(emote)) {
        tokens.add(EmoteToken(emote: emote, text: word, start: start, end: i));
      } else {
        tokens.add(EmoteToken(text: word, start: start, end: i));
      }
    }
    return tokens;
  }

  /// What the viewer can type in [channel]: the merged, visibility-filtered
  /// suggestion list. Owned subs are already fanned into every channel, and
  /// follower emotes only exist in their home channel, so no extra merge.
  List<Emote> sendableEmotes(String channel) =>
      byCode(channel)?.suggestions ?? const [];

  /// Recents resolved to [channel]-local codes; dead ids are dropped.
  Future<List<Emote>> recentsForChannel(String channel) async {
    final recents = await recentEmotes();
    final suggestions = byCode(channel)?.suggestions;
    if (suggestions == null) return recents;
    return resolveRecentsForChannel(recents, suggestions);
  }

  /// Subscriber emotes grouped by owner, with [pinnedChannel] first.
  Map<String, List<Emote>> subsGrouped({String? pinnedChannel}) {
    final grouped = Map<String, List<Emote>>.of(subscriberEmotesByChannel());
    final pinned = pinnedChannel != null ? grouped.remove(pinnedChannel) : null;
    if (pinned == null) return grouped;
    return {pinnedChannel!: pinned, ...grouped};
  }

  /// Channel picker tab: third-party channel emotes plus unlocked Twitch
  /// channel emotes, sorted by code. Status-gated Twitch emotes (subs,
  /// followers, bitstier) live in the subs tab instead: they only render
  /// from the IRC tag, so listing them here implies anyone can use them.
  List<Emote> channelTabEmotes(String channel) {
    final cached = _filterVisible(_channelLookup(channel));
    if (cached == null) return [];
    final result = cached.suggestions.where((e) => !isTwitchLocked(e)).toList();
    result.sort((a, b) => a.code.compareTo(b.code));
    return result;
  }

  /// Emotes found in [text] for precache: tag emotes by id plus word
  /// matches under the sender-proof rule, deduped by id.
  List<Emote> matchEmotes({
    required String channel,
    required String text,
    required List<EmotePosition>? positions,
    String? senderTwitchId,
  }) {
    final lookup = senderTwitchId == null
        ? byCode(channel)
        : byCodeForSender(channel, senderTwitchId);
    if (lookup == null) return const [];
    final seen = <String>{};
    final found = <Emote>[];
    for (final token in tokenize(
      text: text,
      positions: positions,
      byCode: lookup.byCode,
    )) {
      final emote = token.emote;
      if (emote != null && seen.add(emote.id)) found.add(emote);
    }
    return found;
  }

  /// Viewer Twitch user id for matching personal 7TV grants. Cleared logout.
  set viewerTwitchId(String? value) {
    if (_viewerTwitchId == value) return;
    _viewerTwitchId = value;
    _personalSevenTvSetIds.clear();
    _personalSevenTvSets.clear();
    _notify();
  }

  /// Bootstrap: fetch the viewer's owned 7TV sets and their emotes.
  /// Restores the persisted seed first so known sets skip the network.
  Future<void> loadViewerPersonalSevenTvSets({bool force = false}) async {
    await loadPersistedPersonalSets();
    final viewerId = _viewerTwitchId;
    if (viewerId == null || viewerId.isEmpty) return;
    if (_tier == EmoteFetchTier.nothing) return;
    if (!_isProviderOn(EmoteType.sevenTv)) return;
    // Tier upgrade: known set ids would skip the refetch below and keep
    // the old resolution, so forget them and re-pull. Map entries stay
    // until replaced, so a failed fetch keeps the old URLs.
    if (force) _personalSevenTvSetIds.clear();
    List<String> setIds;
    try {
      setIds = await _sevenTvOwnedSetIds(viewerId);
    } catch (e) {
      logDebug('[EmoteManager] personal 7TV set listing failed: $e');
      return;
    }
    var changed = false;
    for (final setId in setIds) {
      if (_personalSevenTvSetIds.contains(setId)) continue;
      List<Emote> emotes;
      try {
        emotes = await _sevenTvEmoteSetFetcher(setId, _tier.resolution!);
      } catch (e) {
        logDebug('[EmoteManager] personal 7TV set $setId failed: $e');
        continue;
      }
      _personalSevenTvSetIds.add(setId);
      _personalSevenTvSets[setId] = emotes;
      changed = true;
    }
    if (changed) {
      _notify();
      unawaited(_savePersonalSets());
    }
  }

  /// Live personal 7TV grant/revoke from the entitlement stream. The
  /// viewer's own EMOTE_SET events feed the personal merge; everyone else's
  /// feed the socket-first foreign discovery (chatterino7 parity, no
  /// per-sender REST).
  Future<void> applySevenTvEntitlement(SevenTvEntitlementEvent event) async {
    if (event.cosmeticKind != 'EMOTE_SET') return;
    final viewerId = _viewerTwitchId;
    if (viewerId == null || !event.twitchUserIds.contains(viewerId)) {
      if (event.kind == 'entitlement.delete') {
        dropForeignPersonalGrant(event.twitchUserIds, event.cosmeticId);
      } else {
        await trackForeignPersonalGrant(event.twitchUserIds, event.cosmeticId);
      }
      return;
    }
    if (_tier == EmoteFetchTier.nothing) return;
    if (!_isProviderOn(EmoteType.sevenTv)) return;
    if (event.kind == 'entitlement.delete') {
      final hadSet = _personalSevenTvSetIds.remove(event.cosmeticId);
      final hadEmotes = _personalSevenTvSets.remove(event.cosmeticId) != null;
      if (hadSet || hadEmotes) {
        _notify();
        unawaited(_savePersonalSets());
      }
      return;
    }
    if (_personalSevenTvSetIds.contains(event.cosmeticId)) return;
    List<Emote> emotes;
    try {
      emotes = await _sevenTvEmoteSetFetcher(
        event.cosmeticId,
        _tier.resolution!,
      );
    } catch (e) {
      logDebug('[EmoteManager] personal 7TV grant fetch failed: $e');
      return;
    }
    _personalSevenTvSetIds.add(event.cosmeticId);
    _personalSevenTvSets[event.cosmeticId] = emotes;
    _notify();
    unawaited(_savePersonalSets());
  }

  /// Map for one message: channel sets plus the sender's personal 7TV emotes
  /// underneath. Foreign codes never leak into other senders' messages.
  EmoteLookup? byCodeForSender(String channel, String? senderTwitchId) {
    final base = byCode(channel);
    final record = senderTwitchId == null
        ? null
        : _foreignPersonalSets[senderTwitchId];
    if (record == null || record.byCode.isEmpty) return base;
    if (!_isProviderOn(EmoteType.sevenTv)) return base;
    final foreign = _filterVisible(
      EmoteLookup(
        byCode: record.byCode,
        suggestions: record.byCode.values.toList(),
      ),
    );
    if (foreign == null) return base;
    final merged = {...foreign.byCode};
    if (base != null) merged.addAll(base.byCode);
    final suggestions = merged.values.toList()
      ..sort((a, b) => a.code.compareTo(b.code));
    return EmoteLookup(byCode: merged, suggestions: suggestions);
  }

  /// Maps foreign users to a personal set from a socket entitlement grant.
  /// Unknown set contents fetch once per set id (shared by all owners).
  Future<void> trackForeignPersonalGrant(
    Iterable<String> userTwitchIds,
    String setId,
  ) async {
    if (setId.isEmpty) return;
    var mappingChanged = false;
    for (final userId in userTwitchIds) {
      if (userId.isEmpty) continue;
      // The viewer's own grants live in _personalSevenTvSets, never here.
      if (userId == _viewerTwitchId) continue;
      if (_foreignPersonalUserSets.putIfAbsent(userId, () => {}).add(setId)) {
        mappingChanged = true;
      }
      _foreignPersonalSetOwners.putIfAbsent(setId, () => {}).add(userId);
    }
    _touchForeignPersonalSet(setId);
    if (_foreignPersonalSetContents.containsKey(setId)) {
      if (mappingChanged) {
        _rebuildForeignPersonalUsers(setId);
        _notify();
      }
      return;
    }
    if (mappingChanged) _rebuildForeignPersonalUsers(setId);
    await _fillForeignPersonalSet(setId);
    unawaited(_savePersonalSets());
  }

  /// Drops a foreign user's personal-set grant (entitlement.delete).
  void dropForeignPersonalGrant(Iterable<String> userTwitchIds, String setId) {
    if (setId.isEmpty) return;
    var changed = false;
    for (final userId in userTwitchIds) {
      final sets = _foreignPersonalUserSets[userId];
      if (sets == null) continue;
      if (sets.remove(setId)) changed = true;
      if (sets.isEmpty) {
        _foreignPersonalUserSets.remove(userId);
        _foreignPersonalSets.remove(userId);
      } else {
        _rebuildForeignPersonalUser(userId);
      }
    }
    final owners = _foreignPersonalSetOwners[setId];
    if (owners != null) {
      owners.removeAll(userTwitchIds);
      if (owners.isEmpty) {
        _foreignPersonalSetOwners.remove(setId);
        _foreignPersonalSetContents.remove(setId);
      }
    }
    if (changed) {
      _notify();
      unawaited(_savePersonalSets());
    }
  }

  // Marks a live set recently used. Placeholders stay put; only live sets
  // move, so untouched empties are evicted first.
  void _touchForeignPersonalSet(String setId) {
    final contents = _foreignPersonalSetContents[setId];
    if (contents == null || contents.isEmpty) return;
    _foreignPersonalSetContents.remove(setId);
    _foreignPersonalSetContents[setId] = contents;
  }

  // Drops a set nobody references (revoked or over the cap).
  void _evictForeignPersonalSet(String setId) {
    _foreignPersonalSetOwners.remove(setId);
    _foreignPersonalSetContents.remove(setId);
    for (final userId in _foreignPersonalUserSets.keys.toList()) {
      final sets = _foreignPersonalUserSets[userId]!;
      if (!sets.remove(setId)) continue;
      if (sets.isEmpty) {
        _foreignPersonalUserSets.remove(userId);
        _foreignPersonalSets.remove(userId);
      } else {
        _rebuildForeignPersonalUser(userId);
      }
    }
  }

  /// Placeholder for a personal set announced over the socket whose contents
  /// arrive via later emote_set.update dispatches.
  void trackForeignPersonalSet(String setId) {
    if (setId.isEmpty) return;
    _foreignPersonalSetContents.putIfAbsent(setId, () => []);
  }

  /// Applies a socket emote_set.update to a tracked foreign personal set.
  /// Unknown sets are ignored: without a grant mapping the contents render
  /// for nobody.
  void applyForeignPersonalSetUpdate({
    required String setId,
    required List<Emote> added,
    required List<String> removedIds,
    required Map<String, String> renamed,
  }) {
    final contents = _foreignPersonalSetContents[setId];
    if (contents == null) return;
    var changed = false;
    if (removedIds.isNotEmpty) {
      final ids = removedIds.toSet();
      final before = contents.length;
      contents.removeWhere((e) => ids.contains(e.id));
      changed = changed || contents.length != before;
    }
    for (final entry in renamed.entries) {
      final idx = contents.indexWhere((e) => e.id == entry.key);
      if (idx < 0) continue;
      contents[idx] = contents[idx].copyWith(code: entry.value);
      changed = true;
    }
    for (final e in added) {
      if (contents.any((x) => x.id == e.id)) continue;
      contents.add(e);
      changed = true;
    }
    if (!changed) return;
    _touchForeignPersonalSet(setId);
    _rebuildForeignPersonalUsers(setId);
    _notify();
    unawaited(_savePersonalSets());
  }

  /// One-time REST fill for a socket-announced set. Once per set id, shared
  /// by all owners; failures stay uncached so a later grant retries.
  Future<void> _fillForeignPersonalSet(String setId) async {
    if (_foreignPersonalSetContents.containsKey(setId)) return;
    if (_tier == EmoteFetchTier.nothing) return;
    if (!_isProviderOn(EmoteType.sevenTv)) return;
    if (_foreignPersonalSetInflight.containsKey(setId)) return;
    final future = _fetchGate.withPermit(() async {
      List<Emote> fetched;
      try {
        fetched = await _sevenTvEmoteSetFetcher(setId, _tier.resolution!);
      } catch (e) {
        logDebug('[EmoteManager] foreign 7TV set $setId failed: $e');
        return;
      }
      if (fetched.isEmpty) return;
      _foreignPersonalSetContents.remove(setId);
      _foreignPersonalSetContents[setId] = fetched;
      while (_foreignPersonalSetContents.length > _maxForeignPersonalSets) {
        _evictForeignPersonalSet(_foreignPersonalSetContents.keys.first);
      }
      _rebuildForeignPersonalUsers(setId);
      _notify();
    });
    _foreignPersonalSetInflight[setId] = future;
    try {
      await future;
    } finally {
      _foreignPersonalSetInflight.remove(setId);
    }
  }

  void _rebuildForeignPersonalUsers(String setId) {
    final owners = _foreignPersonalSetOwners[setId];
    if (owners == null) return;
    for (final userId in owners) {
      _rebuildForeignPersonalUser(userId);
    }
  }

  void _rebuildForeignPersonalUser(String userId) {
    final setIds = _foreignPersonalUserSets[userId];
    if (setIds == null || setIds.isEmpty) {
      _foreignPersonalSets.remove(userId);
      return;
    }
    final merged = <String, Emote>{};
    for (final id in setIds) {
      for (final e in _foreignPersonalSetContents[id] ?? const <Emote>[]) {
        merged.putIfAbsent(e.code, () => e);
      }
    }
    if (merged.isEmpty) {
      _foreignPersonalSets.remove(userId);
    } else {
      final suggestions = merged.values.toList()
        ..sort((a, b) => a.code.compareTo(b.code));
      _foreignPersonalSets[userId] = EmoteLookup(
        byCode: merged,
        suggestions: suggestions,
      );
    }
  }

  // Personal sets change rarely and the socket corrects them live, so the
  // disk copy is a long-lived cold-start seed (not a source of truth).
  static const _personalSetsKey = 'emotes3_personal_sets';
  static const _personalSetsTtl = Duration(days: 30);

  @visibleForTesting
  Future<void> flushPersonalSetsForTest() => _savePersonalSets();

  Future<void> _savePersonalSets() async {
    try {
      final viewer = <String, dynamic>{};
      for (final id in _personalSevenTvSetIds) {
        final emotes = _personalSevenTvSets[id];
        if (emotes == null || emotes.isEmpty) continue;
        viewer[id] = emotes.map((e) => e.toJson()).toList();
      }
      final foreign = <String, dynamic>{};
      final owners = <String, dynamic>{};
      for (final entry in _foreignPersonalSetContents.entries) {
        if (entry.value.isEmpty) continue;
        final setOwners = _foreignPersonalSetOwners[entry.key];
        if (setOwners == null || setOwners.isEmpty) continue;
        foreign[entry.key] = entry.value.map((e) => e.toJson()).toList();
        owners[entry.key] = setOwners.toList();
      }
      if (viewer.isEmpty && foreign.isEmpty) {
        await _metaStore.delete(_personalSetsKey);
        return;
      }
      await _metaStore.write(
        _personalSetsKey,
        jsonEncode({
          'ts': DateTime.now().toIso8601String(),
          'viewerId': _viewerTwitchId,
          'viewer': viewer,
          'foreignOwners': owners,
          'foreign': foreign,
        }),
      );
    } catch (_) {
      logDebug('[EmoteManager] failed to save personal sets');
    }
  }

  /// Restores persisted personal sets. Viewer sets apply only to the matching
  /// account; foreign sets apply to everyone. Never overwrites live data:
  /// only unknown set ids are filled.
  Future<void> loadPersistedPersonalSets() async {
    try {
      final raw = await _metaStore.read(_personalSetsKey);
      if (raw == null) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final ts = DateTime.tryParse(data['ts'] as String? ?? '');
      if (ts == null || DateTime.now().difference(ts) > _personalSetsTtl) {
        await _metaStore.delete(_personalSetsKey);
        return;
      }
      var changed = false;
      final viewerId = _viewerTwitchId;
      if (viewerId != null && (data['viewerId'] as String?) == viewerId) {
        final viewer = data['viewer'] as Map<String, dynamic>? ?? {};
        for (final entry in viewer.entries) {
          if (_personalSevenTvSetIds.contains(entry.key)) continue;
          final emotes = _decodeEmoteList(entry.value);
          if (emotes.isEmpty) continue;
          _personalSevenTvSetIds.add(entry.key);
          _personalSevenTvSets[entry.key] = emotes;
          changed = true;
        }
      }
      final foreign = data['foreign'] as Map<String, dynamic>? ?? {};
      final owners = data['foreignOwners'] as Map<String, dynamic>? ?? {};
      for (final entry in foreign.entries) {
        if (_foreignPersonalSetContents.containsKey(entry.key)) continue;
        final emotes = _decodeEmoteList(entry.value);
        if (emotes.isEmpty) continue;
        final setOwners = (owners[entry.key] as List<dynamic>? ?? [])
            .whereType<String>()
            .where((u) => u.isNotEmpty && u != viewerId)
            .toSet();
        if (setOwners.isEmpty) continue;
        _foreignPersonalSetContents[entry.key] = emotes;
        _foreignPersonalSetOwners[entry.key] = setOwners;
        for (final userId in setOwners) {
          _foreignPersonalUserSets.putIfAbsent(userId, () => {}).add(entry.key);
        }
        _rebuildForeignPersonalUsers(entry.key);
        changed = true;
      }
      if (changed) _notify();
    } catch (_) {
      logDebug('[EmoteManager] failed to load personal sets');
    }
  }

  List<Emote> _decodeEmoteList(Object? raw) {
    final out = <Emote>[];
    if (raw is! List<dynamic>) return out;
    for (final item in raw) {
      try {
        if (item is Map<String, dynamic>) {
          out.add(Emote.fromJson(item));
        }
      } catch (_) {}
    }
    return out;
  }

  // Display order for global grid (differs from dedup priority).
  static const _globalSortPriority = {
    EmoteType.sevenTv: 0,
    EmoteType.twitch: 1,
    EmoteType.bttv: 2,
    EmoteType.ffz: 3,
  };

  static const _globalProviderLabels = {
    EmoteType.sevenTv: 'SevenTV',
    EmoteType.twitch: 'Twitch',
    EmoteType.bttv: 'BetterTTV',
    EmoteType.ffz: 'FrankerFaceZ',
  };

  // Global emotes by provider, in display order, sorted by code.
  Map<String, List<Emote>> globalEmotesByProvider() {
    final lookup = _buildLookup(
      global: _globalCatalog,
      personal: _personalEmotes,
    );
    final grouped = <EmoteType, List<Emote>>{};
    for (final e in lookup.suggestions) {
      (grouped[e.type] ??= []).add(e);
    }
    final result = <String, List<Emote>>{};
    for (final t in _globalSortPriority.keys) {
      final list = grouped[t];
      if (list == null || list.isEmpty) continue;
      list.sort((a, b) => a.code.compareTo(b.code));
      result[_globalProviderLabels[t] ?? ''] = list;
    }
    return result;
  }

  /// Whether [channel]'s cache exists (stale is fine).
  bool hasChannelCache(String channel) => _channelCatalogs.containsKey(channel);

  /// Whether the global emote cache has been resolved at least once.
  bool get hasGlobalCache => _globalResolved;

  Map<String, List<Emote>>? _subsByChannelCache;

  Map<String, List<Emote>> subscriberEmotesByChannel() {
    if (!_isProviderOn(EmoteType.twitch)) return {};
    final cached = _subsByChannelCache;
    if (cached != null) return cached;
    // Group status-gated emotes (subs, followers, bitstier) by
    // ownerChannel (or ownerId), dedup by id.
    final byOwner = <String, Emote>{};
    final ownerOf = <String, String>{};
    final keys = _channelCatalogs.keys.toList()..sort();
    for (final channel in keys) {
      final raw = _channelCatalogs[channel]?.twitchSubs;
      if (raw == null) continue;
      for (final e in raw) {
        if (!isTwitchLocked(e)) continue;
        final meta = e.meta as TwitchMeta;
        final key = e.id.isNotEmpty
            ? e.id
            : '${e.code}|${meta.ownerChannel ?? channel}';
        if (byOwner.containsKey(key)) continue;
        byOwner[key] = e;
        ownerOf[key] = meta.ownerChannel ?? meta.ownerId ?? channel;
      }
    }
    final grouped = <String, List<Emote>>{};
    for (final entry in byOwner.entries) {
      (grouped[ownerOf[entry.key] ?? ''] ??= []).add(entry.value);
    }
    final owners = grouped.keys.toList()..sort();
    final result = <String, List<Emote>>{};
    for (final owner in owners) {
      result[owner] = grouped[owner]!;
    }
    for (final list in result.values) {
      list.sort((a, b) => a.code.compareTo(b.code));
    }
    return _subsByChannelCache = result;
  }

  static const _maxRecent = 100;
  List<String> _recentIds = [];
  bool _recentLoaded = false;
  Prefs? _prefs;

  // ── Provider visibility toggles ─────────────────────────────────────
  final Set<EmoteType> _disabledProviders = {};
  bool _providersLoaded = false;

  // Whether unlisted 7TV emotes render. Fetch-only; flip rebuilds caches.
  bool _allowUnlisted7tv = false;

  Future<void> _ensureProvidersLoaded() async {
    if (_providersLoaded) return;
    _providersLoaded = true;
    final prefs = await _getPrefs();
    final raw = prefs.emoteProvidersDisabled;
    var migrated = false;
    if (raw != null) {
      for (final t in EmoteType.values) {
        if (raw.contains(t.name)) _disabledProviders.add(t);
      }
      // Migrate: Twitch is no longer toggleable.
      if (_disabledProviders.remove(EmoteType.twitch)) migrated = true;
    }
    _allowUnlisted7tv = prefs.emoteAllowUnlisted7tv;
    if (!migrated) return;
    await prefs.setEmoteProvidersDisabled(
      _disabledProviders.map((t) => t.name).toList(),
    );
  }

  /// Whether [type] is fetched and rendered (sync view).
  bool isProviderEnabled(EmoteType type) {
    if (!_providersLoaded) unawaited(_ensureProvidersLoaded());
    return !_disabledProviders.contains(type);
  }

  /// Current enabled providers, awaiting the persisted load first.
  Future<Set<EmoteType>> enabledProviders() async {
    await _ensureProvidersLoaded();
    return {
      for (final t in EmoteType.values)
        if (!_disabledProviders.contains(t)) t,
    };
  }

  Future<void> setProviderEnabled(EmoteType type, bool enabled) async {
    await _ensureProvidersLoaded();
    final changed = enabled
        ? _disabledProviders.remove(type)
        : _disabledProviders.add(type);
    if (!changed) return;
    final prefs = await _getPrefs();
    await prefs.setEmoteProvidersDisabled(
      _disabledProviders.map((t) => t.name).toList(),
    );
    _rebuildCachesForProviderToggles();
  }

  /// Whether unlisted 7TV emotes render (sync view).
  bool get allowUnlisted7tv {
    if (!_providersLoaded) unawaited(_ensureProvidersLoaded());
    return _allowUnlisted7tv;
  }

  Future<void> setAllowUnlisted7tv(bool allowed) async {
    await _ensureProvidersLoaded();
    if (allowed == _allowUnlisted7tv) return;
    _allowUnlisted7tv = allowed;
    final prefs = await _getPrefs();
    await prefs.setEmoteAllowUnlisted7tv(allowed);
    _rebuildCachesForProviderToggles();
  }

  // Filters disabled providers and unlisted 7TV from an already-merged lookup.
  EmoteLookup? _filterVisible(EmoteLookup? lookup) {
    if (lookup == null) return null;
    final hideUnlisted = !_allowUnlisted7tv;
    if (_disabledProviders.isEmpty && !hideUnlisted) return lookup;
    final visible = lookup.suggestions.where((e) {
      if (_disabledProviders.contains(e.type)) return false;
      final meta = e.meta;
      if (hideUnlisted && meta is SevenTvMeta && meta.unlisted) return false;
      return true;
    }).toList();
    return EmoteLookup(
      byCode: {for (final e in visible) e.code: e},
      suggestions: visible,
    );
  }

  // Catalogs feed the merged lookups lazily, so a toggle only drops the
  // derived caches.
  void _rebuildCachesForProviderToggles() {
    _subsByChannelCache = null;
    _mergedCache.clear();
    _notify();
  }

  bool _hasGlobalStash(EmoteType type) =>
      _globalCatalog.listFor(EmoteScope.global, type).isNotEmpty;

  bool _hasChannelStash(String channel, EmoteType type) =>
      _channelCatalogs[channel]?.listFor(EmoteScope.channel, type).isNotEmpty ??
      false;

  /// Refetches globals + channels for types with no retained stash.
  Future<void> ensureStashed(Set<EmoteType> types) async {
    await _ensureProvidersLoaded();
    if (_registryFrozen || _tier == EmoteFetchTier.nothing || types.isEmpty) {
      return;
    }
    final resolution = _tier.resolution;
    if (resolution == null) return;
    final targets = [
      for (final t in types)
        if (_isProviderOn(t)) t,
    ];
    if (targets.isEmpty) return;
    var fetched = false;
    await _enqueueFetch(() async {
      for (final type in targets.where((t) => !_hasGlobalStash(t))) {
        try {
          final emotes = await _fetchGlobalForProvider(type, resolution);
          if (emotes.isNotEmpty) {
            _commitGlobal(
              _globalEpoch,
              GlobalEmoteFetch(byProvider: {type: emotes}),
            );
            fetched = true;
          }
        } catch (e) {
          logDebug('[EmoteManager] stash refetch failed for ${type.name}: $e');
        }
      }
      for (final channel in _channelCatalogs.keys.toList()) {
        final broadcasterId = _channelBroadcasterIds[channel];
        if (broadcasterId == null) continue;
        final missing = [
          for (final t in targets)
            if (!_hasChannelStash(channel, t)) t,
        ];
        if (missing.isEmpty) continue;
        final byProvider = <EmoteType, List<Emote>>{};
        String? sevenTvSetId;
        String? sevenTvUserId;
        for (final type in missing) {
          try {
            final fetch = await _fetchChannelForProvider(
              type,
              broadcasterId,
              channelName: channel,
              resolution: resolution,
            );
            if (fetch.byProvider.isNotEmpty) {
              byProvider.addAll(fetch.byProvider);
              fetched = true;
            }
            sevenTvSetId ??= fetch.sevenTvSetId;
            sevenTvUserId ??= fetch.sevenTvUserId;
          } catch (e) {
            logDebug(
              '[EmoteManager] stash refetch failed for '
              '${type.name}@$channel: $e',
            );
          }
        }
        _commitChannel(
          channel,
          _channelEpoch[channel] ?? 0,
          ChannelEmoteFetch(
            byProvider: byProvider,
            sevenTvSetId: sevenTvSetId,
            sevenTvUserId: sevenTvUserId,
          ),
        );
      }
    });
    if (fetched) _rebuildCachesForProviderToggles();
  }

  Future<List<Emote>> _fetchGlobalForProvider(
    EmoteType type,
    EmoteResolution resolution,
  ) async {
    switch (type) {
      case EmoteType.twitch:
        return _fetchTwitchGlobal(resolution);
      case EmoteType.bttv:
        return BttvEmoteProvider.fetchGlobal(resolution: resolution);
      case EmoteType.ffz:
        return FfzEmoteProvider.fetchGlobal(resolution: resolution);
      case EmoteType.sevenTv:
        return _sevenTvGlobalFetcher(resolution);
    }
  }

  Future<ChannelEmoteFetch> _fetchChannelForProvider(
    EmoteType type,
    String broadcasterId, {
    String? channelName,
    required EmoteResolution resolution,
  }) async {
    switch (type) {
      case EmoteType.twitch:
        final fetched = await TwitchEmoteProvider.fetchChannel(
          broadcasterId,
          accessToken: _accessToken,
          channelName: channelName,
          resolution: resolution,
        );
        // Subs live in the channel's twitchSubs list, not the provider stash.
        final nonSub = fetched.where((e) => !_isTwitchSub(e)).toList();
        return ChannelEmoteFetch(
          byProvider: nonSub.isEmpty ? const {} : {EmoteType.twitch: nonSub},
        );
      case EmoteType.bttv:
        final emotes = await BttvEmoteProvider.fetchChannel(
          broadcasterId,
          resolution: resolution,
        );
        return ChannelEmoteFetch(
          byProvider: emotes.isEmpty ? const {} : {EmoteType.bttv: emotes},
        );
      case EmoteType.ffz:
        final emotes = await FfzEmoteProvider.fetchChannel(
          broadcasterId,
          resolution: resolution,
        );
        return ChannelEmoteFetch(
          byProvider: emotes.isEmpty ? const {} : {EmoteType.ffz: emotes},
        );
      case EmoteType.sevenTv:
        final resp = await _sevenTvChannelFetcher(broadcasterId, resolution);
        return ChannelEmoteFetch(
          byProvider: resp.emotes.isEmpty
              ? const {}
              : {EmoteType.sevenTv: resp.emotes},
          sevenTvSetId: resp.emoteSetId,
          sevenTvUserId: resp.userId,
        );
    }
  }

  Future<Prefs> _getPrefs() async {
    _prefs ??= await Prefs.load();
    return _prefs!;
  }

  Future<void> _ensureRecentLoaded() async {
    if (_recentLoaded) return;
    _recentLoaded = true;
    final prefs = await _getPrefs();
    final raw = prefs.recentEmotes;
    if (raw == null) return;
    try {
      _recentIds = (jsonDecode(raw) as List<dynamic>).cast<String>();
    } catch (_) {
      logDebug('[EmoteManager] failed to parse recent emotes');
    }
  }

  Future<void> _saveRecent() async {
    final prefs = await _getPrefs();
    await prefs.setRecentEmotes(jsonEncode(_recentIds));
  }

  /// Recently used emote ids (most recent first), used to boost autocomplete
  /// ranking. The persisted list loads lazily, so the first keystroke after
  /// launch may rank without it.
  Set<String> get recentEmoteIds {
    if (!_recentLoaded) unawaited(_ensureRecentLoaded());
    return _recentIds.toSet();
  }

  /// Resolve an emote by ID across all caches.
  Emote? emoteById(String id) => _emoteById(id);

  // Hot-path id index; rebuilt on notify/eviction.
  Map<String, Emote> _emoteByIdIndex = {};
  bool _emoteIndexDirty = true;

  void _rebuildEmoteIndex() {
    final index = <String, Emote>{};
    void addAll(Iterable<Emote> emotes) {
      for (final e in emotes) {
        // putIfAbsent keeps scan-order precedence on id collisions.
        index.putIfAbsent(e.id, () => e);
      }
    }

    addAll(_globalCatalog.globalProviderEmotes());
    for (final catalog in _channelCatalogs.values) {
      addAll(catalog.twitchSubs);
      addAll(catalog.channelProviderEmotes());
    }
    for (final setEmotes in _personalSevenTvSets.values) {
      addAll(setEmotes);
    }
    _emoteByIdIndex = index;
    _emoteIndexDirty = false;
  }

  /// Resolve an emote by ID across all caches.
  Emote? _emoteById(String id) {
    if (_emoteIndexDirty) _rebuildEmoteIndex();
    return _emoteByIdIndex[id];
  }

  Future<void> markEmoteUsed(Emote emote) async {
    await _ensureRecentLoaded();
    _recentIds.remove(emote.id);
    _recentIds.insert(0, emote.id);
    if (_recentIds.length > _maxRecent) {
      _recentIds = _recentIds.sublist(0, _maxRecent);
    }
    await _saveRecent();
    _touchUsage(emote.url);
    await _flushUsage();
  }

  /// Records emote display for cache eviction scoring.
  void markEmoteViewed(Emote emote) {
    if (_tier == EmoteFetchTier.nothing) return;
    _touchUsage(emote.url);
    _scheduleUsageFlush();
  }

  Future<List<Emote>> recentEmotes() async {
    await _ensureRecentLoaded();
    final result = <Emote>[];
    for (final id in _recentIds) {
      final emote = _emoteById(id);
      if (emote != null) result.add(emote);
    }
    return result;
  }

  /// Resolves recents to channel-local codes via [suggestions].
  List<Emote> resolveRecentsForChannel(
    List<Emote> recents,
    List<Emote> suggestions,
  ) {
    final byId = <String, Emote>{};
    for (final e in suggestions) {
      byId.putIfAbsent(e.id, () => e);
    }
    final result = <Emote>[];
    for (final recent in recents) {
      final resolved = byId[recent.id];
      if (resolved != null) result.add(resolved);
    }
    return result;
  }

  /// Loads global emotes. [force] skips cache, fetches from network.
  Future<void> preloadGlobalEmotes({bool force = false}) async {
    final epoch = force ? (_globalEpoch = _globalEpoch + 1) : _globalEpoch;
    await _ensureProvidersLoaded();
    if (_globalResolved && !force) return;
    final ttl = await _effectiveTtl();
    if (!force) {
      final loaded = await _loadPersistedCache('emotes4_global', ttl);
      final cached = loaded.catalog;
      if (cached != null) {
        if (_globalEpoch != epoch) return;
        _globalCatalog = cached;
        _globalResolved = true;
        _notify();
        if (loaded.fresh ||
            _registryFrozen ||
            _tier == EmoteFetchTier.nothing) {
          // Fresh cache: render, then background-refresh Twitch globals.
          if (!_skipTwitchBackgroundRefresh) {
            unawaited(
              _enqueueFetch(_refreshTwitchGlobalEmotes).then((fetch) {
                if (fetch != null) _commitGlobal(epoch, fetch);
              }),
            );
          }
          return;
        }
      }
      // Stale: keep stale data, revalidate below.
    }
    // Fetch every enabled provider.
    if (_tier == EmoteFetchTier.nothing) return;
    final loaded = await _loadPersistedCache('emotes4_global', ttl);
    if (loaded.catalog != null) {
      if (_globalEpoch != epoch) return;
      // Seed provider lists a wiped stash would otherwise lose to a flaky
      // fetch (429/5xx/timeout), without clobbering in-memory data.
      _globalCatalog = _globalCatalog.fillMissing(loaded.catalog!);
      _globalResolved = true;
    }
    final fetch = await _enqueueFetch(_fetchAllGlobal);
    if (_commitGlobal(epoch, fetch)) {
      await _savePersistedCache('emotes4_global', _globalCatalog, ttl);
    }
    _notify();
  }

  /// Defaults plus the global unlockable catalogue (broadcaster_id=0).
  /// The /global endpoint returns defaults only, so the picker and
  /// autocomplete miss Prime/Turbo/2FA/Hype Train emotes without this.
  /// Both fetches run in parallel with isolated errors: a defaults failure
  /// no longer aborts the unlockable fetch. A defaults throw still surfaces
  /// when nothing usable arrived, so fetch-failure reporting keeps working.
  Future<List<Emote>> _fetchTwitchGlobal(EmoteResolution resolution) async {
    List<Emote> defaults = const [];
    Object? defaultsError;
    List<Emote> unlockable = const [];
    Future<List<Emote>> getDefaults() async {
      try {
        return await TwitchEmoteProvider.fetchGlobal(
          accessToken: _accessToken,
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
          accessToken: _accessToken,
          resolution: resolution,
        );
      } catch (e) {
        logDebug('[EmoteManager] global unlockable emotes failed: $e');
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
    if (unlockable.isNotEmpty) {
      _twitchCatalogUnlockIds
        ..clear()
        ..addAll(unlockable.where((e) => e.id.isNotEmpty).map((e) => e.id));
    }
    if (unlockable.isEmpty) return defaults;
    // Unlockable catalogue wins on code collision (limited-time rotations
    // reuse names with new ids); dedup by id too.
    final overrideIds = {
      for (final e in unlockable)
        if (e.id.isNotEmpty) e.id,
    };
    final overrideCodes = {for (final e in unlockable) e.code};
    final merged = <Emote>[
      for (final e in defaults)
        if (!(e.id.isNotEmpty
            ? overrideIds.contains(e.id) || overrideCodes.contains(e.code)
            : overrideCodes.contains(e.code)))
          e,
      ...unlockable,
    ];
    final seen = <String>{};
    return [
      for (final e in merged)
        if (e.id.isEmpty || seen.add(e.id)) e,
    ];
  }

  /// Base globals with per-account unlocks applied last so they win on id or
  /// code collision. Third-party emotes keep provider-precedence resolution.
  List<Emote> _withUnlocked(List<Emote> base) =>
      applyAccountUnlocks(base, _unlockedTwitchEmotes.values);

  /// Stores owner-less emote-set results (per-account unlocks) so they render
  /// in chat, autocomplete, and the picker. Upserts by code: a same-code new
  /// id replaces the old unlock, so limited-time rotations never stick stale.
  void _storeUnlockedGlobalEmotes(List<Emote> emotes) {
    if (emotes.isEmpty) return;
    final incomingCodes = {for (final e in emotes) e.code};
    final incomingIds = {
      for (final e in emotes)
        if (e.id.isNotEmpty) e.id,
    };
    _unlockedTwitchEmotes.removeWhere(
      (key, old) =>
          incomingIds.contains(key) ||
          incomingIds.contains(old.id) ||
          incomingCodes.contains(old.code),
    );
    for (final e in emotes) {
      _unlockedTwitchEmotes[e.id.isNotEmpty ? e.id : e.code] = e;
    }
    _globalResolved = true;
    _notify();
  }

  Future<void> storeUserTwitchEmotes(
    Map<String, List<Emote>> perChannel,
  ) async {
    if (_tier == EmoteFetchTier.nothing) return;
    for (final entry in perChannel.entries) {
      final channel = entry.key;
      final emotes = entry.value;
      if (emotes.isEmpty) continue;
      final catalog = _channelCatalogs[channel] ?? EmoteCatalog();
      final existing = catalog.twitchSubs;
      // Fresh first, then non-sub existing; dedup by id.
      final merged = <Emote>[];
      final seen = <String>{};
      for (final e in emotes) {
        if (e.id.isEmpty || seen.add(e.id)) merged.add(e);
      }
      for (final e in existing) {
        if (!_isTwitchSub(e) && (e.id.isEmpty || seen.add(e.id))) {
          merged.add(e);
        }
      }
      _channelCatalogs[channel] = catalog.copyWith(twitchSubs: merged);
      _subsByChannelCache = null;
    }
    _notify();
  }

  Map<String, String> _openChannels(Map<String, String> fallback) =>
      getChannelUserIds?.call() ?? fallback;

  /// Loads subscriber emotes: fetch, resolve owners, fan into channels.
  Future<void> loadUserEmoteSets(
    List<String> emoteSetIds,
    TwitchAuth auth,
    Map<String, String> openChannelUserIds,
  ) async {
    if (_tier == EmoteFetchTier.nothing) return;
    // Skip "0" (Twitch global, already loaded).
    final newSetIds = emoteSetIds
        .where(
          (id) =>
              id != '0' &&
              !_fetchedEmoteSetIds.contains(id) &&
              !_inflightEmoteSetIds.contains(id),
        )
        .toList();
    if (newSetIds.isEmpty) {
      // No new sets, but heal owner labels and attach to late channels.
      final channels = _openChannels(openChannelUserIds);
      await _resolveOwners(auth, channels);
      await _reStoreCachedSubs(channels);
      return;
    }
    _inflightEmoteSetIds.addAll(newSetIds);
    // Subs tab spins (not empty-text) while the fetch below is in flight.
    _notify();
    try {
      final byOwner = await _fetchUserEmoteSets(
        newSetIds,
        accessToken: auth.accessToken,
        resolution: _tier.resolution!,
      );
      final perOwner = <String, List<Emote>>{};
      final unlocked = <Emote>[];
      for (final entry in byOwner.entries) {
        if (entry.key.isEmpty) {
          // Owner-less sets are global unlocks, not channel subs.
          unlocked.addAll(entry.value);
        } else {
          perOwner[entry.key] = entry.value;
          _fetchedSubEmotesByOwner[entry.key] = entry.value;
        }
      }
      if (unlocked.isNotEmpty) _storeUnlockedGlobalEmotes(unlocked);
      _fetchedEmoteSetIds.addAll(newSetIds);
      if (perOwner.isEmpty) {
        logDebug(
          'loadUserEmoteSets: ${newSetIds.length} sets fetched, no channel emotes',
        );
        return;
      }
      final channels = _openChannels(openChannelUserIds);
      await _resolveOwners(auth, channels, ownerIds: perOwner.keys);
      final targets = channels.keys.toList();
      if (targets.isEmpty) {
        logDebug('loadUserEmoteSets: no channel targets');
        return;
      }
      final perChannel = _buildPerChannelEmotes(perOwner, targets);
      await storeUserTwitchEmotes(perChannel);
    } catch (e) {
      logDebug('loadUserEmoteSets failed: $e');
    } finally {
      // Keep fetched ids; failed ones retry on next USERSTATE.
      _inflightEmoteSetIds.removeAll(
        newSetIds.where((id) => !_fetchedEmoteSetIds.contains(id)),
      );
    }
  }

  /// Resolves owner ids to logins (open channels skip API).
  Future<void> _resolveOwners(
    TwitchAuth auth,
    Map<String, String> openChannelUserIds, {
    Iterable<String>? ownerIds,
  }) async {
    // Seed open-channel owners.
    for (final entry in openChannelUserIds.entries) {
      _emoteOwnerLogins[entry.value] = entry.key;
    }
    final owners = (ownerIds ?? _fetchedSubEmotesByOwner.keys)
        .where((id) => !_emoteOwnerLogins.containsKey(id))
        .toSet()
        .toList();
    if (owners.isEmpty) return;
    try {
      final resolved = await _resolveOwnerLogins(auth, owners);
      _emoteOwnerLogins.addAll(resolved);
    } catch (e) {
      logDebug('_resolveOwners failed: $e');
    }
  }

  /// Re-stores cached subs with resolved ownerChannel (reconnect heal).
  Future<void> _reStoreCachedSubs(
    Map<String, String> openChannelUserIds,
  ) async {
    if (_fetchedSubEmotesByOwner.isEmpty) return;
    final targets = openChannelUserIds.keys.toList();
    if (targets.isEmpty) return;
    await storeUserTwitchEmotes(
      _buildPerChannelEmotes(_fetchedSubEmotesByOwner, targets),
    );
  }

  /// Clears per-account emote state (account switch).
  void resetUserEmoteState() {
    _fetchedEmoteSetIds.clear();
    _inflightEmoteSetIds.clear();
    _emoteOwnerLogins.clear();
    _fetchedSubEmotesByOwner.clear();
    _emotesResolvedChannels.clear();
    _subsByChannelCache = null;
    // Unlocks are per-account: drop them from the global Twitch list they
    // merged into. Matches by id, plus by code for empty-id entries, so a
    // same-code default underneath is not removed with them.
    final removedIds = <String>{..._unlockedTwitchEmotes.keys};
    final removedCodes = <String>{
      for (final e in _unlockedTwitchEmotes.values) e.code,
    };
    final removedCatalogIds = <String>{..._twitchCatalogUnlockIds};
    _unlockedTwitchEmotes.clear();
    bool prunesUnlock(Emote e) => e.id.isNotEmpty
        ? removedIds.contains(e.id) || removedCatalogIds.contains(e.id)
        : removedCodes.contains(e.code);
    if (removedIds.isNotEmpty || removedCatalogIds.isNotEmpty) {
      _globalCatalog = _globalCatalog.withList(
        EmoteScope.global,
        EmoteType.twitch,
        _globalCatalog.twitchGlobal.where((e) => !prunesUnlock(e)).toList(),
      );
    }
    _twitchCatalogUnlockIds.clear();
    _personalSevenTvSetIds.clear();
    _personalSevenTvSets.clear();
    _foreignPersonalSetOwners.clear();
    _foreignPersonalUserSets.clear();
    _foreignPersonalSetContents.clear();
    _foreignPersonalSets.clear();
    // Drop channel catalogs so the UI stops showing the old user's sub emotes
    // immediately; _refreshEmotesAfterAuth will rebuild them from the
    // (sub-filtered) persisted cache.
    _channelCatalogs.clear();
    _mergedCache.clear();
    _notify();
  }

  /// Re-fetches subscriber emotes for the ids already known from a prior
  /// USERSTATE/GLOBALUSERSTATE. The manual emote reload would otherwise drop
  /// subs until the next IRC USERSTATE arrives, so call this from that path.
  Future<void> reloadUserEmoteSets(
    TwitchAuth auth,
    Map<String, String> openChannelUserIds,
  ) async {
    if (_tier == EmoteFetchTier.nothing) return;
    if (_fetchedEmoteSetIds.isEmpty) return;
    final ids = _fetchedEmoteSetIds.toList();
    _fetchedEmoteSetIds.clear();
    await loadUserEmoteSets(ids, auth, openChannelUserIds);
  }

  /// Builds per-channel subs map with owner stamps.
  Map<String, List<Emote>> _buildPerChannelEmotes(
    Map<String, List<Emote>> perOwner,
    List<String> targets,
  ) {
    final perChannel = <String, List<Emote>>{};
    for (final target in targets) {
      final list = <Emote>[];
      for (final entry in perOwner.entries) {
        final ownerLogin = _emoteOwnerLogins[entry.key];
        for (final e in entry.value) {
          final meta = e.meta is TwitchMeta
              ? e.meta as TwitchMeta
              : const TwitchMeta(kind: TwitchEmoteKind.standard);
          // Follower emotes only work in their home channel; subs, bits, and
          // unlocks are usable everywhere.
          if (meta.kind == TwitchEmoteKind.follower &&
              ownerLogin?.toLowerCase() != target.toLowerCase()) {
            continue;
          }
          list.add(
            Emote(
              id: e.id,
              code: e.code,
              meta: TwitchMeta(
                kind: meta.kind,
                subTier: meta.subTier,
                ownerChannel: ownerLogin,
                ownerId: entry.key,
              ),
              url: e.url,
              url1x: e.url1x,
              url3x: e.url3x,
              isAnimated: e.isAnimated,
              scope: e.scope,
            ),
          );
        }
      }
      perChannel[target] = list;
    }
    return perChannel;
  }

  static TwitchEmoteKind? _kindOf(Emote e) =>
      e.meta is TwitchMeta ? (e.meta as TwitchMeta).kind : null;

  /// Loads channel emotes. [force] skips cache, fetches from network.
  Future<void> resolveEmotes(
    String channel,
    String? broadcasterId, {
    bool force = false,
  }) async {
    final epoch = force
        ? (_channelEpoch[channel] = (_channelEpoch[channel] ?? 0) + 1)
        : _channelEpoch[channel] ?? 0;
    await _ensureProvidersLoaded();
    if (broadcasterId != null) _channelBroadcasterIds[channel] = broadcasterId;
    final ttl = await _effectiveTtl();
    if (force) {
      // Nothing tier: render cached only.
      if (_tier == EmoteFetchTier.nothing) return;
      final loaded = await _loadPersistedCache('emotes4_$channel', ttl);
      if ((_channelEpoch[channel] ?? 0) != epoch) return;
      if (loaded.catalog != null) {
        _channelCatalogs[channel] =
            (_channelCatalogs[channel] ?? EmoteCatalog()).fillMissing(
              loaded.catalog!,
            );
      }
      final fetch = await _enqueueFetch(
        () => _fetchAllChannel(broadcasterId, channelName: channel),
      );
      if (_commitChannel(channel, epoch, fetch)) {
        await _savePersistedCache(
          'emotes4_$channel',
          _channelCatalogs[channel]!,
          ttl,
        );
      }
      return;
    }
    final loaded = await _loadPersistedCache(
      'emotes4_$channel',
      ttl,
      fetchTime: _channelFetchTimes[channel],
    );
    final cached = loaded.catalog;
    if (cached != null) {
      if ((_channelEpoch[channel] ?? 0) != epoch) return;
      // Stored subs are owned by storeUserTwitchEmotes (USERSTATE) and must
      // not leak across account switches through the disk cache.
      final existingSubs =
          _channelCatalogs[channel]?.twitchSubs ?? const <Emote>[];
      _channelCatalogs[channel] = cached.copyWith(twitchSubs: existingSubs);
      _reapplyLiveSevenTv(channel);
      _notify(channel: channel);
      if (loaded.fresh || _registryFrozen || _tier == EmoteFetchTier.nothing) {
        // Fresh: render, background-refresh Twitch channel emotes.
        if (!_skipTwitchBackgroundRefresh) {
          unawaited(
            _enqueueFetch(
              () => _refreshTwitchChannelEmotes(channel, broadcasterId),
            ).then((fetch) {
              if (fetch != null) _commitChannel(channel, epoch, fetch);
            }),
          );
        }
        // Reconcile 7TV deltas at startup: the fetched set is authoritative,
        // so stale live deltas are dropped rather than re-applied over it.
        if (broadcasterId != null &&
            _tier.index >= EmoteFetchTier.medium.index) {
          unawaited(
            _enqueueFetch(() => _reconcileSevenTv(channel, broadcasterId)).then(
              (fetch) {
                if (fetch == null) return;
                if (fetch.byProvider[EmoteType.sevenTv] != null) {
                  _sevenTvLive.remove(channel);
                }
                _commitChannel(channel, epoch, fetch);
              },
            ),
          );
        }
        return;
      }
      // Stale: keep stale data, revalidate below.
    }
    // Nothing tier: render cached only.
    if (_tier == EmoteFetchTier.nothing) return;
    final fetch = await _enqueueFetch(
      () => _fetchAllChannel(broadcasterId, channelName: channel),
    );
    if (_commitChannel(channel, epoch, fetch)) {
      await _savePersistedCache(
        'emotes4_$channel',
        _channelCatalogs[channel]!,
        ttl,
      );
    }
  }

  /// Applies one global fetch at [epoch]. A stale epoch is dropped so an
  /// in-flight fetch that lands after an evict or forced reload cannot
  /// overwrite newer state. Failed providers feed [takeFetchFailures].
  bool _commitGlobal(int epoch, GlobalEmoteFetch fetch) {
    if (epoch != _globalEpoch) return false;
    for (final _ in fetch.failed) {
      _fetchFailures.add('global emotes');
    }
    if (fetch.byProvider.isEmpty) {
      // Nothing new: a retained catalog still counts as applied so a
      // revalidation can refresh the persisted tier tag.
      return _globalResolved;
    }
    var catalog = _globalCatalog;
    for (final entry in fetch.byProvider.entries) {
      catalog = catalog.withList(EmoteScope.global, entry.key, entry.value);
    }
    _globalCatalog = catalog;
    _notify();
    return true;
  }

  /// Applies one channel fetch at [epoch]. A stale epoch is dropped so an
  /// in-flight fetch that lands after an evict or forced resolve cannot
  /// resurrect the channel. Missing providers keep their retained list; the
  /// stored subs and 7TV identity are preserved.
  bool _commitChannel(String channel, int epoch, ChannelEmoteFetch fetch) {
    if (epoch != (_channelEpoch[channel] ?? 0)) return false;
    for (final _ in fetch.failed) {
      _fetchFailures.add(channel);
    }
    final hasData =
        fetch.byProvider.isNotEmpty ||
        fetch.sevenTvSetId != null ||
        fetch.sevenTvUserId != null ||
        _channelCatalogs.containsKey(channel);
    if (!hasData) return false;

    if (fetch.sevenTvSetId != null) {
      _sevenTvEmoteSetIds[channel] = fetch.sevenTvSetId!;
    }
    if (fetch.sevenTvUserId != null) {
      _sevenTvUserIds[channel] = fetch.sevenTvUserId!;
    }
    var catalog = _channelCatalogs[channel] ?? EmoteCatalog();
    for (final entry in fetch.byProvider.entries) {
      catalog = catalog.withList(EmoteScope.channel, entry.key, entry.value);
    }
    // Subs stay owned by storeUserTwitchEmotes; only non-sub Twitch entries
    // are re-merged here. Followers count as subs (see _buildPerChannelEmotes).
    final twitchNonSub = fetch.byProvider[EmoteType.twitch];
    if (twitchNonSub != null) {
      final subs = catalog.twitchSubs
          .where(
            (e) => _isTwitchSub(e) || _kindOf(e) == TwitchEmoteKind.follower,
          )
          .toList();
      catalog = catalog.copyWith(twitchSubs: [...subs, ...twitchNonSub]);
      _subsByChannelCache = null;
    }
    _channelCatalogs[channel] = catalog;
    _reapplyLiveSevenTv(channel);
    _channelFetchTimes[channel] = DateTime.now();
    _notify(channel: channel);
    return true;
  }

  // Re-applies live 7TV delta after fetch rebuild.
  void _reapplyLiveSevenTv(String channel) {
    final live = _sevenTvLive[channel];
    if (live == null) return;
    final catalog = _channelCatalogs[channel];
    if (catalog == null) return;
    _channelCatalogs[channel] = catalog.copyWith(sevenTvChannel: live);
  }

  /// Produces a Twitch-only channel refresh. Null on skip or failure, so a
  /// background refresh never counts as a reload failure.
  Future<ChannelEmoteFetch?> _refreshTwitchChannelEmotes(
    String channel,
    String? broadcasterId,
  ) async {
    if (broadcasterId == null) return null;
    await _ensureProvidersLoaded();
    if (!_isProviderOn(EmoteType.twitch)) return null;
    try {
      final emotes = await TwitchEmoteProvider.fetchChannel(
        broadcasterId,
        accessToken: _accessToken,
        channelName: channel,
        resolution: _tier.resolution!,
      );
      if (emotes.isEmpty) return null;
      final nonSub = emotes.where((e) => !_isTwitchSub(e)).toList();
      if (nonSub.isEmpty) return null;
      return ChannelEmoteFetch(byProvider: {EmoteType.twitch: nonSub});
    } catch (e) {
      logDebug('[EmoteManager] twitch refresh failed for $channel: $e');
      return null;
    }
  }

  /// Produces a Twitch-only global refresh. Null on skip or failure.
  Future<GlobalEmoteFetch?> _refreshTwitchGlobalEmotes() async {
    await _ensureProvidersLoaded();
    if (!_isProviderOn(EmoteType.twitch)) return null;
    try {
      final emotes = await _fetchTwitchGlobal(_tier.resolution!);
      if (emotes.isEmpty) return null;
      return GlobalEmoteFetch(byProvider: {EmoteType.twitch: emotes});
    } catch (e) {
      logDebug('[EmoteManager] twitch global refresh failed: $e');
      return null;
    }
  }

  /// Reconciles the channel's 7TV set against the server. Used when a live
  /// `user.update` switches the active set: without it the old set keeps
  /// rendering and the next full fetch resurrects it via the live list.
  Future<void> reconcileSevenTvChannel(String channel) {
    final broadcasterId = _channelBroadcasterIds[channel];
    if (broadcasterId == null) return Future.value();
    final epoch = _channelEpoch[channel] ?? 0;
    return _enqueueFetch(() => _reconcileSevenTv(channel, broadcasterId)).then((
      fetch,
    ) {
      if (fetch == null) return;
      // A fetched 7TV set is authoritative: drop stale live deltas. An empty
      // fetch keeps them, matching the old reconcile early return.
      if (fetch.byProvider[EmoteType.sevenTv] != null) {
        _sevenTvLive.remove(channel);
      }
      _commitChannel(channel, epoch, fetch);
    });
  }

  // Produces the channel's current 7TV set for reconcile (medium/high).
  Future<ChannelEmoteFetch?> _reconcileSevenTv(
    String channel,
    String broadcasterId,
  ) async {
    if (_tier.index < EmoteFetchTier.medium.index) return null;
    await _ensureProvidersLoaded();
    if (!_isProviderOn(EmoteType.sevenTv)) return null;
    try {
      final resp = await _sevenTvChannelFetcher(
        broadcasterId,
        _tier.resolution!,
      );
      return ChannelEmoteFetch(
        byProvider: resp.emotes.isEmpty
            ? const {}
            : {EmoteType.sevenTv: resp.emotes},
        sevenTvSetId: resp.emoteSetId,
        sevenTvUserId: resp.userId,
      );
    } catch (e) {
      logDebug('[EmoteManager] 7TV reconcile failed for $channel: $e');
      return null;
    }
  }

  void evictChannel(String channel) {
    // Keep the epoch entry so an in-flight fetch cannot match after eviction.
    _channelEpoch[channel] = (_channelEpoch[channel] ?? 0) + 1;
    _channelCatalogs.remove(channel);
    _channelFetchTimes.remove(channel);
    _emotesResolvedChannels.remove(channel);
    _subsByChannelCache = null;
    _sevenTvEmoteSetIds.remove(channel);
    _sevenTvUserIds.remove(channel);
    _channelBroadcasterIds.remove(channel);
    _mergedCache.remove(channel);
    _sevenTvLive.remove(channel);
    _emoteIndexDirty = true;
  }

  void evictGlobal() {
    _globalEpoch++;
    _globalCatalog = EmoteCatalog();
    _globalResolved = false;
    _unlockedTwitchEmotes.clear();
    _twitchCatalogUnlockIds.clear();
    _mergedCache.clear();
    _emoteIndexDirty = true;
  }

  void markEmotesResolved(String channel) {
    _emotesResolvedChannels.add(channel);
  }

  bool emotesResolved(String channel) =>
      _emotesResolvedChannels.contains(channel);

  /// Bumps the version and notifies listeners with the current (possibly
  /// empty) state, so cached message spans are discarded immediately.
  void notifyStateCleared() {
    _notify();
  }

  void setSevenTvEmoteSetId(String channel, String emoteSetId) {
    _sevenTvEmoteSetIds[channel] = emoteSetId;
  }

  String? getSevenTvEmoteSetId(String channel) => _sevenTvEmoteSetIds[channel];

  String? getSevenTvUserId(String channel) => _sevenTvUserIds[channel];

  String? getChannelForSevenTvEmoteSet(String emoteSetId) {
    for (final entry in _sevenTvEmoteSetIds.entries) {
      if (entry.value == emoteSetId) return entry.key;
    }
    return null;
  }

  // Applies 7TV WS deltas in place; evicts unused from disk cache.
  void updateSevenTvEmotes(
    String channel, {
    List<Emote> added = const [],
    List<String> removedIds = const [],
    Map<String, ({String newName, String oldName})> renamed = const {},
  }) {
    if (_tier == EmoteFetchTier.nothing) return;
    if (!_isProviderOn(EmoteType.sevenTv)) return;
    final catalog = _channelCatalogs[channel];
    if (catalog == null && added.isEmpty) return;

    final changedCodes = <String>{};
    final removedIdsWithUrls = <(String, List<String>)>[];

    if (catalog == null) {
      // No cache to diff against (not yet resolved, or evicted by a nuke).
      // Build a partial view so the delta's emotes render, but do NOT sync
      // it into the live view: one delta isn't the full set, and
      // _reapplyLiveSevenTv would propagate it over the next full fetch.
      final sorted = List.of(added)..sort((a, b) => a.code.compareTo(b.code));
      _channelCatalogs[channel] = EmoteCatalog(sevenTvChannel: sorted);
      _emoteIndexDirty = true;
      _lastChangedCodes[channel] = {for (final e in added) e.code};
      _notify(channel: channel, bumpVersion: false);
      return;
    }

    // Diff against the channel-only merged view, then write the winning 7TV
    // entries back as the live list.
    final byCode = Map<String, Emote>.of(_channelLookup(channel).byCode);

    for (final id in removedIds) {
      final removed = byCode.values
          .where((e) => e.id == id && e.type == EmoteType.sevenTv)
          .toList();
      for (final e in removed) {
        byCode.remove(e.code);
        changedCodes.add(e.code);
        removedIdsWithUrls.add((
          e.id,
          [e.url, if (e.url1x != null) e.url1x!, if (e.url3x != null) e.url3x!],
        ));
      }
    }

    for (final entry in renamed.entries) {
      final e = byCode.values
          .where((x) => x.id == entry.key && x.type == EmoteType.sevenTv)
          .firstOrNull;
      if (e == null) continue;
      byCode.remove(e.code);
      final renamedEmote = e.copyWith(code: entry.value.newName);
      byCode[renamedEmote.code] = renamedEmote;
      changedCodes
        ..add(e.code)
        ..add(renamedEmote.code);
    }

    for (final emote in added) {
      final existing = byCode[emote.code];
      if (existing != null &&
          !(existing.scope.index <= emote.scope.index &&
              kEmoteProviderPriority[emote.type]! <
                  kEmoteProviderPriority[existing.type]!)) {
        continue;
      }
      byCode[emote.code] = emote;
      changedCodes.add(emote.code);
    }

    final live =
        byCode.values.where((e) => e.type == EmoteType.sevenTv).toList()
          ..sort((a, b) => a.code.compareTo(b.code));
    _channelCatalogs[channel] = catalog.copyWith(sevenTvChannel: live);
    _sevenTvLive[channel] = live;

    _lastChangedCodes[channel] = changedCodes;
    // Live deltas don't bump span version (no retroactive re-render).
    _notify(channel: channel, bumpVersion: false);

    // Evict shared 7TV emotes from disk when gone from all channels.
    final unused = removedIdsWithUrls.where(
      (entry) => !_isEmoteUsedElsewhere(entry.$1),
    );
    if (unused.isNotEmpty) {
      unawaited(_evictEmoteImages([for (final entry in unused) ...entry.$2]));
    }
  }

  // Channel-only merged view, matching the old per-channel cache (no global,
  // no personal, unlisted included).
  EmoteLookup _channelLookup(String channel) => mergeEmoteLookup(
    global: EmoteCatalog(),
    channel: _channelCatalogs[channel],
    disabledProviders: _disabledProviders,
    allowUnlisted7tv: true,
  );

  bool _isEmoteUsedElsewhere(String id) {
    for (final catalog in _channelCatalogs.values) {
      if (catalog.twitchSubs.any((e) => e.id == id)) return true;
      if (catalog.channelProviderEmotes().any((e) => e.id == id)) return true;
    }
    return _globalCatalog.globalProviderEmotes().any((e) => e.id == id);
  }

  Future<void> _evictEmoteImages(List<String> urls) async {
    await _ensureUsageLoaded();
    var removed = false;
    for (final url in urls) {
      if (url.isEmpty) continue;
      _emoteUsage.remove(url);
      removed = true;
      try {
        await _removeCachedFile(url);
      } catch (_) {
        logDebug('[EmoteManager] failed to evict unused emote $url');
      }
    }
    if (removed) {
      _usageDirty = true;
      await _flushUsage();
    }
  }

  /// Low/nothing tiers: no Twitch background refresh (infinite TTL).
  bool get _skipTwitchBackgroundRefresh =>
      _tier == EmoteFetchTier.low || _tier == EmoteFetchTier.nothing;

  /// Low tier: frozen registries (seed fetch only, force bypasses).
  bool get _registryFrozen => _tier == EmoteFetchTier.low;

  /// TTL varies by connectivity (longer on cellular).
  Future<Duration> _effectiveTtl() async {
    switch (_tier) {
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

  /// Cached connectivity probe (avoids per-fetch platform calls).
  Future<ConnectivityResult> _probeConnectivity() async {
    final probe = _connectivityProbe;
    if (probe == null) return ConnectivityResult.wifi;
    final now = DateTime.now();
    final probedAt = _probeAt;
    if (probedAt != null && now.difference(probedAt) < _connectivityProbeTtl) {
      return _probeResult;
    }
    try {
      final results = await probe();
      _probeResult = results.contains(ConnectivityResult.mobile)
          ? ConnectivityResult.mobile
          : ConnectivityResult.wifi;
    } catch (_) {
      _probeResult = ConnectivityResult.wifi;
    }
    _probeAt = DateTime.now();
    return _probeResult;
  }

  /// Enqueues fetch with concurrency gate and stagger. The stagger wait runs
  /// before acquiring a permit so sleeping fetches never hold gate slots.
  Future<T> _enqueueFetch<T>(Future<T> Function() action) {
    final enqueuedAt = DateTime.now();
    Future<void> stagger() async {
      final elapsed = DateTime.now().difference(enqueuedAt);
      if (elapsed < _fetchStagger) {
        await Future.delayed(_fetchStagger - elapsed);
      }
    }

    return stagger().then((_) => _fetchGate.withPermit(action));
  }

  @visibleForTesting
  Future<Duration> effectiveTtlForTesting() => _effectiveTtl();

  @visibleForTesting
  int get precacheQueueLengthForTesting => _precacheQueue.length;

  @visibleForTesting
  Future<void> enqueueFetchForTesting(Future<void> Function() action) =>
      _enqueueFetch(action);

  @visibleForTesting
  Future<void> flushUsageForTesting() => _flushUsage();

  @visibleForTesting
  int stashSizeForTesting({String? channel, required EmoteType type}) {
    if (channel == null) {
      return _globalCatalog.listFor(EmoteScope.global, type).length;
    }
    return _channelCatalogs[channel]
            ?.listFor(EmoteScope.channel, type)
            .length ??
        0;
  }

  @visibleForTesting
  int foreignPersonalSetCountForTesting() => _foreignPersonalSetContents.length;

  @visibleForTesting
  Future<GlobalEmoteFetch> fetchAllGlobalForTesting() => _fetchAllGlobal();

  @visibleForTesting
  Future<ChannelEmoteFetch> fetchAllChannelForTesting(
    String? broadcasterId, {
    String? channelName,
  }) => _fetchAllChannel(broadcasterId, channelName: channelName);

  /// Sync gate for fetch lambdas; callers must have awaited
  /// [_ensureProvidersLoaded] first.
  bool _isProviderOn(EmoteType type) => !_disabledProviders.contains(type);

  Future<GlobalEmoteFetch> _fetchAllGlobal() async {
    await _ensureProvidersLoaded();
    final results = <EmoteType, List<Emote>>{};
    final providers = <EmoteType, Future<List<Emote>> Function()>{
      EmoteType.twitch: () async {
        if (!_isProviderOn(EmoteType.twitch)) return [];
        final emotes = await _fetchTwitchGlobal(_tier.resolution!);
        // Empty fetch: keep the retained catalog list.
        if (emotes.isNotEmpty) results[EmoteType.twitch] = emotes;
        return emotes;
      },
      EmoteType.bttv: () async {
        if (!_isProviderOn(EmoteType.bttv)) return [];
        final emotes = await BttvEmoteProvider.fetchGlobal(
          resolution: _tier.resolution!,
        );
        if (emotes.isNotEmpty) results[EmoteType.bttv] = emotes;
        return emotes;
      },
      EmoteType.ffz: () async {
        if (!_isProviderOn(EmoteType.ffz)) return [];
        final emotes = await FfzEmoteProvider.fetchGlobal(
          resolution: _tier.resolution!,
        );
        if (emotes.isNotEmpty) results[EmoteType.ffz] = emotes;
        return emotes;
      },
      EmoteType.sevenTv: () async {
        if (!_isProviderOn(EmoteType.sevenTv)) return [];
        final emotes = await _sevenTvGlobalFetcher(_tier.resolution!);
        if (emotes.isNotEmpty) results[EmoteType.sevenTv] = emotes;
        return emotes;
      },
    };
    final failed = await _fetchConcurrent(providers, maxConcurrent: 2);
    return GlobalEmoteFetch(byProvider: results, failed: failed);
  }

  Future<ChannelEmoteFetch> _fetchAllChannel(
    String? broadcasterId, {
    String? channelName,
  }) async {
    await _ensureProvidersLoaded();
    if (broadcasterId == null) {
      // No broadcaster id: nothing to fetch; the commit keeps retained lists.
      return const ChannelEmoteFetch();
    }
    final results = <EmoteType, List<Emote>>{};
    String? sevenTvSetId;
    String? sevenTvUserId;
    final providers = <EmoteType, Future<List<Emote>> Function()>{
      EmoteType.twitch: () async {
        if (!_isProviderOn(EmoteType.twitch)) return [];
        final fetched = await TwitchEmoteProvider.fetchChannel(
          broadcasterId,
          accessToken: _accessToken,
          channelName: channelName,
          resolution: _tier.resolution!,
        );
        final nonSub = fetched.where((e) => !_isTwitchSub(e)).toList();
        // Empty fetch: keep the retained catalog entry so a silent non-200
        // cannot clobber it.
        if (nonSub.isNotEmpty) results[EmoteType.twitch] = nonSub;
        return nonSub;
      },
      EmoteType.bttv: () async {
        if (!_isProviderOn(EmoteType.bttv)) return [];
        final emotes = await BttvEmoteProvider.fetchChannel(
          broadcasterId,
          resolution: _tier.resolution!,
        );
        if (emotes.isNotEmpty) results[EmoteType.bttv] = emotes;
        return emotes;
      },
      EmoteType.ffz: () async {
        if (!_isProviderOn(EmoteType.ffz)) return [];
        final emotes = await FfzEmoteProvider.fetchChannel(
          broadcasterId,
          resolution: _tier.resolution!,
        );
        if (emotes.isNotEmpty) results[EmoteType.ffz] = emotes;
        return emotes;
      },
      EmoteType.sevenTv: () async {
        if (!_isProviderOn(EmoteType.sevenTv)) return [];
        final resp = await _sevenTvChannelFetcher(
          broadcasterId,
          _tier.resolution!,
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
            logDebug('EmoteManager: ${entry.key.name} failed: $e');
          }
        }),
      );
    }
    await Future.wait(futures, eagerError: false);
    return failed;
  }

  Future<({EmoteCatalog? catalog, bool fresh})> _loadPersistedCache(
    String key,
    Duration ttl, {
    DateTime? fetchTime,
  }) async {
    final prefs = await _getPrefs();
    await _metaStore.migrateFromPrefs(prefs.raw);
    final raw = await _metaStore.read(key);
    if (raw == null) return (catalog: null, fresh: false);
    try {
      // Decode off main isolate for smooth startup.
      final tierIndex = _tier.index;
      final parsed = await Isolate.run(() {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final catalog = EmoteCatalog.fromJsonMap(data['emotes']);
        final tierMatches = data['tier'] is! int || data['tier'] == tierIndex;
        return (
          catalog: catalog,
          tierMatches: tierMatches,
          ts: data['ts'] as String,
        );
      });
      final ts = DateTime.parse(parsed.ts);
      final cachedTime = fetchTime ?? ts;
      final withinTtl = DateTime.now().difference(cachedTime) <= ttl;
      final fresh = withinTtl && parsed.tierMatches;
      return (catalog: _dropSubs(parsed.catalog), fresh: fresh);
    } catch (_) {
      logDebug('[EmoteManager] failed to parse cached emotes');
      return (catalog: null, fresh: false);
    }
  }

  // Persisted Twitch lists must never rehydrate another account's true subs.
  EmoteCatalog _dropSubs(EmoteCatalog catalog) => catalog.copyWith(
    twitchGlobal: catalog.twitchGlobal.where((e) => !_isTwitchSub(e)).toList(),
    twitchChannel: catalog.twitchChannel
        .where((e) => !_isTwitchSub(e))
        .toList(),
    twitchSubs: const [],
  );

  Future<void> _savePersistedCache(
    String key,
    EmoteCatalog catalog,
    Duration ttl,
  ) async {
    // Low/nothing: persist Twitch too (zero network). Medium/high: non-Twitch only.
    // Per-account unlocks never persist: emote-set unlocks plus catalogue
    // unlock ids tracked from the broadcaster_id=0 fetch.
    final persistTwitch =
        _tier == EmoteFetchTier.low || _tier == EmoteFetchTier.nothing;
    List<Emote> keepTwitch(List<Emote> emotes) {
      if (!persistTwitch) return const [];
      return emotes.where((e) {
        if (_isTwitchSub(e)) return false;
        if (e.id.isNotEmpty &&
            (_unlockedTwitchEmotes.containsKey(e.id) ||
                _twitchCatalogUnlockIds.contains(e.id))) {
          return false;
        }
        return true;
      }).toList();
    }

    final saved = EmoteCatalog(
      twitchGlobal: keepTwitch(catalog.twitchGlobal),
      bttvGlobal: catalog.bttvGlobal,
      ffzGlobal: catalog.ffzGlobal,
      sevenTvGlobal: catalog.sevenTvGlobal,
      twitchChannel: keepTwitch(catalog.twitchChannel),
      bttvChannel: catalog.bttvChannel,
      ffzChannel: catalog.ffzChannel,
      sevenTvChannel: catalog.sevenTvChannel,
      twitchSubs: const [],
      sevenTvPersonal: const [],
    );
    if (saved.isEmpty) return;
    try {
      final data = {
        'ts': DateTime.now().toIso8601String(),
        'tier': _tier.index,
        'emotes': saved.toJsonMap(),
      };
      await _metaStore.write(key, jsonEncode(data));
    } catch (_) {
      logDebug('[EmoteManager] failed to save emotes to disk');
    }
  }

  /// Prunes persisted registries for left channels.
  Future<void> pruneStaleChannels(Set<String> activeChannels) async {
    try {
      for (final key in await _metaStore.keys()) {
        if (!key.startsWith('emotes4_')) continue;
        // Personal seeds are account-scoped, not channel-scoped.
        if (key == _personalSetsKey) continue;
        final channel = key.substring('emotes4_'.length);
        if (channel.isEmpty || channel == 'global') continue;
        if (!activeChannels.contains(channel)) {
          await _metaStore.delete(key);
        }
      }
    } catch (_) {}
  }

  /// Deletes all persisted emote metadata (global + per channel), including
  /// left channels. Used by the nuke action so the refetch rebuilds from the
  /// network instead of reseeding from disk.
  Future<void> wipePersisted() async {
    try {
      for (final key in await _metaStore.keys()) {
        if (key.startsWith('emotes4_')) await _metaStore.delete(key);
      }
    } catch (_) {
      logDebug('[EmoteManager] failed to wipe persisted emotes');
    }
  }

  // ── Disk-cache GC: usage tracking ───────────────────────────────────

  /// Usage registry capped at max(300, _cacheCap).
  int get _usageMaxEntries =>
      _cacheCap > _usageMinEntries ? _cacheCap : _usageMinEntries;

  final Set<String> _pendingUsageTouches = {};

  /// Eviction score; null falls back to recency decay.
  double? _registryScore(String url) {
    final record = _emoteUsage[url];
    if (record == null) return null;
    final now = _now();
    final hour = now.millisecondsSinceEpoch ~/ _hourMs;
    final rolled = EmoteUsageRecord.rolledForward(record, hour);
    if (!identical(rolled, record)) _emoteUsage[url] = rolled;
    return rolled.score(now);
  }

  static const _hourMs = 3600000;

  void _touchUsage(String url) {
    if (url.isEmpty) return;
    if (!_usageLoaded) {
      // Defer until loaded to avoid clobbering persisted registry.
      _pendingUsageTouches.add(url);
      return;
    }
    final now = _now();
    final hour = now.millisecondsSinceEpoch ~/ _hourMs;
    final existing = _emoteUsage[url];
    _emoteUsage[url] = existing == null
        ? EmoteUsageRecord(
            lastUsedAt: now,
            bucketBase: hour,
            buckets: List.filled(EmoteUsageRecord._bucketCount, 0),
          ).bumpedAt(hour, now: now)
        : EmoteUsageRecord.bumped(existing, hour, now: now);
    _usageDirty = true;
  }

  Future<void> _ensureUsageLoaded() async {
    if (_usageLoaded) return;
    _usageLoaded = true;
    final prefs = await _getPrefs();
    final raw = prefs.emoteUsage;
    if (raw != null) {
      try {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final entries = data['e'];
        if (entries is Map<String, dynamic>) {
          final now = _now();
          final hour = now.millisecondsSinceEpoch ~/ _hourMs;
          for (final entry in entries.entries) {
            final value = entry.value;
            if (value is! Map<String, dynamic>) continue;
            final record = EmoteUsageRecord.fromJson(value);
            if (record == null) continue;
            _emoteUsage[entry.key] = EmoteUsageRecord.rolledForward(
              record,
              hour,
            );
          }
        }
      } catch (_) {
        logDebug('[EmoteManager] failed to parse emote usage registry');
      }
    }
    if (_pendingUsageTouches.isNotEmpty) {
      for (final url in _pendingUsageTouches) {
        _touchUsage(url);
      }
      _pendingUsageTouches.clear();
      _usageDirty = true;
    }
  }

  Future<void> _flushUsage() async {
    if (!_usageLoaded) return;
    await _ensureUsageLoaded();
    if (!_usageDirty) return;
    _usageDirty = false;
    if (_emoteUsage.length > _usageMaxEntries) {
      // Drop lowest-scored entries.
      final now = _now();
      final entries = _emoteUsage.entries.toList()
        ..sort((a, b) => a.value.score(now).compareTo(b.value.score(now)));
      final overflow = entries.length - _usageMaxEntries;
      for (final entry in entries.take(overflow)) {
        _emoteUsage.remove(entry.key);
      }
    }
    final prefs = await _getPrefs();
    final data = <String, dynamic>{
      'v': 2,
      'e': {
        for (final entry in _emoteUsage.entries)
          entry.key: entry.value.toJson(),
      },
    };
    final encoded = await Isolate.run(() => jsonEncode(data));
    await prefs.setEmoteUsage(encoded);
  }

  /// Debounced flush for high-frequency view tracking.
  void _scheduleUsageFlush() {
    if (!_usageLoaded) return;
    _usageFlushTimer?.cancel();
    _usageFlushTimer = Timer(_usageFlushDelay, () {
      _usageFlushTimer = null;
      unawaited(_flushUsage());
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _usageFlushTimer?.cancel();
    _precacheQueue.clear();
    super.dispose();
  }

  // ── Cache init + migrations ─────────────────────────────────────────

  /// Runs migrations, registers priority source, enforces cap.
  Future<void> startCacheGc() async {
    await _ensureUsageLoaded();
    final cache = _cacheManager;
    cache.maxObjects = _cacheCap;
    cache.priorityScore = _registryScore;
    cache.lastUsedAt = (url) => _emoteUsage[url]?.lastUsedAt;
    if (!_migrationRan) {
      final prefs = await _getPrefs();
      if (prefs.emoteGcMigratedV1) {
        _migrationRan = true;
      } else {
        // First launch after GC: clear old cache (untracked by usage registry).
        try {
          await DefaultCacheManager().emptyCache();
        } catch (_) {
          logDebug('[EmoteManager] cache migration emptyCache failed');
        }
        _migrationRan = true;
        await prefs.setEmoteGcMigratedV1(true);
      }
    }
    if (!_migrationRanV2) {
      final prefs = await _getPrefs();
      if (prefs.emoteGcMigratedV2) {
        _migrationRanV2 = true;
      } else {
        // v2 migration: clear v1 DefaultCacheManager leftovers.
        try {
          await DefaultCacheManager().emptyCache();
        } catch (_) {
          logDebug('[EmoteManager] cache v2 migration emptyCache failed');
        }
        _migrationRanV2 = true;
        await prefs.setEmoteGcMigratedV2(true);
      }
    }
    await cache.enforceNow();
  }

  // ── Pre-cache queue for seen emotes ──────────────────────────────────

  final Set<String> _seenEmoteIds = {};
  final _precacheQueue = <Emote>[];
  bool _isProcessingPrecache = false;
  static const _maxConcurrentPrecache = 5;
  // Bounded dedup and queue to prevent unbounded growth.
  static const _maxSeenEmoteIds = 2000;
  static const _maxPrecacheQueue = 300;

  void enqueueSeenEmotes(List<Emote> emotes) {
    // Nothing tier: skip fetch and usage tracking.
    if (_tier == EmoteFetchTier.nothing) return;
    final fresh = <Emote>[];
    for (final e in emotes) {
      if (_seenEmoteIds.add(e.id)) {
        fresh.add(e);
      }
    }
    if (fresh.isEmpty) return;
    // Evict oldest-seen ids instead of clearing the set.
    while (_seenEmoteIds.length > _maxSeenEmoteIds) {
      final it = _seenEmoteIds.iterator;
      it.moveNext();
      _seenEmoteIds.remove(it.current);
    }
    for (final e in fresh) {
      _touchUsage(e.url);
    }
    // Zero cap: skip precache (eviction would delete immediately).
    if (_cacheCap > 0) {
      _precacheQueue.addAll(fresh);
      // Bound queue: drop oldest pending when outpacing drain.
      if (_precacheQueue.length > _maxPrecacheQueue) {
        _precacheQueue.removeRange(
          0,
          _precacheQueue.length - _maxPrecacheQueue,
        );
      }
      if (!_isProcessingPrecache) {
        _processPrecacheQueue();
      }
    }
    _scheduleUsageFlush();
  }

  void _processPrecacheQueue() {
    _isProcessingPrecache = true;
    _stepPrecache();
  }

  void _stepPrecache() {
    if (_precacheQueue.isEmpty) {
      _isProcessingPrecache = false;
      return;
    }
    final batch = _precacheQueue.take(_maxConcurrentPrecache).toList();
    _precacheQueue.removeRange(0, batch.length);
    Future.wait(
      batch.map(_precacheEmote),
      eagerError: false,
    ).then((_) => _stepPrecache());
  }

  Future<void> _precacheEmote(Emote emote) async {
    if (await _cacheManager.isFull()) return;
    try {
      await _cacheManager.getSingleFile(emote.url);
    } catch (_) {
      logDebug('[EmoteManager] failed to precache emote: ${emote.code}');
    }
  }
}
