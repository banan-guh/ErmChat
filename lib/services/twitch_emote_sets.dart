import 'dart:async';

import '../emotes/emote.dart';
import '../models/emote_fetch_tier.dart';
import '../util/log.dart';
import 'emote_fetcher.dart';
import 'emote_store.dart';
import 'twitch_auth.dart';

/// Twitch per-account emotes from Helix `chat/emotes/user`: subscriber,
/// follower and bits emotes plus owner-less unlocks (Prime/Turbo/2FA/Hype
/// Train/limited-time globals).
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

  // The account's emotes are fetched once per account; later loads only
  // re-attach them to newly joined channels.
  bool _fetched = false;
  bool _inflight = false;
  // Token the fetch ran with: a re-login (new scopes, same account) refetches.
  String? _fetchedToken;
  // Bumped by an account reset, so a fetch started for the previous account
  // drops its results instead of storing them under the new one.
  int _account = 0;
  // owner id -> login, built up across resolves and reused between reconnects.
  final Map<String, String> _emoteOwnerLogins = {};
  // Last fetched locked user emote sets keyed by owner id. Kept in memory
  // so a reconnect can re-stamp resolved logins and re-store without
  // re-fetching. Word-matchable grants bypass this cache for the global
  // unlock overlay instead.
  final Map<String, List<Emote>> _fetchedSubEmotesByOwner = {};
  // Owner-less Twitch unlocks from the user emotes fetch (per-account
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
  bool get subEmoteFetchInFlight => _inflight;

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

  /// Loads the account's Twitch emotes once, then on later calls only
  /// re-attaches them to channels joined since (owner logins healed).
  Future<void> loadUserEmotes(
    TwitchAuth auth,
    Map<String, String> openChannelUserIds,
  ) async {
    if (_tier() == EmoteFetchTier.nothing) return;
    // Anonymous has no account emotes, and no user id would ever arrive.
    if (auth.accessToken == null) return;
    if (_fetched && _fetchedToken != auth.accessToken) _fetched = false;
    if (_fetched || _inflight) {
      final channels = _openChannels(openChannelUserIds);
      await _resolveOwners(auth, channels);
      await _reStoreCachedSubs(channels);
      return;
    }
    _inflight = true;
    final account = _account;
    // Subs tab spins (not empty-text) while the fetch below is in flight.
    // Rendered rows ignore the emit; live surfaces re-read.
    _store.notifyCatalogChanged();
    try {
      // A fresh login joins channels before its identity resolves; wait for
      // it rather than skip, since nothing else retries the fetch.
      final userId = auth.userId ?? await _awaitUserId(auth);
      if (userId == null || userId.isEmpty) return;
      final byOwner = await _fetcher.fetchUserEmotes(
        userId,
        accessToken: auth.accessToken,
      );
      if (account != _account) return;
      final perOwner = <String, List<Emote>>{};
      final unlocked = <Emote>[];
      // A refetch replaces the cache, so lapsed subs drop out.
      _fetchedSubEmotesByOwner.clear();
      for (final entry in byOwner.entries) {
        if (entry.key.isEmpty) {
          // Owner-less sets are global unlocks, not channel subs.
          unlocked.addAll(entry.value);
        } else {
          // Status-gated emotes fan out per channel; word-matchable grants
          // are account unlocks usable everywhere and join the global
          // overlay instead, stamped global so no channel tab claims them.
          final owned = <Emote>[];
          for (final e in entry.value) {
            if (EmoteStore.isTwitchLocked(e)) {
              owned.add(e);
            } else {
              unlocked.add(
                e.scope == EmoteScope.channel
                    ? e.copyWith(scope: EmoteScope.global)
                    : e,
              );
            }
          }
          if (owned.isNotEmpty) {
            perOwner[entry.key] = owned;
            _fetchedSubEmotesByOwner[entry.key] = owned;
          }
        }
      }
      if (unlocked.isNotEmpty) _storeUnlockedGlobalEmotes(unlocked);
      _fetched = true;
      _fetchedToken = auth.accessToken;
      if (perOwner.isEmpty) {
        return;
      }
      final channels = _openChannels(openChannelUserIds);
      await _resolveOwners(auth, channels, ownerIds: perOwner.keys);
      final targets = channels.keys.toList();
      if (targets.isEmpty || account != _account) {
        return;
      }
      final perChannel = _buildPerChannelEmotes(perOwner, targets);
      await storeUserTwitchEmotes(perChannel);
    } catch (e) {
      logDebug('loadUserEmotes failed: $e');
    } finally {
      // A failed fetch leaves _fetched false, so the next load retries. A
      // stale fetch leaves the flag to the new account's.
      if (account == _account) _inflight = false;
    }
  }

  // Pending wait for the user id; an account reset releases it with null.
  Completer<String?>? _userIdWaiter;

  Future<String?> _awaitUserId(TwitchAuth auth) {
    final done = _userIdWaiter = Completer<String?>();
    void check() {
      final id = auth.userId;
      if (id != null && id.isNotEmpty && !done.isCompleted) done.complete(id);
    }

    auth.addListener(check);
    return done.future.whenComplete(() {
      auth.removeListener(check);
      if (identical(_userIdWaiter, done)) _userIdWaiter = null;
    });
  }

  /// Re-fetches the account's emotes (manual emote reload).
  Future<void> reloadUserEmotes(
    TwitchAuth auth,
    Map<String, String> openChannelUserIds,
  ) async {
    if (_tier() == EmoteFetchTier.nothing || _inflight) return;
    _fetched = false;
    await loadUserEmotes(auth, openChannelUserIds);
  }

  /// Clears per-account emote state (account switch). Unlocks are per-account:
  /// they are dropped from the global Twitch list they merged into, matched by
  /// id plus by code for empty-id entries.
  void resetUserEmoteState() {
    _account++;
    _fetched = false;
    _inflight = false;
    final waiter = _userIdWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete(null);
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
          // Follower emotes only work in their home channel; subs and bits
          // are usable everywhere.
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
