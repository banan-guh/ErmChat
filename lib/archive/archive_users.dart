import 'intern_table.dart';

/// Who a user is: written once per user.
class Who {
  const Who({required this.userId, required this.login, this.displayName});

  final String userId;
  final String login;

  /// Null when it equals [login].
  final String? displayName;

  @override
  bool operator ==(Object other) =>
      other is Who &&
      other.userId == userId &&
      other.login == login &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(userId, login, displayName);
}

/// How a user looked at one point in time, interned by value.
class Look {
  const Look({this.color, this.badges = '', this.extra = const []});

  /// Name color such as `#FF0000`, or null.
  final String? color;

  /// Badge combo as `set/version,set/version`.
  final String badges;

  /// Extensible key/value pairs (7TV paint, third-party badges).
  final List<(String, String)> extra;

  String get _key => [
    color ?? '\u0000',
    badges,
    for (final (k, v) in extra) '$k\u0001$v',
  ].join('\u0002');

  @override
  bool operator ==(Object other) => other is Look && other._key == _key;

  @override
  int get hashCode => _key.hashCode;
}

/// A who plus a look: the one reference a row stores.
class UserState {
  const UserState(this.who, this.look);

  final int who;
  final int look;

  @override
  bool operator ==(Object other) =>
      other is UserState && other.who == who && other.look == look;

  @override
  int get hashCode => Object.hash(who, look);
}

/// Interned user tables by id. Ids are handed out in order. Rows store
/// state ids, so states never renumber and live in a sparse table; whos and
/// looks are only named by states and the search index, so [compact] can
/// close their gaps.
class UserTables {
  final whos = InternTable<Who>();
  final looks = InternTable<Look>();
  final states = InternTable<UserState>.sparse();

  /// The ids the next new entries get.
  int get nextWho => whos.length;
  int get nextLook => looks.length;
  int get nextState => states.length;

  int internWho(Who who) => whos.intern(who);

  int internLook(Look look) => looks.intern(look);

  /// Returns the id a row stores for this who/look pair.
  int internState(int who, int look) {
    if (whos[who] == null || looks[look] == null) {
      throw RangeError('unknown who $who or look $look');
    }
    return states.intern(UserState(who, look));
  }

  /// Restores saved entries at their ids, in any order.
  void putWho(int id, Who who) => whos.put(id, who);

  void putLook(int id, Look look) => looks.put(id, look);

  void putState(int id, int who, int look) =>
      states.put(id, UserState(who, look));

  /// Drops every state outside [live], then the whos and looks no state
  /// left uses. Returns the dropped ids.
  ({List<int> whos, List<int> looks, List<int> states}) prune(Set<int> live) {
    final deadStates = [
      for (final (id, _) in states.entries)
        if (!live.contains(id)) id,
    ];
    states.remove(deadStates);
    final usedWhos = <int>{};
    final usedLooks = <int>{};
    for (final (_, s) in states.entries) {
      usedWhos.add(s.who);
      usedLooks.add(s.look);
    }
    final deadWhos = [
      for (final (id, _) in whos.entries)
        if (!usedWhos.contains(id)) id,
    ];
    final deadLooks = [
      for (final (id, _) in looks.entries)
        if (!usedLooks.contains(id)) id,
    ];
    whos.remove(deadWhos);
    looks.remove(deadLooks);
    return (whos: deadWhos, looks: deadLooks, states: deadStates);
  }

  /// Whether [compact] would at least halve the whos or the looks.
  bool get sparse => whos.sparse || looks.sparse;

  /// What [compact] would do now, without doing it: each old id's new id,
  /// or -1 for a gap.
  ({List<int> whos, List<int> looks}) compactPlan() =>
      (whos: whos.compactPlan(), looks: looks.compactPlan());

  /// Closes the gaps in whos and looks and points every state at the new
  /// ids. Returns the remaps, as [compactPlan] gave them.
  ({List<int> whos, List<int> looks}) compact() {
    final w = whos.compact();
    final l = looks.compact();
    for (final (id, s) in states.entries.toList()) {
      states.replace(id, UserState(w[s.who], l[s.look]));
    }
    return (whos: w, looks: l);
  }
}
