import 'dart:convert';
import 'dart:isolate';

import '../emotes/emote.dart';
import '../emotes/emote_catalog.dart';
import '../models/emote_fetch_tier.dart';
import '../util/log.dart';
import '../util/prefs.dart';
import 'emote_meta_store.dart';
import 'seven_tv_personal_sets.dart';

/// File-backed persistence for the emote catalog: global and per-channel
/// provider lists, decoded off the main isolate on load.
///
/// Twitch subscriber lists never persist (they are per-account), and low/
/// nothing-tier caches persist Twitch lists too since those tiers do zero
/// network. Per-account unlocks are stripped before writing.
class EmotePersistence {
  EmotePersistence({
    required this._tier,
    required this._isAccountUnlock,
    EmoteMetaStore? metaStore,
  }) : _metaStore = metaStore ?? EmoteMetaStore.I;

  final EmoteFetchTier Function() _tier;
  final bool Function(String id) _isAccountUnlock;
  final EmoteMetaStore _metaStore;

  Prefs? _prefs;

  Future<Prefs> _getPrefs() async {
    _prefs ??= await Prefs.load();
    return _prefs!;
  }

  /// Loads a persisted catalog for [key], dropping subs and flagging whether
  /// the tier and TTL still match.
  Future<({EmoteCatalog? catalog, bool fresh})> load(
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
      final tierIndex = _tier().index;
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
      logDebug('[EmotePersistence] failed to parse cached emotes');
      return (catalog: null, fresh: false);
    }
  }

  // Persisted Twitch lists must never rehydrate another account's true subs.
  EmoteCatalog _dropSubs(EmoteCatalog catalog) => catalog.copyWith(
    twitchGlobal: catalog.twitchGlobal.where((e) => !isTwitchSub(e)).toList(),
    twitchChannel: catalog.twitchChannel.where((e) => !isTwitchSub(e)).toList(),
    twitchSubs: const [],
  );

  Future<void> save(String key, EmoteCatalog catalog, Duration ttl) async {
    // Low/nothing: persist Twitch too (zero network). Medium/high: non-Twitch
    // only. Per-account unlocks never persist.
    final persistTwitch =
        _tier() == EmoteFetchTier.low || _tier() == EmoteFetchTier.nothing;
    List<Emote> keepTwitch(List<Emote> emotes) {
      if (!persistTwitch) return const [];
      return emotes.where((e) {
        if (isTwitchSub(e)) return false;
        if (e.id.isNotEmpty && _isAccountUnlock(e.id)) return false;
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
        'tier': _tier().index,
        'emotes': saved.toJsonMap(),
      };
      await _metaStore.write(key, jsonEncode(data));
    } catch (_) {
      logDebug('[EmotePersistence] failed to save emotes to disk');
    }
  }

  /// Prunes persisted registries for left channels.
  Future<void> pruneStaleChannels(Set<String> activeChannels) async {
    try {
      for (final key in await _metaStore.keys()) {
        if (!key.startsWith('emotes5_')) continue;
        // Personal seeds are account-scoped, not channel-scoped.
        if (key == SevenTvPersonalSets.personalSetsKey) continue;
        final channel = key.substring('emotes5_'.length);
        if (channel.isEmpty || channel == 'global') continue;
        if (!activeChannels.contains(channel)) {
          await _metaStore.delete(key);
        }
      }
    } catch (e) {
      logDebug('[EmotePersistence] failed to prune stale channels: $e');
    }
  }

  /// Deletes all persisted emote metadata (global + per channel), including
  /// left channels. Used by the nuke action so the refetch rebuilds from the
  /// network instead of reseeding from disk. The personal-set seed is not
  /// catalog metadata and is left alone.
  Future<void> wipePersisted() async {
    try {
      for (final key in await _metaStore.keys()) {
        if (key == SevenTvPersonalSets.personalSetsKey) continue;
        if (key.startsWith('emotes5_') ||
            key.startsWith('emotes4_') ||
            key.startsWith('emotes3_')) {
          await _metaStore.delete(key);
        }
      }
    } catch (e) {
      logDebug('[EmotePersistence] failed to wipe persisted emotes: $e');
    }
  }
}
