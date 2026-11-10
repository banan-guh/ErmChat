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
///
/// The lists live in one keyed collection ([_lists]) that the historical
/// `twitchGlobal` … `sevenTvPersonal` accessors read, so no method needs a
/// per-scope/per-provider branch. Loops walk [_slots], [_providerSlots] or
/// [_scopeSlots] instead of the map: those constants are the only source of
/// catalog order, so precedence never rides on map insertion order.
class EmoteCatalog {
  /// Provider lists keyed by (scope, provider). Every slot is present.
  final Map<(EmoteScope, EmoteType), List<Emote>> _lists;

  /// The stored Twitch channel/subs snapshot. It is persisted and merged like
  /// a list, but it is not a (scope, provider) pair — channel/Twitch is already
  /// the provider list — so it sits beside [_lists].
  final List<Emote> twitchSubs;

  /// Global and channel slots in catalog order, which is also the order the
  /// merge walks them in (Twitch first, so a later provider wins the code).
  static const _providerSlots = <(EmoteScope, EmoteType)>[
    (EmoteScope.global, EmoteType.twitch),
    (EmoteScope.global, EmoteType.bttv),
    (EmoteScope.global, EmoteType.ffz),
    (EmoteScope.global, EmoteType.sevenTv),
    (EmoteScope.channel, EmoteType.twitch),
    (EmoteScope.channel, EmoteType.bttv),
    (EmoteScope.channel, EmoteType.ffz),
    (EmoteScope.channel, EmoteType.sevenTv),
  ];

  /// Every slot in catalog order: the global lists, the channel lists, then
  /// 7TV personal (the only personal list there is).
  static const _slots = <(EmoteScope, EmoteType)>[
    ..._providerSlots,
    (EmoteScope.personal, EmoteType.sevenTv),
  ];

  /// Provider slots of one scope, in catalog order.
  static Iterable<(EmoteScope, EmoteType)> _scopeSlots(EmoteScope scope) =>
      _providerSlots.where((slot) => slot.$1 == scope);

  /// Freezes a freshly built slot map. Values are already unmodifiable lists;
  /// the explicit map type gives the literal the element context it needs.
  static Map<(EmoteScope, EmoteType), List<Emote>> _frozen(
    Map<(EmoteScope, EmoteType), List<Emote>> lists,
  ) => Map.unmodifiable(lists);

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
  }) : _lists = _frozen({
         (EmoteScope.global, EmoteType.twitch): List.unmodifiable(twitchGlobal),
         (EmoteScope.global, EmoteType.bttv): List.unmodifiable(bttvGlobal),
         (EmoteScope.global, EmoteType.ffz): List.unmodifiable(ffzGlobal),
         (EmoteScope.global, EmoteType.sevenTv): List.unmodifiable(
           sevenTvGlobal,
         ),
         (EmoteScope.channel, EmoteType.twitch): List.unmodifiable(
           twitchChannel,
         ),
         (EmoteScope.channel, EmoteType.bttv): List.unmodifiable(bttvChannel),
         (EmoteScope.channel, EmoteType.ffz): List.unmodifiable(ffzChannel),
         (EmoteScope.channel, EmoteType.sevenTv): List.unmodifiable(
           sevenTvChannel,
         ),
         (EmoteScope.personal, EmoteType.sevenTv): List.unmodifiable(
           sevenTvPersonal,
         ),
       }),
       twitchSubs = List.unmodifiable(twitchSubs);

  /// Wraps lists that are already unmodifiable, so internal copies do not
  /// re-wrap the lists they keep.
  const EmoteCatalog._(this._lists, this.twitchSubs);

  List<Emote> get twitchGlobal => _listOf(EmoteScope.global, EmoteType.twitch);

  List<Emote> get bttvGlobal => _listOf(EmoteScope.global, EmoteType.bttv);

  List<Emote> get ffzGlobal => _listOf(EmoteScope.global, EmoteType.ffz);

  List<Emote> get sevenTvGlobal =>
      _listOf(EmoteScope.global, EmoteType.sevenTv);

  List<Emote> get twitchChannel =>
      _listOf(EmoteScope.channel, EmoteType.twitch);

  List<Emote> get bttvChannel => _listOf(EmoteScope.channel, EmoteType.bttv);

  List<Emote> get ffzChannel => _listOf(EmoteScope.channel, EmoteType.ffz);

  List<Emote> get sevenTvChannel =>
      _listOf(EmoteScope.channel, EmoteType.sevenTv);

  List<Emote> get sevenTvPersonal =>
      _listOf(EmoteScope.personal, EmoteType.sevenTv);

  bool get isEmpty =>
      _slots.every((slot) => _listOf(slot.$1, slot.$2).isEmpty) &&
      twitchSubs.isEmpty;

  bool get isNotEmpty => !isEmpty;

  /// The list stored for [scope]/[type], const-empty for the pairs no provider
  /// exposes.
  List<Emote> _listOf(EmoteScope scope, EmoteType type) =>
      _lists[(scope, type)] ?? const [];

  /// Global and channel lists of [type] in [scope]; personal only exists for
  /// 7TV and is read through [sevenTvPersonal] directly.
  List<Emote> listFor(EmoteScope scope, EmoteType type) => _listOf(scope, type);

  /// A copy with the [scope]/[type] list replaced. Pairs no provider exposes
  /// (personal outside 7TV) leave every list unchanged.
  EmoteCatalog withList(EmoteScope scope, EmoteType type, List<Emote> emotes) =>
      EmoteCatalog._(
        _frozen({
          for (final (slotScope, slotType) in _slots)
            (slotScope, slotType): slotScope == scope && slotType == type
                ? List.unmodifiable(emotes)
                : _listOf(slotScope, slotType),
        }),
        twitchSubs,
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
  EmoteCatalog fillMissing(EmoteCatalog other) {
    List<Emote> pick(EmoteScope scope, EmoteType type) {
      final own = _listOf(scope, type);
      return own.isEmpty ? other._listOf(scope, type) : own;
    }

    return EmoteCatalog._(
      _frozen({
        for (final (scope, type) in _slots) (scope, type): pick(scope, type),
      }),
      twitchSubs.isEmpty ? other.twitchSubs : twitchSubs,
    );
  }

  /// Flat channel provider emotes (excludes the stored Twitch subs list), in
  /// provider order.
  Iterable<Emote> channelProviderEmotes() => _emotesIn(EmoteScope.channel);

  /// Every global list, in provider order.
  Iterable<Emote> globalProviderEmotes() => _emotesIn(EmoteScope.global);

  /// Every provider list of [scope] concatenated, in provider order.
  Iterable<Emote> _emotesIn(EmoteScope scope) sync* {
    for (final (_, type) in _scopeSlots(scope)) {
      yield* _listOf(scope, type);
    }
  }

  /// Persisted key of one provider list, e.g. `twitchGlobal` or
  /// `sevenTvPersonal`: the provider name plus its scope, exactly the names the
  /// per-list fields used to have.
  static String _jsonKey(EmoteScope scope, EmoteType type) => switch (scope) {
    EmoteScope.global => '${type.name}Global',
    EmoteScope.channel => '${type.name}Channel',
    EmoteScope.personal => '${type.name}Personal',
  };

  /// Persisted key of the stored Twitch channel/subs snapshot.
  static const _subsKey = 'twitchSubs';

  Map<String, dynamic> toJsonMap() {
    final map = <String, dynamic>{};
    void put(String key, List<Emote> emotes) {
      if (emotes.isEmpty) return;
      map[key] = [for (final e in emotes) e.toJson()];
    }

    for (final (scope, type) in _providerSlots) {
      put(_jsonKey(scope, type), _listOf(scope, type));
    }
    // The subs snapshot keeps the place it has always had, between the channel
    // and the personal lists.
    put(_subsKey, twitchSubs);
    put(_jsonKey(EmoteScope.personal, EmoteType.sevenTv), sevenTvPersonal);
    return map;
  }

  static List<Emote> _decode(Object? raw) {
    final out = <Emote>[];
    if (raw is! List<dynamic>) return out;
    for (final item in raw) {
      try {
        if (item is Map<String, dynamic>) out.add(Emote.fromJson(item));
      } catch (_) {
        // A malformed emote drops only itself.
      }
    }
    return out;
  }

  /// Rebuilds a catalog list-for-list from the persisted map shape. Unknown
  /// keys are ignored and missing keys stay empty.
  static EmoteCatalog fromJsonMap(Object? raw) {
    if (raw is! Map<String, dynamic>) return EmoteCatalog();
    return EmoteCatalog._(
      _frozen({
        for (final (scope, type) in _slots)
          (scope, type): List.unmodifiable(_decode(raw[_jsonKey(scope, type)])),
      }),
      List.unmodifiable(_decode(raw[_subsKey])),
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
/// [kEmoteProviderPriority] wins. Personal 7TV emotes beat third-party channel
/// and global codes; Twitch's own emotes keep theirs. Disabled providers,
/// hidden unlisted 7TV emotes, and personal sets' unapproved emotes are
/// dropped before the merge, so the next candidate for the code survives.
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

  bool hidden(Emote e) {
    if (disabledProviders.contains(e.type)) return true;
    final meta = e.meta;
    if (meta is SevenTvMeta) {
      if (!allowUnlisted7tv && meta.unlisted) return true;
      // A personal set can hold pending or rejected emotes.
      if (e.scope == EmoteScope.personal && !meta.personalUse) return true;
    }
    return false;
  }

  void add(Emote e) {
    if (hidden(e)) return;
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

  // Global lists in provider order; the Twitch list takes the account unlock
  // overlay before it enters the merge.
  for (final (_, type) in EmoteCatalog._scopeSlots(EmoteScope.global)) {
    final emotes = global._listOf(EmoteScope.global, type);
    final source = type == EmoteType.twitch
        ? applyAccountUnlocks(emotes, accountUnlocks)
        : emotes;
    for (final e in source) {
      add(e);
    }
  }
  if (channel != null) {
    // Stored Twitch channel/subs precede the provider lists so a stored entry
    // keeps its code on a same-provider tie.
    for (final e in channel.twitchSubs) {
      add(e);
    }
    for (final (_, type) in EmoteCatalog._scopeSlots(EmoteScope.channel)) {
      for (final e in channel._listOf(EmoteScope.channel, type)) {
        add(e);
      }
    }
  }
  for (final e in personal) {
    if (hidden(e)) continue;
    final existing = best[e.code];
    // Personal 7TV emotes beat channel/global third-party codes. Twitch's
    // own emotes keep theirs, matching the 7TV clients.
    if (existing != null && existing.type == EmoteType.twitch) continue;
    best[e.code] = e;
    scopeOf[e.code] = e.scope.index;
  }

  final visible = best.values.toList();
  visible.sort((a, b) => a.code.compareTo(b.code));
  return EmoteLookup(
    byCode: {for (final e in visible) e.code: e},
    suggestions: visible,
  );
}
