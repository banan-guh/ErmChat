import 'dart:typed_data';

import 'archive_io.dart';

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

/// Interned user tables. Ids are the insertion index and stay stable.
class UserTables {
  static const int version = 1;

  final List<Who> whos = [];
  final List<Look> looks = [];
  final List<UserState> states = [];
  final Map<Who, int> _whoIds = {};
  final Map<Look, int> _lookIds = {};
  final Map<UserState, int> _stateIds = {};

  int internWho(Who who) => _whoIds.putIfAbsent(who, () {
    whos.add(who);
    return whos.length - 1;
  });

  int internLook(Look look) => _lookIds.putIfAbsent(look, () {
    looks.add(look);
    return looks.length - 1;
  });

  /// Returns the id a row stores for this who/look pair.
  int internState(int who, int look) {
    if (who < 0 || who >= whos.length || look < 0 || look >= looks.length) {
      throw RangeError('unknown who $who or look $look');
    }
    final state = UserState(who, look);
    return _stateIds.putIfAbsent(state, () {
      states.add(state);
      return states.length - 1;
    });
  }

  /// Packed like a block: the three tables, deflated.
  Uint8List encode() {
    final body = ByteWriter();
    body.varint(whos.length);
    for (final w in whos) {
      body.string(w.userId);
      body.string(w.login);
      body.string(w.displayName ?? '');
      body.byte(w.displayName == null ? 0 : 1);
    }
    body.varint(looks.length);
    for (final l in looks) {
      body.string(l.color ?? '');
      body.byte(l.color == null ? 0 : 1);
      body.string(l.badges);
      body.varint(l.extra.length);
      for (final (k, v) in l.extra) {
        body.string(k);
        body.string(v);
      }
    }
    body.varint(states.length);
    for (final s in states) {
      body.varint(s.who);
      body.varint(s.look);
    }
    return packPayload(version, body.takeBytes());
  }

  /// Throws [ArchiveFormatException] on truncated, corrupt, or unknown data.
  static UserTables decode(Uint8List data) {
    final raw = unpackPayload(version, data, 'user tables');
    final r = ByteReader(raw);
    final t = UserTables();
    int count() {
      final n = r.varint();
      if (n > r.remaining) {
        throw const ArchiveFormatException('implausible count');
      }
      return n;
    }

    try {
      for (var i = count(); i > 0; i--) {
        final id = r.string();
        final login = r.string();
        final name = r.string();
        final has = r.byte() == 1;
        t.internWho(
          Who(userId: id, login: login, displayName: has ? name : null),
        );
      }
      for (var i = count(); i > 0; i--) {
        final color = r.string();
        final hasColor = r.byte() == 1;
        final badges = r.string();
        final extra = <(String, String)>[];
        for (var j = count(); j > 0; j--) {
          extra.add((r.string(), r.string()));
        }
        t.internLook(
          Look(color: hasColor ? color : null, badges: badges, extra: extra),
        );
      }
      for (var i = count(); i > 0; i--) {
        t.internState(r.varint(), r.varint());
      }
    } on RangeError {
      throw const ArchiveFormatException('state references unknown user');
    }
    return t;
  }
}
