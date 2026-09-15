import '../emotes/emote.dart';
import '../emotes/emote_catalog.dart';
import '../models/twitch_message.dart';
import 'emote_fetcher.dart';

/// One typed catalog change emitted by [EmoteStore].
///
/// [channel] null means a global change. A non-null [deltaCodes] marks a live
/// 7TV delta: it must refresh the picker lists but not invalidate rendered
/// messages (those keep the emote state they were built with). A null
/// [deltaCodes] on a channel change is a full refetch.
class EmoteChange {
  const EmoteChange({
    required this.version,
    this.channel,
    this.deltaCodes,
    this.overlay = false,
  });

  final int version;
  final String? channel;
  final Set<String>? deltaCodes;

  /// True for an overlay-only refresh (personal/foreign 7TV sets): cached
  /// lookups refresh, but rendered spans and the id index stay valid.
  final bool overlay;

  bool get isGlobal => channel == null;
  bool get isDelta => deltaCodes != null;
}

/// Owns the emote catalog state: provider lists per scope, 7TV identity and
/// live sets, the merged lookup caches, and the id index.
///
/// Plain Dart object (no Riverpod, no Flutter). The manager feeds it fetches
/// and observes [EmoteChange]; the Riverpod notifier bridges that stream to
/// widgets. Personal 7TV emotes and account unlocks stay in the manager and
/// arrive as overlay parameters on the lookup methods.
class EmoteStore {
  // ── Change stream ───────────────────────────────────────────────────
  final _listeners = <void Function(EmoteChange)>[];
  bool _disposed = false;
  int _version = 0;
  EmoteChange? _lastChange;

  /// Catalog version used by message span caches. Live 7TV deltas do not
  /// advance it, so already-rendered messages stay frozen.
  int get version => _version;

  /// Most recent change, or null before the first one.
  EmoteChange? get lastChange => _lastChange;

  void addListener(void Function(EmoteChange) listener) =>
      _listeners.add(listener);

  void removeListener(void Function(EmoteChange) listener) =>
      _listeners.remove(listener);

  void dispose() {
    _disposed = true;
    _listeners.clear();
  }

  /// Records a catalog change. [bumpVersion] false keeps rendered spans frozen
  /// (live 7TV deltas). Drops the affected merged cache and notifies.
  void emitChange({
    String? channel,
    Set<String>? deltaCodes,
    bool bumpVersion = true,
    bool overlay = false,
  }) {
    if (_disposed) return;
    if (bumpVersion) _version++;
    final change = EmoteChange(
      version: _version,
      channel: channel,
      deltaCodes: deltaCodes,
      overlay: overlay,
    );
    _lastChange = change;
    if (!overlay) _emoteIndexDirty = true;
    if (channel != null) {
      _mergedCache.remove(channel);
      _foreignLookupCache.remove(channel);
    } else {
      _mergedCache.clear();
      _foreignLookupCache.clear();
    }
    for (final listener in List.of(_listeners)) {
      listener(change);
    }
  }

  /// Overlay-only refresh: personal sets, fetch state, configuration, or
  /// visibility. Refreshes derived lookups so new messages resolve updates,
  /// but does not bump the span version or dirty the id index, so visible
  /// messages keep their spans and no cross-channel re-render storm happens.
  void notifyOverlayChanged() {
    _mergedCache.clear();
    _foreignLookupCache.clear();
    emitChange(channel: null, bumpVersion: false, overlay: true);
  }

  /// Emits a global full change (account reset, overlay/personal change).
  void notifyStateCleared() => emitChange(channel: null);

  /// Records a config-only update (tier, auto mode). Catalog data is unchanged,
  /// so this refreshes derived lookups without invalidating rendered spans.
  void notifyConfigChanged() => notifyOverlayChanged();

  /// Clears derived visibility caches and refreshes lookups without
  /// invalidating rendered spans.
  void notifyVisibilityChanged() {
    _subsByChannelCache = null;
    notifyOverlayChanged();
  }

  // ── Catalog state ───────────────────────────────────────────────────
  // Global provider catalog plus an attempted flag. The catalog persists
  // list-for-list, so per-provider retention and toggle rebuilds need no
  // lossy reconstruction.
  EmoteCatalog _globalCatalog = EmoteCatalog();
  bool _globalAttempted = false;
  // Epoch per scope: a forced refresh or evict bumps it, so a commit from an
  // older in-flight fetch is dropped instead of overwriting newer state.
  int _globalEpoch = 0;
  // Per-channel emote metadata (code maps, not image bytes: decoded pixels
  // and disk files are shared by URL across channels). One catalog per joined
  // channel; evictChannel frees it on leave, so no cap is kept.
  final _channelCatalogs = <String, EmoteCatalog>{};
  final _channelEpoch = <String, int>{};
  // Account generation folded into every channel epoch, so an account switch
  // drops all in-flight channel commits without tracking each one.
  int _channelEpochBase = 0;
  final _channelFetchTimes = <String, DateTime>{};
  final _emotesResolvedChannels = <String>{};
  final _sevenTvEmoteSetIds = <String, String>{};
  final _sevenTvUserIds = <String, String>{};
  // Live 7TV list; re-applied after fetch rebuilds to avoid clobbering.
  final _sevenTvLive = <String, List<Emote>>{};
  // Channels whose 7TV list came from a full fetch (or a disk seed), so a
  // live delta can be stashed and re-applied over later rebuilds.
  final _sevenTvFull = <String>{};
  // Merged emotes: channel overrides global, personal 7TV merges everywhere.
  // Cached until the next emit clears it.
  final _mergedCache = <String, EmoteLookup?>{};
  // Per-sender overlay lookups keyed by the sender's foreign lookup object.
  // Ingest and render ask for the same sender lookup within one emote version,
  // so sharing the result avoids rebuilding the foreign merge 2-3 times.
  final _foreignLookupCache = <String, Map<EmoteLookup, EmoteLookup>>{};
  static const _maxForeignLookupsPerChannel = 256;
  Map<String, List<Emote>>? _subsByChannelCache;

  final Set<EmoteType> _disabledProviders = {};
  bool _allowUnlisted7tv = false;

  int get globalEpoch => _globalEpoch;

  int bumpGlobalEpoch() => _globalEpoch = _globalEpoch + 1;

  int channelEpoch(String channel) =>
      (_channelEpoch[channel] ?? 0) + _channelEpochBase;

  int bumpChannelEpoch(String channel) {
    _channelEpoch[channel] = (_channelEpoch[channel] ?? 0) + 1;
    return channelEpoch(channel);
  }

  DateTime? channelFetchTime(String channel) => _channelFetchTimes[channel];

  bool get hasGlobalCache => _globalAttempted;

  EmoteCatalog get globalCatalog => _globalCatalog;

  EmoteCatalog? channelCatalog(String channel) => _channelCatalogs[channel];

  List<String> get channelNames => _channelCatalogs.keys.toList();

  bool hasChannelCache(String channel) => _channelCatalogs.containsKey(channel);

  // ── Provider visibility ─────────────────────────────────────────────
  void setProviderVisibility(Set<EmoteType> disabled, bool allowUnlisted) {
    _disabledProviders
      ..clear()
      ..addAll(disabled);
    _allowUnlisted7tv = allowUnlisted;
  }

  bool isProviderEnabled(EmoteType type) => !_disabledProviders.contains(type);

  bool get allowUnlisted7tv => _allowUnlisted7tv;

  /// Toggles [type]; true when the enabled set actually changed.
  bool enableProvider(EmoteType type, bool enabled) =>
      enabled ? _disabledProviders.remove(type) : _disabledProviders.add(type);

  /// Sets unlisted 7TV rendering; true when the value actually changed.
  bool setAllowUnlisted(bool allowed) {
    if (allowed == _allowUnlisted7tv) return false;
    _allowUnlisted7tv = allowed;
    return true;
  }

  // ── Static emote helpers ────────────────────────────────────────────
  /// Twitch emotes that need sender proof: they render only from the IRC
  /// `emotes` tag, never from a bare word match. Covers sub, follower, and
  /// bits tiers. Globals and unlockables stay word-matchable.
  static bool isTwitchLocked(Emote e) =>
      e.meta is TwitchMeta &&
      (e.meta as TwitchMeta).kind != TwitchEmoteKind.standard;

  static TwitchEmoteKind? _kindOf(Emote e) =>
      e.meta is TwitchMeta ? (e.meta as TwitchMeta).kind : null;

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
              scales: {EmoteScale.large: twitchFallbackUrl(pos.emoteId)},
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

  // ── Lookups ─────────────────────────────────────────────────────────
  /// Merged emotes for [channel]: channel overrides global, personal 7TV and
  /// account unlocks overlay everywhere. Cached until the next emit.
  EmoteLookup? byCode(
    String channel, {
    Iterable<Emote> personal = const [],
    Iterable<Emote> unlocks = const [],
  }) {
    final cached = _mergedCache[channel];
    if (cached != null) return cached;
    final channelCatalog = _channelCatalogs[channel];
    final hasGlobalData =
        _globalCatalog.isNotEmpty || unlocks.isNotEmpty || personal.isNotEmpty;
    EmoteLookup? result;
    if (channelCatalog == null && !hasGlobalData) {
      result = null;
    } else {
      result = _buildLookup(
        global: _globalCatalog,
        channel: channelCatalog,
        personal: personal,
        unlocks: unlocks,
      );
    }
    _mergedCache[channel] = result;
    return result;
  }

  /// Map for one message: channel sets plus the sender's personal 7TV emotes
  /// underneath. Foreign codes never leak into other senders' messages.
  /// [foreign] is the caller's per-sender lookup, null when unknown.
  EmoteLookup? byCodeForSender(
    String channel, {
    Iterable<Emote> personal = const [],
    Iterable<Emote> unlocks = const [],
    EmoteLookup? foreign,
  }) {
    final base = byCode(channel, personal: personal, unlocks: unlocks);
    if (foreign == null || foreign.byCode.isEmpty) return base;
    final cache = _foreignLookupCache.putIfAbsent(channel, () => {});
    final cached = cache[foreign];
    if (cached != null) return cached;
    final visible = _filterVisible(foreign);
    if (visible == null) return base;
    final merged = {...visible.byCode};
    if (base != null) merged.addAll(base.byCode);
    final suggestions = merged.values.toList()
      ..sort((a, b) => a.code.compareTo(b.code));
    final result = EmoteLookup(byCode: merged, suggestions: suggestions);
    if (cache.length < _maxForeignLookupsPerChannel) cache[foreign] = result;
    return result;
  }

  // Catalog merge plus the per-account unlock overlay and visibility
  // filters. Callers cache the result in _mergedCache.
  EmoteLookup _buildLookup({
    required EmoteCatalog global,
    EmoteCatalog? channel,
    Iterable<Emote> personal = const [],
    Iterable<Emote> unlocks = const [],
  }) => mergeEmoteLookup(
    global: global,
    channel: channel,
    personal: personal,
    accountUnlocks: unlocks,
    disabledProviders: _disabledProviders,
    allowUnlisted7tv: _allowUnlisted7tv,
  );

  /// What the viewer can type in [channel]: the merged, visibility-filtered
  /// suggestion list. Owned subs are already fanned into every channel, and
  /// follower emotes only exist in their home channel, so no extra merge.
  List<Emote> sendableEmotes(
    String channel, {
    Iterable<Emote> personal = const [],
    Iterable<Emote> unlocks = const [],
  }) =>
      byCode(channel, personal: personal, unlocks: unlocks)?.suggestions ??
      const [];

  /// Subscriber emotes grouped by owner, with [pinnedChannel] first.
  Map<String, List<Emote>> subsGrouped({String? pinnedChannel}) {
    final grouped = Map<String, List<Emote>>.of(subscriberEmotesByChannel());
    final channel = pinnedChannel;
    if (channel == null) return grouped;
    final pinned = grouped.remove(channel);
    if (pinned == null) return grouped;
    return {channel: pinned, ...grouped};
  }

  /// Channel picker tab: third-party channel emotes plus unlocked Twitch
  /// channel emotes, sorted by code. Status-gated Twitch emotes (subs,
  /// followers, bitstier) live in the subs tab instead: they only render
  /// from the IRC tag, so listing them here implies anyone can use them.
  List<Emote> channelTabEmotes(String channel) {
    final cached = _filterVisible(_channelLookup(channel));
    if (cached == null) return [];
    return cached.suggestions.where((e) => !isTwitchLocked(e)).toList();
  }

  /// Emotes found in [text] for precache: tag emotes by id plus word
  /// matches under the sender-proof rule, deduped by id.
  List<Emote> matchEmotes({
    required String channel,
    required String text,
    required List<EmotePosition>? positions,
    String? senderTwitchId,
    Iterable<Emote> personal = const [],
    Iterable<Emote> unlocks = const [],
    EmoteLookup? foreign,
  }) {
    final lookup = senderTwitchId == null
        ? byCode(channel, personal: personal, unlocks: unlocks)
        : byCodeForSender(
            channel,
            personal: personal,
            unlocks: unlocks,
            foreign: foreign,
          );
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

  // Global emotes by provider, in display order, sorted by code.
  Map<String, List<Emote>> globalEmotesByProvider({
    Iterable<Emote> personal = const [],
    Iterable<Emote> unlocks = const [],
  }) {
    final lookup = _buildLookup(
      global: _globalCatalog,
      personal: personal,
      unlocks: unlocks,
    );
    final grouped = <EmoteType, List<Emote>>{};
    for (final e in lookup.suggestions) {
      (grouped[e.type] ??= []).add(e);
    }
    final result = <String, List<Emote>>{};
    for (final t in _globalSortPriority.keys) {
      final list = grouped[t];
      if (list == null || list.isEmpty) continue;
      result[_globalProviderLabels[t] ?? ''] = list;
    }
    return result;
  }

  Map<String, List<Emote>> subscriberEmotesByChannel() {
    if (!isProviderEnabled(EmoteType.twitch)) return {};
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

  /// Resolve an emote by ID across all caches, then the personal and account
  /// unlock overlays.
  Emote? emoteById(
    String id, {
    Iterable<Emote> personal = const [],
    Iterable<Emote> unlocks = const [],
  }) {
    if (_emoteIndexDirty) _rebuildEmoteIndex();
    final found = _emoteIndex[id];
    if (found != null) return found;
    for (final e in personal) {
      if (e.id == id) return e;
    }
    for (final e in unlocks) {
      if (e.id == id) return e;
    }
    return null;
  }

  // Hot-path id index; rebuilt lazily after a catalog change.
  Map<String, Emote> _emoteIndex = {};
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
    _emoteIndex = index;
    _emoteIndexDirty = false;
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

  // Channel-only merged view, matching the old per-channel cache (no global,
  // no personal, unlisted included).
  EmoteLookup _channelLookup(String channel) => mergeEmoteLookup(
    global: EmoteCatalog(),
    channel: _channelCatalogs[channel],
    disabledProviders: _disabledProviders,
    allowUnlisted7tv: true,
  );

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

  // ── Commits ─────────────────────────────────────────────────────────
  /// Seeds the resolved global catalog from a disk cache at [epoch]. A stale
  /// epoch is dropped. Emits a global change.
  bool seedGlobalFromCache(int epoch, EmoteCatalog cached) {
    if (epoch != _globalEpoch) return false;
    _globalCatalog = cached;
    _globalAttempted = true;
    emitChange(channel: null);
    return true;
  }

  /// Fills empty global lists from a disk seed at [epoch]. No emit: the
  /// caller emits once the fetch settles.
  bool fillMissingGlobal(int epoch, EmoteCatalog seed) {
    if (epoch != _globalEpoch) return false;
    _globalCatalog = _globalCatalog.fillMissing(seed);
    _globalAttempted = true;
    return true;
  }

  /// Applies one global fetch at [epoch]. A stale epoch is dropped so an
  /// in-flight fetch that lands after an evict or forced reload cannot
  /// overwrite newer state.
  bool commitGlobal(int epoch, GlobalEmoteFetch fetch) {
    if (epoch != _globalEpoch) return false;
    _globalAttempted = true;
    if (fetch.byProvider.isEmpty) {
      // Nothing new: a retained catalog still counts as applied. Report
      // whether data is present so a no-op failure keeps the persisted cache.
      return _globalCatalog.isNotEmpty;
    }
    var catalog = _globalCatalog;
    for (final entry in fetch.byProvider.entries) {
      catalog = catalog.withList(EmoteScope.global, entry.key, entry.value);
    }
    _globalCatalog = catalog;
    emitChange(channel: null);
    return true;
  }

  /// Seeds a channel catalog from a disk cache and re-applies live 7TV deltas.
  /// Emits a channel full change.
  void seedChannelFromCache(
    String channel,
    EmoteCatalog cached,
    List<Emote> existingSubs,
  ) {
    _channelCatalogs[channel] = cached.copyWith(twitchSubs: existingSubs);
    _sevenTvFull.add(channel);
    _reapplyLiveSevenTv(channel);
    emitChange(channel: channel);
  }

  /// Fills empty channel lists from a disk seed. No emit.
  void fillMissingChannel(String channel, EmoteCatalog seed) {
    _channelCatalogs[channel] = (_channelCatalogs[channel] ?? EmoteCatalog())
        .fillMissing(seed);
  }

  /// Applies one channel fetch at [epoch]. A stale epoch is dropped so an
  /// in-flight fetch that lands after an evict or forced resolve cannot
  /// resurrect the channel. Missing providers keep their retained list; the
  /// stored subs and 7TV identity are preserved.
  bool commitChannel(String channel, int epoch, ChannelEmoteFetch fetch) {
    if (epoch != channelEpoch(channel)) return false;
    // No provider lists and no 7TV identity: keep the retained lists, skip the
    // freshness stamp and emit, and report a retained catalog so the caller
    // can still refresh the persisted tier tag.
    if (fetch.byProvider.isEmpty &&
        fetch.sevenTvSetId == null &&
        fetch.sevenTvUserId == null) {
      return _channelCatalogs.containsKey(channel);
    }

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
            (e) => isTwitchSub(e) || _kindOf(e) == TwitchEmoteKind.follower,
          )
          .toList();
      catalog = catalog.copyWith(twitchSubs: [...subs, ...twitchNonSub]);
      _subsByChannelCache = null;
    }
    _channelCatalogs[channel] = catalog;
    // A fetched 7TV list is a full snapshot; deltas can now be stashed and
    // re-applied over later rebuilds.
    if (fetch.byProvider[EmoteType.sevenTv] != null) {
      _sevenTvFull.add(channel);
    }
    _reapplyLiveSevenTv(channel);
    _channelFetchTimes[channel] = DateTime.now();
    emitChange(channel: channel);
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

  /// Drops stale live 7TV deltas when a full fetched set is authoritative.
  void dropLiveSevenTv(String channel) {
    _sevenTvLive.remove(channel);
  }

  /// Stores owner-less emote-set results (per-account channel subs), fanning
  /// each owner list into its channel. Notifies only channels whose stored
  /// subscription list actually changed.
  void storeUserTwitchEmotes(Map<String, List<Emote>> perChannel) {
    final changedChannels = <String>[];
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
        if (!isTwitchSub(e) && (e.id.isEmpty || seen.add(e.id))) {
          merged.add(e);
        }
      }
      // Reconnect heals can restamp identical subscription data. Skip the
      // write and notification when nothing resolved differently.
      if (_sameSubs(existing, merged)) continue;
      _channelCatalogs[channel] = catalog.copyWith(twitchSubs: merged);
      changedChannels.add(channel);
    }
    if (changedChannels.isEmpty) return;
    _subsByChannelCache = null;
    changedChannels.sort();
    for (final channel in changedChannels) {
      emitChange(channel: channel);
    }
  }

  static bool _sameSubs(List<Emote> before, List<Emote> after) {
    if (identical(before, after)) return true;
    if (before.length != after.length) return false;
    for (var i = 0; i < before.length; i++) {
      if (!_sameSub(before[i], after[i])) return false;
    }
    return true;
  }

  static bool _sameSub(Emote before, Emote after) {
    return before.id == after.id &&
        before.code == after.code &&
        before.scope == after.scope &&
        _sameScales(before.scales, after.scales) &&
        before.isAnimated == after.isAnimated &&
        before.isZeroWidth == after.isZeroWidth &&
        _subMetaFingerprint(before.meta) == _subMetaFingerprint(after.meta);
  }

  static bool _sameScales(
    Map<EmoteScale, String> before,
    Map<EmoteScale, String> after,
  ) {
    if (before.length != after.length) return false;
    for (final entry in before.entries) {
      if (after[entry.key] != entry.value) return false;
    }
    return true;
  }

  static String _subMetaFingerprint(EmoteMeta meta) => switch (meta) {
    TwitchMeta(
      :final kind,
      :final subTier,
      :final ownerChannel,
      :final ownerId,
    ) =>
      'twitch:${kind.name}:$subTier:$ownerChannel:$ownerId',
    BttvMeta() => 'bttv',
    FfzMeta(:final ownerChannel) => 'ffz:$ownerChannel',
    SevenTvMeta(
      :final creator,
      :final baseName,
      :final unlisted,
      :final relativeScale,
      :final aspectRatio,
    ) =>
      'sevenTv:$creator:$baseName:$unlisted:$relativeScale:$aspectRatio',
  };

  /// Applies a 7TV WS delta in place. Returns the image URLs of removed
  /// emotes that are no longer referenced anywhere, for disk eviction by the
  /// caller. Emits a channel delta that does not advance [version].
  List<String> updateSevenTvEmotes(
    String channel, {
    List<Emote> added = const [],
    List<String> removedIds = const [],
    Map<String, ({String newName, String oldName})> renamed = const {},
  }) {
    final catalog = _channelCatalogs[channel];
    if (catalog == null && added.isEmpty) return const [];
    if (added.isEmpty && removedIds.isEmpty && renamed.isEmpty) {
      return const [];
    }

    final changedCodes = <String>{};
    final removedIdsWithUrls = <(String, List<String>)>[];

    if (catalog == null) {
      // No cache to diff against (not yet resolved, or evicted by a nuke).
      // Build a partial view so the delta's emotes render, but do NOT sync
      // it into the live view: one delta isn't the full set, and
      // _reapplyLiveSevenTv would propagate it over the next full fetch.
      _sevenTvFull.remove(channel);
      final sorted = List.of(added)..sort((a, b) => a.code.compareTo(b.code));
      _channelCatalogs[channel] = EmoteCatalog(sevenTvChannel: sorted);
      emitChange(
        channel: channel,
        deltaCodes: {for (final e in added) e.code},
        bumpVersion: false,
      );
      return const [];
    }

    // Diff against the channel-only merged view, then write the winning 7TV
    // entries back as the live list.
    final byCode = Map<String, Emote>.of(_channelLookup(channel).byCode);
    final codesById = <String, List<String>>{};
    for (final e in byCode.values) {
      if (e.type != EmoteType.sevenTv) continue;
      (codesById[e.id] ??= []).add(e.code);
    }

    for (final id in removedIds) {
      final codes = codesById.remove(id);
      if (codes == null) continue;
      for (final code in codes) {
        final e = byCode.remove(code);
        if (e == null) continue;
        changedCodes.add(code);
        removedIdsWithUrls.add((e.id, e.scales.values.toList()));
      }
    }

    for (final entry in renamed.entries) {
      final codes = codesById[entry.key];
      if (codes == null || codes.isEmpty) continue;
      final e = byCode[codes.first];
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
              (kEmoteProviderPriority[emote.type] ?? 99) <
                  (kEmoteProviderPriority[existing.type] ?? 99))) {
        continue;
      }
      byCode[emote.code] = emote;
      changedCodes.add(emote.code);
    }

    // Unknown removals/renames and duplicate adds can arrive as deltas.
    // Do not invalidate lookups or rebuild the id index for no-op events.
    if (changedCodes.isEmpty && removedIdsWithUrls.isEmpty) return const [];

    final live =
        byCode.values.where((e) => e.type == EmoteType.sevenTv).toList()
          ..sort((a, b) => a.code.compareTo(b.code));
    _channelCatalogs[channel] = catalog.copyWith(sevenTvChannel: live);
    // Only an authoritative (fully fetched) list may be stashed for re-apply;
    // a partial pre-fetch delta must not overwrite a later full fetch.
    if (_sevenTvFull.contains(channel)) {
      _sevenTvLive[channel] = live;
    }

    // Live deltas don't bump span version (no retroactive re-render).
    emitChange(channel: channel, deltaCodes: changedCodes, bumpVersion: false);

    // Shared 7TV emotes gone from all channels are evicted from disk. Rebuild
    // the id index once so the membership check is O(1) per removed id instead
    // of rescanning every catalog. Otherwise leave the lazy id lookup to the
    // next emoteById call.
    if (removedIdsWithUrls.isEmpty) return const [];
    _rebuildEmoteIndex();
    final unused = removedIdsWithUrls.where(
      (entry) => !_emoteIndex.containsKey(entry.$1),
    );
    return [for (final entry in unused) ...entry.$2];
  }

  // ── Eviction + account reset ────────────────────────────────────────
  void evictChannel(String channel) {
    // Keep the epoch entry so an in-flight fetch cannot match after eviction.
    _channelEpoch[channel] = (_channelEpoch[channel] ?? 0) + 1;
    _channelCatalogs.remove(channel);
    _channelFetchTimes.remove(channel);
    _emotesResolvedChannels.remove(channel);
    _subsByChannelCache = null;
    _sevenTvEmoteSetIds.remove(channel);
    _sevenTvUserIds.remove(channel);
    _mergedCache.remove(channel);
    _foreignLookupCache.remove(channel);
    _sevenTvLive.remove(channel);
    _sevenTvFull.remove(channel);
    _emoteIndexDirty = true;
  }

  void evictGlobal() {
    _globalEpoch++;
    _globalCatalog = EmoteCatalog();
    _globalAttempted = false;
    _mergedCache.clear();
    _foreignLookupCache.clear();
    _emoteIndexDirty = true;
  }

  /// Clears the catalog part of an account switch. [removedUnlockIds],
  /// [removedUnlockCodes], and [removedCatalogUnlockIds] describe the
  /// per-account Twitch entries the manager dropped, so they are pruned from
  /// the retained global Twitch list. Emits a global change.
  void clearAccountScopedState({
    Set<String> removedUnlockIds = const {},
    Set<String> removedUnlockCodes = const {},
    Set<String> removedCatalogUnlockIds = const {},
  }) {
    // Drop any in-flight commit from the old account on both scopes.
    _globalEpoch++;
    _channelEpochBase++;
    _emotesResolvedChannels.clear();
    _subsByChannelCache = null;
    bool prunesUnlock(Emote e) => e.id.isNotEmpty
        ? removedUnlockIds.contains(e.id) ||
              removedCatalogUnlockIds.contains(e.id)
        : removedUnlockCodes.contains(e.code);
    if (removedUnlockIds.isNotEmpty ||
        removedUnlockCodes.isNotEmpty ||
        removedCatalogUnlockIds.isNotEmpty) {
      _globalCatalog = _globalCatalog.withList(
        EmoteScope.global,
        EmoteType.twitch,
        _globalCatalog.twitchGlobal.where((e) => !prunesUnlock(e)).toList(),
      );
    }
    _channelCatalogs.clear();
    // Channel 7TV set ids are channel identity, not account identity, so they
    // stay for live delta routing; the 7TV user id is refreshed on re-resolve.
    _sevenTvUserIds.clear();
    _channelFetchTimes.clear();
    _sevenTvLive.clear();
    _sevenTvFull.clear();
    _mergedCache.clear();
    _foreignLookupCache.clear();
    emitChange(channel: null);
  }

  // ── 7TV identity + resolved flags ───────────────────────────────────
  void markEmotesResolved(String channel) {
    _emotesResolvedChannels.add(channel);
  }

  bool emotesResolved(String channel) =>
      _emotesResolvedChannels.contains(channel);

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
}
