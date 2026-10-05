import 'dart:convert';

import '../emotes/emote.dart';
import '../emotes/emote_catalog.dart';
import '../util/log.dart';
import 'emote_meta_store.dart';
import 'emote_providers/ffz_emotes.dart';

/// FFZ global sets granted to named users (the supporter effect emotes),
/// resolved per sender login. Persisted because a fresh global cache skips
/// the fetch that carries them.
class FfzUserEmotes {
  FfzUserEmotes({EmoteMetaStore? metaStore})
    : _metaStore = metaStore ?? EmoteMetaStore.I;

  /// Channel pruning skips this key (see [EmotePersistence]).
  static const storeKey = 'emotes5_ffz_user_sets';

  final EmoteMetaStore _metaStore;
  FfzUserSets _sets = const FfzUserSets();

  /// True once sets were fetched or restored, even when FFZ granted none.
  bool get known => _known;
  bool _known = false;

  // Lookups per set combination and per sender 7TV lookup, so callers that
  // cache on lookup identity keep hitting. Rebuilt on every apply.
  var _lookups = <String, EmoteLookup>{};
  var _merged = Expando<Map<EmoteLookup, EmoteLookup>>();

  /// [login]'s granted emotes, null when they have none.
  EmoteLookup? lookupFor(String? login) {
    if (login == null || _sets.isEmpty) return null;
    final lower = login.toLowerCase();
    final ids = [
      for (final entry in _sets.logins.entries)
        if (entry.value.contains(lower)) entry.key,
    ];
    if (ids.isEmpty) return null;
    return _lookups.putIfAbsent(ids.join(','), () {
      final byCode = <String, Emote>{};
      for (final id in ids) {
        for (final e in _sets.emotes[id] ?? const <Emote>[]) {
          byCode.putIfAbsent(e.code, () => e);
        }
      }
      final suggestions = byCode.values.toList()
        ..sort((a, b) => a.code.compareTo(b.code));
      return EmoteLookup(byCode: byCode, suggestions: suggestions);
    });
  }

  /// [foreign] (the sender's personal 7TV lookup) plus [login]'s FFZ sets.
  /// The same inputs return the same object.
  EmoteLookup? withSender(EmoteLookup? foreign, String? login) {
    final own = lookupFor(login);
    if (own == null) return foreign;
    if (foreign == null) return own;
    final byOwn = _merged[foreign] ??= {};
    return byOwn.putIfAbsent(own, () {
      final byCode = {...own.byCode, ...foreign.byCode};
      final suggestions = byCode.values.toList()
        ..sort((a, b) => a.code.compareTo(b.code));
      return EmoteLookup(byCode: byCode, suggestions: suggestions);
    });
  }

  /// Replaces the sets from a global fetch and persists them.
  Future<void> apply(FfzUserSets sets) async {
    // A partial and a final commit carry the same fetch.
    if (identical(sets, _sets)) return;
    _set(sets);
    try {
      await _metaStore.write(
        storeKey,
        jsonEncode({
          for (final id in sets.emotes.keys)
            id: {
              'logins': sets.logins[id]?.toList() ?? const <String>[],
              'emotes': [for (final e in sets.emotes[id]!) e.toJson()],
            },
        }),
      );
    } catch (_) {
      logDebug('[FfzUserEmotes] failed to save user sets');
    }
  }

  /// Restores persisted sets unless a fetch already landed.
  Future<void> loadPersisted() async {
    if (_known) return;
    try {
      final raw = await _metaStore.read(storeKey);
      if (raw == null || _known) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final logins = <String, Set<String>>{};
      final emotes = <String, List<Emote>>{};
      for (final entry in data.entries) {
        final set = entry.value as Map<String, dynamic>;
        logins[entry.key] = {
          for (final login in set['logins'] as List<dynamic>) login as String,
        };
        emotes[entry.key] = [
          for (final e in set['emotes'] as List<dynamic>)
            Emote.fromJson(e as Map<String, dynamic>),
        ];
      }
      _set(FfzUserSets(logins: logins, emotes: emotes));
    } catch (_) {
      logDebug('[FfzUserEmotes] failed to load user sets');
    }
  }

  void _set(FfzUserSets sets) {
    _sets = sets;
    _known = true;
    _lookups = {};
    _merged = Expando();
  }
}
