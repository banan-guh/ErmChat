import '../emotes/emote.dart';
import '../models/emote_fetch_tier.dart';
import '../util/log.dart';
import 'emote_fetcher.dart';
import 'emote_store.dart';
import 'twitch_auth.dart';

/// Twitch per-account emote sets: subscriber emotes granted by the IRC
/// emote-sets path plus owner-less unlocks (Prime/Turbo/2FA/Hype Train).
///
/// Owns the fetch bookkeeping (fetched ids, in-flight ids, owner logins) and
/// fans resolved subscriber emotes into the store's per-channel lists.
class TwitchEmoteSets {
  TwitchEmoteSets({
    required this._fetcher,
    required this._store,
    required this._tier,
    this.getChannelUserIds,
  });

  final EmoteFetcher _fetcher;
  final EmoteStore _store;
  final EmoteFetchTier Function() _tier;

  /// Live open-channel -> broadcaster-id source, injected by the app layer and
  /// read at store time. Late-resolving ids must still receive fetched subs;
  /// null in unit tests, which pass explicit maps instead.
  final Map<String, String> Function()? getChannelUserIds;

  String? accessToken;

  // Emote-set ids already fetched via the IRC emote-sets path, so repeated
  // USERSTATE (per channel join / message send) doesn't refetch them.
  final Set<String> _fetchedEmoteSetIds = {};
  // Set ids currently in flight; dropped on failure so the next event retries.
  final Set<String> _inflightEmoteSetIds = {};
  // owner id -> login, built up across resolves and reused between reconnects.
  final Map<String, String> _emoteOwnerLogins = {};
  // Last fetched user sub-emote sets keyed by owner id. Kept in memory so a
  // reconnect can re-stamp resolved logins and re-store without re-fetching.
  final Map<String, List<Emote>> _fetchedSubEmotesByOwner = {};
  // Owner-less Twitch unlocks from the IRC emote-sets path (per-account
  // Prime/Turbo/2FA/Hype Train emotes). Merged into the global lookup.
  final _unlockedTwitchEmotes = <String, Emote>{};
  // Ids from the global unlockable catalogue (broadcaster_id=0). Per-account
  // like the emote-set unlocks, so excluded from disk and pruned on reset.
  final _twitchCatalogUnlockIds = <String>{};

  /// Per-account owner-less unlocks for the global lookup overlay.
  Iterable<Emote> get unlockedEmotes => _unlockedTwitchEmotes.values;

  bool isAccountUnlocked(String id) => _unlockedTwitchEmotes.containsKey(id);

  bool isCatalogUnlocked(String id) => _twitchCatalogUnlockIds.contains(id);

  /// Whether a subscriber-emote fetch is currently in flight. The subs tab
  /// shows a spinner (not the empty text) while true, so a slow fetch never
  /// reads as "no subscriber emotes".
  bool get subEmoteFetchInFlight => _inflightEmoteSetIds.isNotEmpty;

  /// Applies the account catalogue unlock ids from a global fetch. Empty
  /// leaves the retained ids untouched.
  void applyCatalogUnlockIds(Set<String> ids) {
    if (ids.isEmpty) return;
    _twitchCatalogUnlockIds
      ..clear()
      ..addAll(ids);
  }

  /// Drops the global unlock overlays (global evict / account reset).
  void clearUnlocks() {
    _unlockedTwitchEmotes.clear();
    _twitchCatalogUnlockIds.clear();
  }

  Future<void> storeUserTwitchEmotes(
    Map<String, List<Emote>> perChannel,
  ) async {
    if (_tier() == EmoteFetchTier.nothing) return;
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
    if (_tier() == EmoteFetchTier.nothing) return;
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
    // Rendered rows ignore the emit; live surfaces re-read.
    _store.notifyCatalogChanged();
    try {
      final byOwner = await _fetcher.fetchUserEmoteSets(
        newSetIds,
        accessToken: auth.accessToken,
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

  /// Re-fetches subscriber emotes for the ids already known from a prior
  /// USERSTATE/GLOBALUSERSTATE. The manual emote reload would otherwise drop
  /// subs until the next IRC USERSTATE arrives, so call this from that path.
  Future<void> reloadUserEmoteSets(
    TwitchAuth auth,
    Map<String, String> openChannelUserIds,
  ) async {
    if (_tier() == EmoteFetchTier.nothing) return;
    if (_fetchedEmoteSetIds.isEmpty) return;
    final ids = _fetchedEmoteSetIds.toList();
    _fetchedEmoteSetIds.clear();
    await loadUserEmoteSets(ids, auth, openChannelUserIds);
  }

  /// Clears per-account emote state (account switch). Unlocks are per-account:
  /// they are dropped from the global Twitch list they merged into, matched by
  /// id plus by code for empty-id entries.
  void resetUserEmoteState() {
    _fetchedEmoteSetIds.clear();
    _inflightEmoteSetIds.clear();
    _emoteOwnerLogins.clear();
    _fetchedSubEmotesByOwner.clear();
    final removedIds = <String>{..._unlockedTwitchEmotes.keys};
    final removedCodes = <String>{
      for (final e in _unlockedTwitchEmotes.values) e.code,
    };
    final removedCatalogIds = <String>{..._twitchCatalogUnlockIds};
    clearUnlocks();
    _store.clearAccountScopedState(
      removedUnlockIds: removedIds,
      removedUnlockCodes: removedCodes,
      removedCatalogUnlockIds: removedCatalogIds,
    );
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
    _store.notifyCatalogChanged();
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
              scales: e.scales,
              isAnimated: e.isAnimated,
              isZeroWidth: e.isZeroWidth,
              scope: e.scope,
            ),
          );
        }
      }
      perChannel[target] = list;
    }
    return perChannel;
  }
}
