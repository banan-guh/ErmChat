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
import '../services/twitch_auth.dart';
import '../util/log.dart';
import '../util/prefs.dart';
import 'emote_cache_manager.dart';
import 'emote_fetch.dart';
import 'emote_fetcher.dart';
import 'emote_meta_store.dart';
import 'emote_store.dart';
import 'seven_tv_event_client.dart';
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

class EmoteManager {
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
  final EmoteCacheManager? _injectedCacheManager;
  EmoteCacheManager? _cacheManagerInstance;
  final EmoteMetaStore _metaStore;
  final Map<String, EmoteUsageRecord> _emoteUsage = {};

  // Network fetching and fetch policy live in the fetcher; the manager owns
  // the resulting state and commits.
  late final EmoteFetcher _fetcher;

  // Catalog state, commits, and lookups live in the store; the manager feeds
  // it fetches and owns the per-account overlays (personal 7TV sets, Twitch
  // unlocks) plus the usage registry and prefs.
  final EmoteStore _store;
  final bool _ownsStore;

  /// Resolved lazily so constructing an [EmoteManager] (e.g. in tests) never
  /// instantiates the path-provider-backed cache singleton until it's needed.
  EmoteCacheManager get _cacheManager =>
      _cacheManagerInstance ??= (_injectedCacheManager ?? EmoteCacheManager());
  bool _usageLoaded = false;
  bool _usageDirty = false;
  bool _migrationRan = false;
  bool _migrationRanV2 = false;

  // How long view-touch flushes wait for quiet before persisting. The emote
  // menu marks dozens of cells viewed on open; the debounce collapses that
  // burst into a single prefs write.
  static const _defaultUsageFlushDelay = Duration(milliseconds: 250);
  final Duration _usageFlushDelay;
  Timer? _usageFlushTimer;

  EmoteManager({
    EmoteStore? store,
    Future<List<ConnectivityResult>> Function()? probe,
    Duration fetchStagger = defaultEmoteFetchStagger,
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
  }) : _store = store ?? EmoteStore(),
       _ownsStore = store == null,
       _injectedCacheManager = cacheManager,
       _metaStore = metaStore ?? EmoteMetaStore.I,
       _now = now ?? DateTime.now {
    _removeCachedFile =
        removeCachedFile ?? ((String url) => _cacheManager.removeFile(url));
    _tier = tier;
    _cacheCap = cacheCap.clamp(minEmoteCacheMax, maxEmoteCacheMax).toInt();
    _fetcher = EmoteFetcher(
      now: _now,
      tier: () => _tier,
      isProviderEnabled: _isProviderOn,
      accessToken: () => _accessToken,
      probe: probe,
      fetchStagger: fetchStagger,
      sevenTvChannelFetcher: sevenTvChannelFetcher,
      sevenTvGlobalFetcher: sevenTvGlobalFetcher,
      sevenTvOwnedSetIds: sevenTvOwnedSetIdsFetcher,
      sevenTvEmoteSetFetcher: sevenTvEmoteSetFetcher,
      resolveOwnerLogins: resolveOwnerLogins,
      fetchUserEmoteSets: fetchUserEmoteSets,
    );
  }

  /// Catalog store backing lookups and commits.
  EmoteStore get store => _store;

  /// Fetching tier controlling resolution, cache TTL, and 7TV reconcile gating.
  EmoteFetchTier get tier => _tier;

  set tier(EmoteFetchTier value) {
    if (value == _tier) return;
    _tier = value;
    _store.notifyStateCleared();
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

  /// Current emote-data version. Forwards the store so message span caches
  /// detect stale spans lazily; live 7TV deltas do not advance it.
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

  set accessToken(String? value) => _accessToken = value;

  // Merged emotes: channel overrides global, personal 7TV merges everywhere.
  // The store owns the cache; the manager supplies the account overlays.
  EmoteLookup? byCode(String channel) => _store.byCode(
    channel,
    personal: _personalEmotes,
    unlocks: _unlockedTwitchEmotes.values,
  );

  // Viewer personal 7TV emotes in merge order (first set wins code conflicts).
  Iterable<Emote> get _personalEmotes sync* {
    for (final setEmotes in _personalSevenTvSets.values) {
      yield* setEmotes;
    }
  }

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
    personal: _personalEmotes,
    unlocks: _unlockedTwitchEmotes.values,
  );

  /// Recents resolved to [channel]-local codes; dead ids are dropped.
  Future<List<Emote>> recentsForChannel(String channel) async {
    final recents = await recentEmotes();
    final suggestions = byCode(channel)?.suggestions;
    if (suggestions == null) return recents;
    return resolveRecentsForChannel(recents, suggestions);
  }

  /// Subscriber emotes grouped by owner, with [pinnedChannel] first.
  Map<String, List<Emote>> subsGrouped({String? pinnedChannel}) =>
      _store.subsGrouped(pinnedChannel: pinnedChannel);

  /// Channel picker tab: third-party channel emotes plus unlocked Twitch
  /// channel emotes, sorted by code. Status-gated Twitch emotes (subs,
  /// followers, bitstier) live in the subs tab instead: they only render
  /// from the IRC tag, so listing them here implies anyone can use them.
  List<Emote> channelTabEmotes(String channel) =>
      _store.channelTabEmotes(channel);

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
    personal: _personalEmotes,
    unlocks: _unlockedTwitchEmotes.values,
    foreign: senderTwitchId == null
        ? null
        : _foreignPersonalSets[senderTwitchId],
  );

  /// Viewer Twitch user id for matching personal 7TV grants. Cleared logout.
  set viewerTwitchId(String? value) {
    if (_viewerTwitchId == value) return;
    _viewerTwitchId = value;
    _personalSevenTvSetIds.clear();
    _personalSevenTvSets.clear();
    _store.notifyStateCleared();
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
      setIds = await _fetcher.fetchSevenTvOwnedSetIds(viewerId);
    } catch (e) {
      logDebug('[EmoteManager] personal 7TV set listing failed: $e');
      return;
    }
    var changed = false;
    for (final setId in setIds) {
      if (_personalSevenTvSetIds.contains(setId)) continue;
      List<Emote> emotes;
      try {
        emotes = await _fetcher.fetchSevenTvEmoteSet(setId, _tier.resolution!);
      } catch (e) {
        logDebug('[EmoteManager] personal 7TV set $setId failed: $e');
        continue;
      }
      _personalSevenTvSetIds.add(setId);
      _personalSevenTvSets[setId] = emotes;
      changed = true;
    }
    if (changed) {
      _store.notifyStateCleared();
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
        _store.notifyStateCleared();
        unawaited(_savePersonalSets());
      }
      return;
    }
    if (_personalSevenTvSetIds.contains(event.cosmeticId)) return;
    List<Emote> emotes;
    try {
      emotes = await _fetcher.fetchSevenTvEmoteSet(
        event.cosmeticId,
        _tier.resolution!,
      );
    } catch (e) {
      logDebug('[EmoteManager] personal 7TV grant fetch failed: $e');
      return;
    }
    _personalSevenTvSetIds.add(event.cosmeticId);
    _personalSevenTvSets[event.cosmeticId] = emotes;
    _store.notifyStateCleared();
    unawaited(_savePersonalSets());
  }

  /// Map for one message: channel sets plus the sender's personal 7TV emotes
  /// underneath. Foreign codes never leak into other senders' messages.
  EmoteLookup? byCodeForSender(String channel, String? senderTwitchId) =>
      _store.byCodeForSender(
        channel,
        senderTwitchId,
        personal: _personalEmotes,
        unlocks: _unlockedTwitchEmotes.values,
        foreign: senderTwitchId == null
            ? null
            : _foreignPersonalSets[senderTwitchId],
      );

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
        _store.notifyStateCleared();
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
      _store.notifyStateCleared();
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
    _store.notifyStateCleared();
    unawaited(_savePersonalSets());
  }

  /// One-time REST fill for a socket-announced set. Once per set id, shared
  /// by all owners; failures stay uncached so a later grant retries.
  Future<void> _fillForeignPersonalSet(String setId) async {
    if (_foreignPersonalSetContents.containsKey(setId)) return;
    if (_tier == EmoteFetchTier.nothing) return;
    if (!_isProviderOn(EmoteType.sevenTv)) return;
    if (_foreignPersonalSetInflight.containsKey(setId)) return;
    final future = () async {
      List<Emote> fetched;
      try {
        fetched = await _fetcher.fetchSevenTvEmoteSet(setId, _tier.resolution!);
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
      _store.notifyStateCleared();
    }();
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
      if (changed) _store.notifyStateCleared();
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

  // Global emotes by provider, in display order, sorted by code.
  Map<String, List<Emote>> globalEmotesByProvider() =>
      _store.globalEmotesByProvider(
        personal: _personalEmotes,
        unlocks: _unlockedTwitchEmotes.values,
      );

  /// Whether [channel]'s cache exists (stale is fine).
  bool hasChannelCache(String channel) => _store.hasChannelCache(channel);

  /// Whether the global emote cache has been resolved at least once.
  bool get hasGlobalCache => _store.hasGlobalCache;

  Map<String, List<Emote>> subscriberEmotesByChannel() =>
      _store.subscriberEmotesByChannel();

  static const _maxRecent = 100;
  List<String> _recentIds = [];
  bool _recentLoaded = false;
  Prefs? _prefs;

  // ── Provider visibility toggles ─────────────────────────────────────
  bool _providersLoaded = false;

  Future<void> _ensureProvidersLoaded() async {
    if (_providersLoaded) return;
    _providersLoaded = true;
    final prefs = await _getPrefs();
    final raw = prefs.emoteProvidersDisabled;
    final disabled = <EmoteType>{};
    var migrated = false;
    if (raw != null) {
      for (final t in EmoteType.values) {
        if (raw.contains(t.name)) disabled.add(t);
      }
      // Migrate: Twitch is no longer toggleable.
      if (disabled.remove(EmoteType.twitch)) migrated = true;
    }
    _store.setProviderVisibility(disabled, prefs.emoteAllowUnlisted7tv);
    if (!migrated) return;
    await prefs.setEmoteProvidersDisabled(disabled.map((t) => t.name).toList());
  }

  /// Whether [type] is fetched and rendered (sync view).
  bool isProviderEnabled(EmoteType type) {
    if (!_providersLoaded) unawaited(_ensureProvidersLoaded());
    return _store.isProviderEnabled(type);
  }

  /// Current enabled providers, awaiting the persisted load first.
  Future<Set<EmoteType>> enabledProviders() async {
    await _ensureProvidersLoaded();
    return {
      for (final t in EmoteType.values)
        if (_store.isProviderEnabled(t)) t,
    };
  }

  Future<void> setProviderEnabled(EmoteType type, bool enabled) async {
    await _ensureProvidersLoaded();
    if (!_store.enableProvider(type, enabled)) return;
    final prefs = await _getPrefs();
    await prefs.setEmoteProvidersDisabled(
      EmoteType.values
          .where((t) => !_store.isProviderEnabled(t))
          .map((t) => t.name)
          .toList(),
    );
    _store.notifyVisibilityChanged();
  }

  /// Whether unlisted 7TV emotes render (sync view).
  bool get allowUnlisted7tv {
    if (!_providersLoaded) unawaited(_ensureProvidersLoaded());
    return _store.allowUnlisted7tv;
  }

  Future<void> setAllowUnlisted7tv(bool allowed) async {
    await _ensureProvidersLoaded();
    if (!_store.setAllowUnlisted(allowed)) return;
    final prefs = await _getPrefs();
    await prefs.setEmoteAllowUnlisted7tv(allowed);
    _store.notifyVisibilityChanged();
  }

  bool _hasGlobalStash(EmoteType type) =>
      _store.globalCatalog.listFor(EmoteScope.global, type).isNotEmpty;

  bool _hasChannelStash(String channel, EmoteType type) =>
      _store
          .channelCatalog(channel)
          ?.listFor(EmoteScope.channel, type)
          .isNotEmpty ??
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
    await _fetcher.enqueue(() async {
      for (final type in targets.where((t) => !_hasGlobalStash(t))) {
        try {
          final fetch = await _fetcher.fetchGlobalForProvider(type, resolution);
          if (fetch.byProvider.isNotEmpty) {
            _commitGlobal(_store.globalEpoch, fetch);
            fetched = true;
          }
        } catch (e) {
          logDebug('[EmoteManager] stash refetch failed for ${type.name}: $e');
        }
      }
      for (final channel in _store.channelNames) {
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
            final fetch = await _fetcher.fetchChannelForProvider(
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
          _store.channelEpoch(channel),
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

  /// Resolve an emote by ID across all caches, then the personal overlay.
  Emote? emoteById(String id) =>
      _store.emoteById(id, personal: _personalEmotes);

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
      final emote = emoteById(id);
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
    final epoch = force ? _store.bumpGlobalEpoch() : _store.globalEpoch;
    await _ensureProvidersLoaded();
    if (_store.hasGlobalCache && !force) return;
    final ttl = await _fetcher.effectiveTtl();
    if (!force) {
      final loaded = await _loadPersistedCache('emotes4_global', ttl);
      final cached = loaded.catalog;
      if (cached != null) {
        if (!_store.seedGlobalFromCache(epoch, cached)) return;
        if (loaded.fresh ||
            _registryFrozen ||
            _tier == EmoteFetchTier.nothing) {
          // Fresh cache: render, then background-refresh Twitch globals.
          if (!_skipTwitchBackgroundRefresh) {
            unawaited(
              _fetcher.enqueue(_fetcher.refreshTwitchGlobal).then((fetch) {
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
      // Seed provider lists a wiped stash would otherwise lose to a flaky
      // fetch (429/5xx/timeout), without clobbering in-memory data.
      if (!_store.fillMissingGlobal(epoch, loaded.catalog!)) return;
    }
    final fetch = await _fetcher.enqueue(_fetcher.fetchAllGlobal);
    if (_commitGlobal(epoch, fetch)) {
      await _savePersistedCache('emotes4_global', _store.globalCatalog, ttl);
    }
    _store.notifyStateCleared();
  }

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
    _store.markGlobalResolved();
    _store.notifyStateCleared();
  }

  Future<void> storeUserTwitchEmotes(
    Map<String, List<Emote>> perChannel,
  ) async {
    if (_tier == EmoteFetchTier.nothing) return;
    _store.storeUserTwitchEmotes(perChannel);
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
    _store.notifyStateCleared();
    try {
      final byOwner = await _fetcher.fetchUserEmoteSets(
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
      final resolved = await _fetcher.resolveOwnerLogins(auth, owners);
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
    // Unlocks are per-account: drop them from the global Twitch list they
    // merged into. Matches by id, plus by code for empty-id entries, so a
    // same-code default underneath is not removed with them.
    final removedIds = <String>{..._unlockedTwitchEmotes.keys};
    final removedCodes = <String>{
      for (final e in _unlockedTwitchEmotes.values) e.code,
    };
    final removedCatalogIds = <String>{..._twitchCatalogUnlockIds};
    _unlockedTwitchEmotes.clear();
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
    _store.clearAccountScopedState(
      removedUnlockIds: removedIds,
      removedUnlockCodes: removedCodes,
      removedCatalogUnlockIds: removedCatalogIds,
    );
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

  /// Loads channel emotes. [force] skips cache, fetches from network.
  Future<void> resolveEmotes(
    String channel,
    String? broadcasterId, {
    bool force = false,
  }) async {
    final epoch = force
        ? _store.bumpChannelEpoch(channel)
        : _store.channelEpoch(channel);
    await _ensureProvidersLoaded();
    if (broadcasterId != null) _channelBroadcasterIds[channel] = broadcasterId;
    final ttl = await _fetcher.effectiveTtl();
    if (force) {
      // Nothing tier: render cached only.
      if (_tier == EmoteFetchTier.nothing) return;
      final loaded = await _loadPersistedCache('emotes4_$channel', ttl);
      if (_store.channelEpoch(channel) != epoch) return;
      if (loaded.catalog != null) {
        _store.fillMissingChannel(channel, loaded.catalog!);
      }
      final fetch = await _fetcher.enqueue(
        () => _fetcher.fetchAllChannel(broadcasterId, channelName: channel),
      );
      if (_commitChannel(channel, epoch, fetch)) {
        await _savePersistedCache(
          'emotes4_$channel',
          _store.channelCatalog(channel)!,
          ttl,
        );
      }
      return;
    }
    final loaded = await _loadPersistedCache(
      'emotes4_$channel',
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
      if (loaded.fresh || _registryFrozen || _tier == EmoteFetchTier.nothing) {
        // Fresh: render, background-refresh Twitch channel emotes.
        if (!_skipTwitchBackgroundRefresh) {
          unawaited(
            _fetcher
                .enqueue(
                  () => _fetcher.refreshTwitchChannel(channel, broadcasterId),
                )
                .then((fetch) {
                  if (fetch != null) _commitChannel(channel, epoch, fetch);
                }),
          );
        }
        // Reconcile 7TV deltas at startup: the fetched set is authoritative,
        // so stale live deltas are dropped rather than re-applied over it.
        if (broadcasterId != null &&
            _tier.index >= EmoteFetchTier.medium.index) {
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
                }),
          );
        }
        return;
      }
      // Stale: keep stale data, revalidate below.
    }
    // Nothing tier: render cached only.
    if (_tier == EmoteFetchTier.nothing) return;
    final fetch = await _fetcher.enqueue(
      () => _fetcher.fetchAllChannel(broadcasterId, channelName: channel),
    );
    if (_commitChannel(channel, epoch, fetch)) {
      await _savePersistedCache(
        'emotes4_$channel',
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
    // fetch stays pure. An empty set leaves the retained ids untouched.
    if (fetch.twitchCatalogUnlockIds.isNotEmpty) {
      _twitchCatalogUnlockIds
        ..clear()
        ..addAll(fetch.twitchCatalogUnlockIds);
    }
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
  /// `user.update` switches the active set: without it the old set keeps
  /// rendering and the next full fetch resurrects it via the live list.
  Future<void> reconcileSevenTvChannel(String channel) async {
    await _ensureProvidersLoaded();
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
    _unlockedTwitchEmotes.clear();
    _twitchCatalogUnlockIds.clear();
    _store.evictGlobal();
  }

  void markEmotesResolved(String channel) => _store.markEmotesResolved(channel);

  bool emotesResolved(String channel) => _store.emotesResolved(channel);

  /// Bumps the version and notifies listeners with the current (possibly
  /// empty) state, so cached message spans are discarded immediately.
  void notifyStateCleared() => _store.notifyStateCleared();

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
    if (_tier == EmoteFetchTier.nothing) return;
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

  @visibleForTesting
  Future<Duration> effectiveTtlForTesting() => _fetcher.effectiveTtl();

  @visibleForTesting
  int get precacheQueueLengthForTesting => _precacheQueue.length;

  @visibleForTesting
  Future<void> enqueueFetchForTesting(Future<void> Function() action) =>
      _fetcher.enqueue(action);

  @visibleForTesting
  Future<void> flushUsageForTesting() => _flushUsage();

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
  int foreignPersonalSetCountForTesting() => _foreignPersonalSetContents.length;

  @visibleForTesting
  Future<GlobalEmoteFetch> fetchAllGlobalForTesting() async {
    await _ensureProvidersLoaded();
    return _fetcher.fetchAllGlobal();
  }

  @visibleForTesting
  Future<ChannelEmoteFetch> fetchAllChannelForTesting(
    String? broadcasterId, {
    String? channelName,
  }) async {
    await _ensureProvidersLoaded();
    return _fetcher.fetchAllChannel(broadcasterId, channelName: channelName);
  }

  /// Sync gate for fetch lambdas; callers must have awaited
  /// [_ensureProvidersLoaded] first.
  bool _isProviderOn(EmoteType type) => _store.isProviderEnabled(type);

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
    twitchGlobal: catalog.twitchGlobal.where((e) => !isTwitchSub(e)).toList(),
    twitchChannel: catalog.twitchChannel.where((e) => !isTwitchSub(e)).toList(),
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
        if (isTwitchSub(e)) return false;
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

  void dispose() {
    _usageFlushTimer?.cancel();
    _precacheQueue.clear();
    if (_ownsStore) _store.dispose();
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
