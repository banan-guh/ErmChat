import 'emote.dart';

/// Dedup priority within one scope: lower wins. 7TV over BTTV over FFZ over
/// Twitch, matching how overlapping codes are resolved across providers.
const kEmoteProviderPriority = <EmoteType, int>{
  EmoteType.sevenTv: 0,
  EmoteType.bttv: 1,
  EmoteType.ffz: 2,
  EmoteType.twitch: 3,
};

/// Derived, read-only view of a merged catalog: code->emote plus the same
/// emotes sorted by code for suggestion lists.
class EmoteLookup {
  final Map<String, Emote> byCode;
  final List<Emote> suggestions;

  EmoteLookup({required this.byCode, required this.suggestions});
}

/// Immutable per-scope provider emote lists. The global catalog holds every
/// global provider list; a channel catalog holds every channel list plus the
/// stored Twitch channel/subs list.
class EmoteCatalog {
  final List<Emote> twitchGlobal;
  final List<Emote> bttvGlobal;
  final List<Emote> ffzGlobal;
  final List<Emote> sevenTvGlobal;
  final List<Emote> twitchChannel;
  final List<Emote> bttvChannel;
  final List<Emote> ffzChannel;
  final List<Emote> sevenTvChannel;
  final List<Emote> twitchSubs;
  final List<Emote> sevenTvPersonal;

  EmoteCatalog({
    List<Emote> twitchGlobal = const [],
    List<Emote> bttvGlobal = const [],
    List<Emote> ffzGlobal = const [],
    List<Emote> sevenTvGlobal = const [],
    List<Emote> twitchChannel = const [],
    List<Emote> bttvChannel = const [],
    List<Emote> ffzChannel = const [],
    List<Emote> sevenTvChannel = const [],
    List<Emote> twitchSubs = const [],
    List<Emote> sevenTvPersonal = const [],
  }) : twitchGlobal = List.unmodifiable(twitchGlobal),
       bttvGlobal = List.unmodifiable(bttvGlobal),
       ffzGlobal = List.unmodifiable(ffzGlobal),
       sevenTvGlobal = List.unmodifiable(sevenTvGlobal),
       twitchChannel = List.unmodifiable(twitchChannel),
       bttvChannel = List.unmodifiable(bttvChannel),
       ffzChannel = List.unmodifiable(ffzChannel),
       sevenTvChannel = List.unmodifiable(sevenTvChannel),
       twitchSubs = List.unmodifiable(twitchSubs),
       sevenTvPersonal = List.unmodifiable(sevenTvPersonal);

  bool get isEmpty =>
      twitchGlobal.isEmpty &&
      bttvGlobal.isEmpty &&
      ffzGlobal.isEmpty &&
      sevenTvGlobal.isEmpty &&
      twitchChannel.isEmpty &&
      bttvChannel.isEmpty &&
      ffzChannel.isEmpty &&
      sevenTvChannel.isEmpty &&
      twitchSubs.isEmpty &&
      sevenTvPersonal.isEmpty;

  bool get isNotEmpty => !isEmpty;

  /// Global and channel lists of [type] in [scope]; personal only exists for
  /// 7TV and is read through [sevenTvPersonal] directly.
  List<Emote> listFor(EmoteScope scope, EmoteType type) =>
      switch ((scope, type)) {
        (EmoteScope.global, EmoteType.twitch) => twitchGlobal,
        (EmoteScope.global, EmoteType.bttv) => bttvGlobal,
        (EmoteScope.global, EmoteType.ffz) => ffzGlobal,
        (EmoteScope.global, EmoteType.sevenTv) => sevenTvGlobal,
        (EmoteScope.channel, EmoteType.twitch) => twitchChannel,
        (EmoteScope.channel, EmoteType.bttv) => bttvChannel,
        (EmoteScope.channel, EmoteType.ffz) => ffzChannel,
        (EmoteScope.channel, EmoteType.sevenTv) => sevenTvChannel,
        (EmoteScope.personal, EmoteType.sevenTv) => sevenTvPersonal,
        (EmoteScope.personal, _) => const [],
      };

  EmoteCatalog withList(EmoteScope scope, EmoteType type, List<Emote> emotes) =>
      copyWith(
        twitchGlobal: scope == EmoteScope.global && type == EmoteType.twitch
            ? emotes
            : null,
        bttvGlobal: scope == EmoteScope.global && type == EmoteType.bttv
            ? emotes
            : null,
        ffzGlobal: scope == EmoteScope.global && type == EmoteType.ffz
            ? emotes
            : null,
        sevenTvGlobal: scope == EmoteScope.global && type == EmoteType.sevenTv
            ? emotes
            : null,
        twitchChannel: scope == EmoteScope.channel && type == EmoteType.twitch
            ? emotes
            : null,
        bttvChannel: scope == EmoteScope.channel && type == EmoteType.bttv
            ? emotes
            : null,
        ffzChannel: scope == EmoteScope.channel && type == EmoteType.ffz
            ? emotes
            : null,
        sevenTvChannel: scope == EmoteScope.channel && type == EmoteType.sevenTv
            ? emotes
            : null,
        sevenTvPersonal:
            scope == EmoteScope.personal && type == EmoteType.sevenTv
            ? emotes
            : null,
      );

  EmoteCatalog copyWith({
    List<Emote>? twitchGlobal,
    List<Emote>? bttvGlobal,
    List<Emote>? ffzGlobal,
    List<Emote>? sevenTvGlobal,
    List<Emote>? twitchChannel,
    List<Emote>? bttvChannel,
    List<Emote>? ffzChannel,
    List<Emote>? sevenTvChannel,
    List<Emote>? twitchSubs,
    List<Emote>? sevenTvPersonal,
  }) => EmoteCatalog(
    twitchGlobal: twitchGlobal ?? this.twitchGlobal,
    bttvGlobal: bttvGlobal ?? this.bttvGlobal,
    ffzGlobal: ffzGlobal ?? this.ffzGlobal,
    sevenTvGlobal: sevenTvGlobal ?? this.sevenTvGlobal,
    twitchChannel: twitchChannel ?? this.twitchChannel,
    bttvChannel: bttvChannel ?? this.bttvChannel,
    ffzChannel: ffzChannel ?? this.ffzChannel,
    sevenTvChannel: sevenTvChannel ?? this.sevenTvChannel,
    twitchSubs: twitchSubs ?? this.twitchSubs,
    sevenTvPersonal: sevenTvPersonal ?? this.sevenTvPersonal,
  );

  /// Returns a catalog whose every list is this catalog's list when non-empty,
  /// otherwise the matching list from [other]. Used to seed the in-memory
  /// catalog from disk.
  EmoteCatalog fillMissing(EmoteCatalog other) => EmoteCatalog(
    twitchGlobal: twitchGlobal.isEmpty ? other.twitchGlobal : twitchGlobal,
    bttvGlobal: bttvGlobal.isEmpty ? other.bttvGlobal : bttvGlobal,
    ffzGlobal: ffzGlobal.isEmpty ? other.ffzGlobal : ffzGlobal,
    sevenTvGlobal: sevenTvGlobal.isEmpty ? other.sevenTvGlobal : sevenTvGlobal,
    twitchChannel: twitchChannel.isEmpty ? other.twitchChannel : twitchChannel,
    bttvChannel: bttvChannel.isEmpty ? other.bttvChannel : bttvChannel,
    ffzChannel: ffzChannel.isEmpty ? other.ffzChannel : ffzChannel,
    sevenTvChannel: sevenTvChannel.isEmpty
        ? other.sevenTvChannel
        : sevenTvChannel,
    twitchSubs: twitchSubs.isEmpty ? other.twitchSubs : twitchSubs,
    sevenTvPersonal: sevenTvPersonal.isEmpty
        ? other.sevenTvPersonal
        : sevenTvPersonal,
  );

  /// Flat channel provider emotes (excludes the stored Twitch subs list), in
  /// provider order.
  Iterable<Emote> channelProviderEmotes() sync* {
    yield* twitchChannel;
    yield* bttvChannel;
    yield* ffzChannel;
    yield* sevenTvChannel;
  }

  /// Every global list, in provider order.
  Iterable<Emote> globalProviderEmotes() sync* {
    yield* twitchGlobal;
    yield* bttvGlobal;
    yield* ffzGlobal;
    yield* sevenTvGlobal;
  }

  Map<String, dynamic> toJsonMap() {
    final map = <String, dynamic>{};
    void put(String key, List<Emote> emotes) {
      if (emotes.isEmpty) return;
      map[key] = [for (final e in emotes) e.toJson()];
    }

    put('twitchGlobal', twitchGlobal);
    put('bttvGlobal', bttvGlobal);
    put('ffzGlobal', ffzGlobal);
    put('sevenTvGlobal', sevenTvGlobal);
    put('twitchChannel', twitchChannel);
    put('bttvChannel', bttvChannel);
    put('ffzChannel', ffzChannel);
    put('sevenTvChannel', sevenTvChannel);
    put('twitchSubs', twitchSubs);
    put('sevenTvPersonal', sevenTvPersonal);
    return map;
  }

  static List<Emote> _decode(Object? raw) {
    final out = <Emote>[];
    if (raw is! List<dynamic>) return out;
    for (final item in raw) {
      try {
        if (item is Map<String, dynamic>) out.add(Emote.fromJson(item));
      } catch (_) {}
    }
    return out;
  }

  /// Rebuilds a catalog list-for-list from the persisted map shape. Unknown
  /// keys are ignored and missing keys stay empty.
  static EmoteCatalog fromJsonMap(Object? raw) {
    if (raw is! Map<String, dynamic>) return EmoteCatalog();
    return EmoteCatalog(
      twitchGlobal: _decode(raw['twitchGlobal']),
      bttvGlobal: _decode(raw['bttvGlobal']),
      ffzGlobal: _decode(raw['ffzGlobal']),
      sevenTvGlobal: _decode(raw['sevenTvGlobal']),
      twitchChannel: _decode(raw['twitchChannel']),
      bttvChannel: _decode(raw['bttvChannel']),
      ffzChannel: _decode(raw['ffzChannel']),
      sevenTvChannel: _decode(raw['sevenTvChannel']),
      twitchSubs: _decode(raw['twitchSubs']),
      sevenTvPersonal: _decode(raw['sevenTvPersonal']),
    );
  }
}

/// Ids and codes claimed by [emotes], used to test overlay collisions.
({Set<String> ids, Set<String> codes}) emoteOverlayKeys(
  Iterable<Emote> emotes,
) {
  final ids = <String>{};
  final codes = <String>{};
  for (final e in emotes) {
    if (e.id.isNotEmpty) ids.add(e.id);
    codes.add(e.code);
  }
  return (ids: ids, codes: codes);
}

/// Whether [emote]'s id or code is claimed by [keys].
bool overlayCollides(
  Emote emote,
  ({Set<String> ids, Set<String> codes}) keys,
) => keys.ids.contains(emote.id) || keys.codes.contains(emote.code);

/// Applies the account unlock overlay to a Twitch list: base entries whose id
/// or code collides with an unlock are replaced by the unlock. Third-party
/// entries pass through untouched.
List<Emote> applyAccountUnlocks(List<Emote> base, Iterable<Emote> unlocks) {
  if (unlocks.isEmpty) return base;
  final keys = emoteOverlayKeys(unlocks);
  return [
    for (final e in base)
      if (e.type != EmoteType.twitch || !overlayCollides(e, keys)) e,
    ...unlocks,
  ];
}

/// Merges a global catalog, an optional channel catalog, viewer personal 7TV
/// emotes, and the account unlock overlay into one read-only lookup.
///
/// Channel scope beats global; within a scope the provider priority in
/// [kEmoteProviderPriority] wins; personal 7TV emotes merge underneath the
/// base so channel/global codes always win conflicts. Disabled providers and
/// hidden unlisted 7TV emotes are dropped.
EmoteLookup mergeEmoteLookup({
  required EmoteCatalog global,
  EmoteCatalog? channel,
  Iterable<Emote> personal = const [],
  Iterable<Emote> accountUnlocks = const [],
  Set<EmoteType> disabledProviders = const {},
  bool allowUnlisted7tv = false,
}) {
  final best = <String, Emote>{};
  final scopeOf = <String, int>{};

  void add(Emote e) {
    if (disabledProviders.contains(e.type)) return;
    final existing = best[e.code];
    if (existing == null) {
      best[e.code] = e;
      scopeOf[e.code] = e.scope.index;
      return;
    }
    final existingScope = scopeOf[e.code] ?? 0;
    final newScope = e.scope.index;
    if (newScope > existingScope) {
      best[e.code] = e;
      scopeOf[e.code] = newScope;
    } else if (newScope == existingScope &&
        (kEmoteProviderPriority[e.type] ?? 99) <
            (kEmoteProviderPriority[existing.type] ?? 99)) {
      best[e.code] = e;
    }
  }

  for (final e in applyAccountUnlocks(global.twitchGlobal, accountUnlocks)) {
    add(e);
  }
  for (final e in global.bttvGlobal) {
    add(e);
  }
  for (final e in global.ffzGlobal) {
    add(e);
  }
  for (final e in global.sevenTvGlobal) {
    add(e);
  }
  if (channel != null) {
    // Stored Twitch channel/subs precede the provider lists so a stored entry
    // keeps its code on a same-provider tie.
    for (final e in channel.twitchSubs) {
      add(e);
    }
    for (final e in channel.twitchChannel) {
      add(e);
    }
    for (final e in channel.bttvChannel) {
      add(e);
    }
    for (final e in channel.ffzChannel) {
      add(e);
    }
    for (final e in channel.sevenTvChannel) {
      add(e);
    }
  }
  for (final e in personal) {
    if (disabledProviders.contains(e.type)) continue;
    best.putIfAbsent(e.code, () => e);
  }

  final visible = <Emote>[];
  for (final e in best.values) {
    final meta = e.meta;
    if (!allowUnlisted7tv && meta is SevenTvMeta && meta.unlisted) continue;
    visible.add(e);
  }
  visible.sort((a, b) => a.code.compareTo(b.code));
  return EmoteLookup(
    byCode: {for (final e in visible) e.code: e},
    suggestions: visible,
  );
}
