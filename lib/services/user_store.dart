import 'dart:collection';

class UserStore {
  static const _maxPerChannel = 5000;
  final _users = <String, LinkedHashMap<String, void>>{};

  void addUser(String channel, String displayName) {
    if (displayName.isEmpty) return;
    final map =
        _users.putIfAbsent(channel, () => LinkedHashMap<String, void>());
    map.remove(displayName);
    map[displayName] = null;
    while (map.length > _maxPerChannel) {
      map.remove(map.keys.first);
    }
  }

  Iterable<String> usersForChannel(String channel) {
    return _users[channel]?.keys ?? const Iterable<String>.empty();
  }

  void removeChannel(String channel) {
    _users.remove(channel);
  }
}
