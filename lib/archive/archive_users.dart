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

/// Interned user tables by id. Ids are handed out in order and never reused,
/// so [prune] leaves gaps that stored rows never point into.
class UserTables {
  final Map<int, Who> whos = {};
  final Map<int, Look> looks = {};
  final Map<int, UserState> states = {};

  /// The ids the next new entries get.
  int nextWho = 0;
  int nextLook = 0;
  int nextState = 0;

  final Map<Who, int> _whoIds = {};
  final Map<Look, int> _lookIds = {};
  final Map<UserState, int> _stateIds = {};

  int internWho(Who who) => _whoIds.putIfAbsent(who, () {
    whos[nextWho] = who;
    return nextWho++;
  });

  int internLook(Look look) => _lookIds.putIfAbsent(look, () {
    looks[nextLook] = look;
    return nextLook++;
  });

  /// Returns the id a row stores for this who/look pair.
  int internState(int who, int look) {
    if (!whos.containsKey(who) || !looks.containsKey(look)) {
      throw RangeError('unknown who $who or look $look');
    }
    return _stateIds.putIfAbsent(UserState(who, look), () {
      states[nextState] = UserState(who, look);
      return nextState++;
    });
  }

  /// Restores saved entries at their ids, in any order.
  void putWho(int id, Who who) {
    whos[id] = who;
    _whoIds[who] = id;
    if (id >= nextWho) nextWho = id + 1;
  }

  void putLook(int id, Look look) {
    looks[id] = look;
    _lookIds[look] = id;
    if (id >= nextLook) nextLook = id + 1;
  }

  void putState(int id, int who, int look) {
    final state = UserState(who, look);
    states[id] = state;
    _stateIds[state] = id;
    if (id >= nextState) nextState = id + 1;
  }

  /// Drops every state outside [live], then the whos and looks no state
  /// left uses. Returns the dropped ids.
  ({List<int> whos, List<int> looks, List<int> states}) prune(Set<int> live) {
    final deadStates = [
      for (final id in states.keys)
        if (!live.contains(id)) id,
    ];
    for (final id in deadStates) {
      _stateIds.remove(states.remove(id));
    }
    final usedWhos = {for (final s in states.values) s.who};
    final usedLooks = {for (final s in states.values) s.look};
    final deadWhos = [
      for (final id in whos.keys)
        if (!usedWhos.contains(id)) id,
    ];
    final deadLooks = [
      for (final id in looks.keys)
        if (!usedLooks.contains(id)) id,
    ];
    for (final id in deadWhos) {
      _whoIds.remove(whos.remove(id));
    }
    for (final id in deadLooks) {
      _lookIds.remove(looks.remove(id));
    }
    return (whos: deadWhos, looks: deadLooks, states: deadStates);
  }
}
