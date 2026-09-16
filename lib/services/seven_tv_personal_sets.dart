import 'dart:async';
import 'dart:convert';

import '../emotes/emote.dart';
import '../emotes/emote_catalog.dart';
import '../models/emote_fetch_tier.dart';
import '../util/log.dart';
import 'emote_fetcher.dart';
import 'emote_meta_store.dart';
import 'seven_tv_event_client.dart';

/// 7TV personal emote sets: the viewer's own grants and other viewers'
/// (foreign) grants learned from the socket.
///
/// Viewer sets merge everywhere for the active account; foreign sets are
/// sender-scoped, so only their owner's messages render them. Metadata only
/// (codes and URLs); image bytes stay centralized by URL in the image module,
/// so a personal emote shared with a channel set decodes once.
///
/// Persistence is a long-lived cold-start seed, not a source of truth: the
/// socket corrects the sets live.
class SevenTvPersonalSets {
  SevenTvPersonalSets({
    required this._fetcher,
    required this._metaStore,
    required this._tier,
    required bool Function(EmoteType) isProviderEnabled,
    required this._notifyChanged,
    DateTime Function()? now,
    String? Function()? viewerTwitchIdSource,
  }) : _isProviderOn = isProviderEnabled,
       _viewerIdSource = viewerTwitchIdSource,
       _now = now ?? DateTime.now;

  final EmoteFetcher _fetcher;
  final EmoteMetaStore _metaStore;
  final EmoteFetchTier Function() _tier;
  final bool Function(EmoteType) _isProviderOn;
  final void Function() _notifyChanged;
  final DateTime Function() _now;

  /// Live account-id source, read when no explicit id was set. Wired by the
  /// app layer; null in unit tests, which set the id through the manager.
  final String? Function()? _viewerIdSource;

  // Viewer Twitch user id; personal 7TV grants are matched against it.
  String? _viewerTwitchId;

  // Owned 7TV set ids and their merged emotes (personal grants, usable in
  // every channel). Kept out of the persisted caches; rebuilt per account.
  final _personalSevenTvSetIds = <String>{};
  final _personalSevenTvSets = <String, List<Emote>>{};

  // Other viewers' personal 7TV sets, learned from the socket (chatterino7
  // parity): entitlement.create maps users to sets, emote_set.* fills the
  // contents. Sender-scoped: only that sender's messages render them. No
  // per-sender REST; unknown set contents fetch once per set id. Foreign sets
  // are sparse (seen only when their owner chats), so the 50-entry LRU below
  // needs no churn handling.
  final _foreignPersonalSetOwners = <String, Set<String>>{};
  final _foreignPersonalUserSets = <String, Set<String>>{};
  final _foreignPersonalSetContents = <String, List<Emote>>{};
  final _foreignPersonalSetInflight = <String, Future<void>>{};
  final _foreignPersonalSets = <String, EmoteLookup>{};
  // Sets announced over the socket before their contents arrive. Tracked so
  // the cap counts them, and distinguished from a filled set so a later grant
  // can still trigger the REST fill.
  final _foreignPlaceholderSets = <String>{};
  // Unmapped sets render for nobody; bound the contents map.
  // Eviction is least-recently-touched first (insertion order doubles as
  // recency: touches reinsert). Render lookups never touch; too hot.
  static const _maxForeignPersonalSets = 50;

  // Bumped on reset so an in-flight foreign fill that lands afterwards is
  // dropped instead of repopulating cleared state.
  int _generation = 0;

  // Personal sets change rarely and the socket corrects them live, so the
  // disk copy is a long-lived cold-start seed (not a source of truth).
  static const personalSetsKey = 'emotes5_personal_sets';
  static const _personalSetsTtl = Duration(days: 30);

  /// Viewer Twitch user id for matching personal 7TV grants. Clears viewer
  /// sets on change so the old account's emotes never leak.
  set viewerTwitchId(String? value) {
    if (viewerTwitchId == value) return;
    _viewerTwitchId = value;
    _personalSevenTvSetIds.clear();
    _personalSevenTvSets.clear();
    _notifyChanged();
  }

  String? get viewerTwitchId => _viewerTwitchId ?? _viewerIdSource?.call();

  /// Viewer personal 7TV emotes in merge order (first set wins conflicts).
  Iterable<Emote> get viewerEmotes sync* {
    for (final setEmotes in _personalSevenTvSets.values) {
      yield* setEmotes;
    }
  }

  /// Sender-scoped personal lookup, null when [senderTwitchId] has none.
  EmoteLookup? foreignFor(String? senderTwitchId) =>
      senderTwitchId == null ? null : _foreignPersonalSets[senderTwitchId];

  /// Bootstrap: fetch the viewer's owned 7TV sets and their emotes.
  /// Restores the persisted seed first so known sets skip the network.
  Future<void> loadViewerPersonalSevenTvSets({bool force = false}) async {
    await loadPersisted();
    final viewerId = viewerTwitchId;
    if (viewerId == null || viewerId.isEmpty) return;
    if (_tier() == EmoteFetchTier.nothing) return;
    if (!_isProviderOn(EmoteType.sevenTv)) return;
    // Tier upgrade: known set ids would skip the refetch below and keep
    // the old resolution, so forget them and re-pull. Map entries stay
    // until replaced, so a failed fetch keeps the old URLs.
    if (force) _personalSevenTvSetIds.clear();
    List<String> setIds;
    try {
      setIds = await _fetcher.fetchSevenTvOwnedSetIds(viewerId);
    } catch (e) {
      logDebug('[SevenTvPersonalSets] personal 7TV set listing failed: $e');
      return;
    }
    var changed = false;
    for (final setId in setIds) {
      if (_personalSevenTvSetIds.contains(setId)) continue;
      List<Emote> emotes;
      try {
        emotes = await _fetcher.fetchSevenTvEmoteSet(setId);
      } catch (e) {
        logDebug('[SevenTvPersonalSets] personal 7TV set $setId failed: $e');
        continue;
      }
      _personalSevenTvSetIds.add(setId);
      _personalSevenTvSets[setId] = emotes;
      changed = true;
    }
    if (changed) {
      _notifyChanged();
      unawaited(_save());
    }
  }

  /// Live personal 7TV grant/revoke from the entitlement stream. The
  /// viewer's own EMOTE_SET events feed the personal merge; everyone else's
  /// feed the socket-first foreign discovery (chatterino7 parity, no
  /// per-sender REST).
  Future<void> applyEntitlement(SevenTvEntitlementEvent event) async {
    if (event.cosmeticKind != 'EMOTE_SET') return;
    final viewerId = viewerTwitchId;
    if (viewerId == null || !event.twitchUserIds.contains(viewerId)) {
      if (event.kind == 'entitlement.delete') {
        dropForeignGrant(event.twitchUserIds, event.cosmeticId);
      } else {
        await trackForeignGrant(event.twitchUserIds, event.cosmeticId);
      }
      return;
    }
    if (_tier() == EmoteFetchTier.nothing) return;
    if (!_isProviderOn(EmoteType.sevenTv)) return;
    if (event.kind == 'entitlement.delete') {
      final hadSet = _personalSevenTvSetIds.remove(event.cosmeticId);
      final hadEmotes = _personalSevenTvSets.remove(event.cosmeticId) != null;
      if (hadSet || hadEmotes) {
        _notifyChanged();
        unawaited(_save());
      }
      return;
    }
    if (_personalSevenTvSetIds.contains(event.cosmeticId)) return;
    List<Emote> emotes;
    try {
      emotes = await _fetcher.fetchSevenTvEmoteSet(event.cosmeticId);
    } catch (e) {
      logDebug('[SevenTvPersonalSets] personal 7TV grant fetch failed: $e');
      return;
    }
    _personalSevenTvSetIds.add(event.cosmeticId);
    _personalSevenTvSets[event.cosmeticId] = emotes;
    _notifyChanged();
    unawaited(_save());
  }

  /// Maps foreign users to a personal set from a socket entitlement grant.
  /// Unknown set contents fetch once per set id (shared by all owners).
  Future<void> trackForeignGrant(
    Iterable<String> userTwitchIds,
    String setId,
  ) async {
    if (setId.isEmpty) return;
    var mappingChanged = false;
    for (final userId in userTwitchIds) {
      if (userId.isEmpty) continue;
      // The viewer's own grants live in the viewer sets, never here.
      if (userId == viewerTwitchId) continue;
      if (_foreignPersonalUserSets.putIfAbsent(userId, () => {}).add(setId)) {
        mappingChanged = true;
      }
      _foreignPersonalSetOwners.putIfAbsent(setId, () => {}).add(userId);
    }
    _touchForeignSet(setId);
    if (_foreignPersonalSetContents.containsKey(setId) &&
        !_foreignPlaceholderSets.contains(setId)) {
      if (mappingChanged) {
        _rebuildForeignUsers(setId);
        _notifyChanged();
      }
      return;
    }
    if (mappingChanged) _rebuildForeignUsers(setId);
    await _fillForeignSet(setId);
    unawaited(_save());
  }

  /// Drops a foreign user's personal-set grant (entitlement.delete).
  void dropForeignGrant(Iterable<String> userTwitchIds, String setId) {
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
        _rebuildForeignUser(userId);
      }
    }
    final owners = _foreignPersonalSetOwners[setId];
    if (owners != null) {
      owners.removeAll(userTwitchIds);
      if (owners.isEmpty) {
        _foreignPersonalSetOwners.remove(setId);
        _foreignPersonalSetContents.remove(setId);
        _foreignPlaceholderSets.remove(setId);
      }
    }
    if (changed) {
      _notifyChanged();
      unawaited(_save());
    }
  }

  // Marks a live set recently used. Placeholders stay put; only live sets
  // move, so untouched empties are evicted first.
  void _touchForeignSet(String setId) {
    final contents = _foreignPersonalSetContents[setId];
    if (contents == null || contents.isEmpty) return;
    _foreignPersonalSetContents.remove(setId);
    _foreignPersonalSetContents[setId] = contents;
  }

  // Drops a set nobody references (revoked or over the cap).
  void _evictForeignSet(String setId) {
    _foreignPersonalSetOwners.remove(setId);
    _foreignPersonalSetContents.remove(setId);
    _foreignPlaceholderSets.remove(setId);
    for (final userId in _foreignPersonalUserSets.keys.toList()) {
      final sets = _foreignPersonalUserSets[userId];
      if (sets == null) continue;
      if (!sets.remove(setId)) continue;
      if (sets.isEmpty) {
        _foreignPersonalUserSets.remove(userId);
        _foreignPersonalSets.remove(userId);
      } else {
        _rebuildForeignUser(userId);
      }
    }
  }

  // Shared insert for placeholders and filled sets: reinserts (recency) and
  // evicts down to the cap so neither path can exceed it.
  void _putForeignSet(String setId, List<Emote> contents) {
    _foreignPersonalSetContents.remove(setId);
    _foreignPersonalSetContents[setId] = contents;
    while (_foreignPersonalSetContents.length > _maxForeignPersonalSets) {
      _evictForeignSet(_foreignPersonalSetContents.keys.first);
    }
  }

  /// Placeholder for a personal set announced over the socket whose contents
  /// arrive via later emote_set.update dispatches.
  void trackSet(String setId) {
    if (setId.isEmpty) return;
    if (_foreignPersonalSetContents.containsKey(setId)) return;
    _foreignPlaceholderSets.add(setId);
    _putForeignSet(setId, <Emote>[]);
  }

  /// Applies a socket emote_set.update to a tracked foreign personal set.
  /// Unknown sets are ignored: without a grant mapping the contents render
  /// for nobody.
  void applyForeignSetUpdate({
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
    _foreignPlaceholderSets.remove(setId);
    _touchForeignSet(setId);
    _rebuildForeignUsers(setId);
    _notifyChanged();
    unawaited(_save());
  }

  /// One-time REST fill for a socket-announced set. Once per set id, shared
  /// by all owners; failures stay uncached so a later grant retries.
  Future<void> _fillForeignSet(String setId) async {
    final filled =
        _foreignPersonalSetContents.containsKey(setId) &&
        !_foreignPlaceholderSets.contains(setId);
    if (filled) return;
    if (_tier() == EmoteFetchTier.nothing) return;
    if (!_isProviderOn(EmoteType.sevenTv)) return;
    if (_foreignPersonalSetInflight.containsKey(setId)) return;
    final generation = _generation;
    final future = () async {
      List<Emote> fetched;
      try {
        fetched = await _fetcher.fetchSevenTvEmoteSet(setId);
      } catch (e) {
        logDebug('[SevenTvPersonalSets] foreign 7TV set $setId failed: $e');
        return;
      }
      // A reset cleared this state while the fetch was in flight.
      if (generation != _generation) return;
      if (fetched.isEmpty) return;
      _foreignPlaceholderSets.remove(setId);
      _putForeignSet(setId, fetched);
      _rebuildForeignUsers(setId);
      _notifyChanged();
    }();
    _foreignPersonalSetInflight[setId] = future;
    try {
      await future;
    } finally {
      if (identical(_foreignPersonalSetInflight[setId], future)) {
        _foreignPersonalSetInflight.remove(setId);
      }
    }
  }

  void _rebuildForeignUsers(String setId) {
    final owners = _foreignPersonalSetOwners[setId];
    if (owners == null) return;
    for (final userId in owners) {
      _rebuildForeignUser(userId);
    }
  }

  void _rebuildForeignUser(String userId) {
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

  Future<void> flushForTest() => _save();

  int get foreignSetCount => _foreignPersonalSetContents.length;

  /// Clears viewer and foreign personal state (account switch).
  void reset() {
    _generation++;
    _personalSevenTvSetIds.clear();
    _personalSevenTvSets.clear();
    _foreignPersonalSetOwners.clear();
    _foreignPersonalUserSets.clear();
    _foreignPersonalSetContents.clear();
    _foreignPersonalSetInflight.clear();
    _foreignPlaceholderSets.clear();
    _foreignPersonalSets.clear();
  }

  Future<void> _save() async {
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
        await _metaStore.delete(personalSetsKey);
        return;
      }
      await _metaStore.write(
        personalSetsKey,
        jsonEncode({
          'ts': _now().toIso8601String(),
          'viewerId': viewerTwitchId,
          'viewer': viewer,
          'foreignOwners': owners,
          'foreign': foreign,
        }),
      );
    } catch (_) {
      logDebug('[SevenTvPersonalSets] failed to save personal sets');
    }
  }

  /// Restores persisted personal sets. Viewer sets apply only to the matching
  /// account; foreign sets apply to everyone. Never overwrites live data:
  /// only unknown set ids are filled.
  Future<void> loadPersisted() async {
    try {
      final raw = await _metaStore.read(personalSetsKey);
      if (raw == null) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final ts = DateTime.tryParse(data['ts'] as String? ?? '');
      if (ts == null || _now().difference(ts) > _personalSetsTtl) {
        await _metaStore.delete(personalSetsKey);
        return;
      }
      var changed = false;
      final viewerId = viewerTwitchId;
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
        final placeholder = _foreignPlaceholderSets.contains(entry.key);
        if (_foreignPersonalSetContents.containsKey(entry.key) &&
            !placeholder) {
          continue;
        }
        final emotes = _decodeEmoteList(entry.value);
        if (emotes.isEmpty) continue;
        final setOwners = (owners[entry.key] as List<dynamic>? ?? [])
            .whereType<String>()
            .where((u) => u.isNotEmpty && u != viewerId)
            .toSet();
        if (setOwners.isEmpty) continue;
        _foreignPlaceholderSets.remove(entry.key);
        _foreignPersonalSetContents[entry.key] = emotes;
        _foreignPersonalSetOwners[entry.key] = setOwners;
        for (final userId in setOwners) {
          _foreignPersonalUserSets.putIfAbsent(userId, () => {}).add(entry.key);
        }
        _rebuildForeignUsers(entry.key);
        changed = true;
      }
      if (changed) _notifyChanged();
    } catch (_) {
      logDebug('[SevenTvPersonalSets] failed to load personal sets');
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
}
