import 'dart:convert';

import '../archive/set_log.dart';
import '../emotes/emote.dart';
import '../emotes/emote_catalog.dart';
import '../models/twitch_badge.dart';
import '../util/log.dart';
import 'archive_store.dart';

/// Which emotes a read hides, like the live lookup: disabled providers and,
/// unless allowed, unlisted 7TV emotes.
typedef EmoteVisibilityRule = ({Set<EmoteType> disabled, bool allowUnlisted});

/// What each emote and badge set held over time, one [SetLog] per set,
/// recorded from fetches and read back so archived chat shows the emotes
/// and badges of its time.
class SetHistory {
  SetHistory(this.store);

  final Future<ArchiveStore?> store;

  static const emoteKind = 'emote';
  static const badgeKind = 'badge';
  static const _badgeSource = 'twitch';
  static const _providers = [EmoteType.bttv, EmoteType.ffz, EmoteType.sevenTv];

  /// Lookups and badge tables kept for reuse; rows of one stretch of chat
  /// share them.
  static const _cacheSize = 8;

  /// The live provider toggles, which reads apply over the history.
  EmoteVisibilityRule Function() visibility = _showAll;

  static EmoteVisibilityRule _showAll() =>
      (disabled: const {}, allowUnlisted: true);

  /// Key of [e]'s definition: provider, id and code, so a renamed alias
  /// stays its own version.
  static String emoteKey(Emote e) => '${e.type.name}:${e.id}:${e.code}';

  final Map<String, Future<SetLog>> _logs = {};
  Future<void> _observing = Future.value();

  // Decoded definitions by scope and key, shared by every lookup.
  final Map<String, Emote> _emotes = {};
  final Map<String, Map<String, Emote>> _lookups = {};
  final Map<String, Map<String, BadgeVersion>> _badges = {};

  Future<SetLog> _log(ArchiveStore s, String kind, String scope, String src) =>
      _logs['$kind|$scope|$src'] ??= s
          .observations(kind, scope, src)
          .then(SetLog.new);

  /// Notes that a fetch of one set returned [items], key to definition
  /// JSON, at [at] (now by default). An empty result is skipped: it cannot
  /// be told from a broken fetch, and the next one settles it. Never throws.
  Future<void> observe(
    String kind,
    String scope,
    String source,
    Map<String, String> items, {
    DateTime? at,
  }) => _observeWith(kind, scope, source, (_) => items, at);

  Future<void> _observeWith(
    String kind,
    String scope,
    String source,
    Map<String, String> Function(Map<String, String> latest) build,
    DateTime? at,
  ) {
    final atMs = (at ?? DateTime.now()).millisecondsSinceEpoch;
    return _observing = _observing.then((_) async {
      try {
        final s = await store;
        if (s == null) return;
        final log = await _log(s, kind, scope, source);
        final rows = log.rows;
        if (rows.isNotEmpty && atMs <= rows.last.atMs) return;
        final items = build(log.latest);
        if (items.isEmpty) return;
        final o = log.diff(items, atMs);
        if (o == null) {
          await s.touchObservation(kind, scope, source, rows.last.atMs, atMs);
          log.touch(atMs);
          return;
        }
        await s.addObservation(kind, scope, source, o);
        log.add(o);
      } catch (e) {
        logDebug('[SetHistory] write failed: $e');
      }
    });
  }

  /// One set as observed at [at]: key to definition JSON.
  Future<Map<String, String>> observedAt(
    String kind,
    String scope,
    String source,
    DateTime at,
  ) async {
    await _observing;
    final s = await store;
    if (s == null) return const {};
    return (await _log(s, kind, scope, source)).at(at.millisecondsSinceEpoch);
  }

  /// A fetch of [provider]'s emotes for [scope] ('' for global). Twitch
  /// emotes are left out: rows keep their positions.
  Future<void> observeEmotes(
    String scope,
    EmoteType provider,
    Iterable<Emote> emotes, {
    DateTime? at,
  }) {
    if (provider == EmoteType.twitch) return Future.value();
    return observe(emoteKind, scope, provider.name, {
      for (final e in emotes) emoteKey(e): jsonEncode(e.toJson()),
    }, at: at);
  }

  /// A 7TV live change to [channel]'s set, applied over the last observed
  /// one. Without one there is nothing to apply it to, so it waits for the
  /// next fetch.
  Future<void> observeSevenTvDelta(
    String channel, {
    List<Emote> added = const [],
    List<String> removedIds = const [],
    Map<String, String> renamed = const {},
    DateTime? at,
  }) => _observeWith(emoteKind, channel, EmoteType.sevenTv.name, (latest) {
    if (latest.isEmpty) return const {};
    final next = <String, String>{};
    for (final e in latest.entries) {
      final id = e.key.split(':')[1];
      if (removedIds.contains(id)) continue;
      final name = renamed[id];
      if (name == null) {
        next[e.key] = e.value;
        continue;
      }
      final def = jsonDecode(e.value) as Map<String, dynamic>;
      def['code'] = name;
      next['${EmoteType.sevenTv.name}:$id:$name'] = jsonEncode(def);
    }
    for (final e in added) {
      next[emoteKey(e)] = jsonEncode(e.toJson());
    }
    return next;
  }, at);

  /// A fetch of [scope]'s Twitch badges ('' for global). A redrawn badge
  /// keeps its set and version but not its image, so the image is part of
  /// the key.
  Future<void> observeBadges(
    String scope,
    Map<String, BadgeSet> sets, {
    DateTime? at,
  }) => observe(badgeKind, scope, _badgeSource, {
    for (final set in sets.entries)
      for (final v in set.value.versions.entries)
        '${set.key}/${v.key}/${v.value.imageUrl}': jsonEncode({
          'set': set.key,
          'version': v.key,
          'url': v.value.imageUrl,
          'title': ?v.value.title,
        }),
  }, at: at);

  /// [channel]'s emote and badge history, loaded for reads; null when the
  /// store is closed.
  Future<ChannelSets?> load(String channel) async {
    await _observing;
    try {
      final s = await store;
      if (s == null) return null;
      return ChannelSets._(
        this,
        channel,
        emotes: [
          for (final scope in ['', channel])
            for (final p in _providers)
              (scope, p, await _log(s, emoteKind, scope, p.name)),
        ],
        badges: [
          for (final scope in ['', channel])
            await _log(s, badgeKind, scope, _badgeSource),
        ],
        visibility: visibility(),
      );
    } catch (e) {
      logDebug('[SetHistory] load failed: $e');
      return null;
    }
  }

  Emote? _emote(String scope, String key, String json) {
    final id = '$scope|$key';
    final known = _emotes[id];
    if (known != null) return known;
    try {
      return _emotes[id] = Emote.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
    } on Object catch (e) {
      logDebug('[SetHistory] bad emote def $key: $e');
      return null;
    }
  }

  static V _cached<V>(Map<String, V> cache, String key, V Function() build) {
    final hit = cache.remove(key);
    if (hit != null) return cache[key] = hit;
    if (cache.length >= _cacheSize) cache.remove(cache.keys.first);
    return cache[key] = build();
  }

  /// Forgets every log, for a wiped store. Waits for writes in flight.
  Future<void> clear() async {
    await _observing;
    _logs.clear();
    _emotes.clear();
    _lookups.clear();
    _badges.clear();
  }
}

/// One channel's emote and badge history, read synchronously row by row.
/// A row older than the first observation reads the first one, the nearest
/// knowledge. Null answers mean nothing was ever observed: the caller falls
/// back to today's sets.
class ChannelSets {
  ChannelSets._(
    this._history,
    this._channel, {
    required List<(String, EmoteType, SetLog)> emotes,
    required List<SetLog> badges,
    required EmoteVisibilityRule visibility,
  }) : _emoteLogs = emotes,
       _badgeLogs = badges,
       _visibility = visibility,
       _visibilityKey =
           '${[for (final t in visibility.disabled) t.name]..sort()}'
           '${visibility.allowUnlisted}';

  final SetHistory _history;
  final String _channel;
  final List<(String, EmoteType, SetLog)> _emoteLogs;
  final List<SetLog> _badgeLogs;
  final EmoteVisibilityRule _visibility;
  final String _visibilityKey;

  /// Whether Twitch emotes show, so rows keep their positions.
  bool get twitchOn => !_visibility.disabled.contains(EmoteType.twitch);

  /// Third-party emotes by code as the sets stood at [ms], merged like the
  /// live lookup.
  Map<String, Emote>? emotesAt(int ms) {
    final at = [for (final (_, _, log) in _emoteLogs) log.indexAt(ms)];
    if (at.every((i) => i < 0)) return null;
    return SetHistory._cached(
      _history._lookups,
      '$_channel|${at.join(',')}|$_visibilityKey',
      () {
        final lists = {
          for (final scope in [EmoteScope.global, EmoteScope.channel])
            scope: <EmoteType, List<Emote>>{},
        };
        for (var i = 0; i < _emoteLogs.length; i++) {
          if (at[i] < 0) continue;
          final (scope, provider, log) = _emoteLogs[i];
          final kind = scope.isEmpty ? EmoteScope.global : EmoteScope.channel;
          lists[kind]![provider] = [
            for (final e in log.stateAt(at[i]).entries)
              ?_history._emote(scope, e.key, e.value),
          ];
        }
        EmoteCatalog catalog(EmoteScope scope) {
          var c = EmoteCatalog();
          for (final e in lists[scope]!.entries) {
            c = c.withList(scope, e.key, e.value);
          }
          return c;
        }

        return mergeEmoteLookup(
          global: catalog(EmoteScope.global),
          channel: catalog(EmoteScope.channel),
          disabledProviders: _visibility.disabled,
          allowUnlisted7tv: _visibility.allowUnlisted,
        ).byCode;
      },
    );
  }

  /// Badge images by `set/version` as they stood at [ms], the channel's
  /// over the global ones.
  Map<String, BadgeVersion>? badgesAt(int ms) {
    final at = [for (final log in _badgeLogs) log.indexAt(ms)];
    if (at.every((i) => i < 0)) return null;
    return SetHistory._cached(
      _history._badges,
      '$_channel|${at.join(',')}',
      () {
        final out = <String, BadgeVersion>{};
        for (var i = 0; i < _badgeLogs.length; i++) {
          if (at[i] < 0) continue;
          for (final json in _badgeLogs[i].stateAt(at[i]).values) {
            try {
              final m = jsonDecode(json) as Map<String, dynamic>;
              out['${m['set']}/${m['version']}'] = BadgeVersion(
                imageUrl: m['url'] as String,
                title: m['title'] as String?,
              );
            } on Object catch (e) {
              logDebug('[SetHistory] bad badge def: $e');
            }
          }
        }
        return out;
      },
    );
  }
}
