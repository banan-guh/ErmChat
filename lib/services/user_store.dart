import 'dart:collection';

class UserStore {
  static const _maxPerChannel = 5000;
  final _users = <String, LinkedHashSet<String>>{};

  void addUser(String channel, String displayName) {
    if (displayName.isEmpty) return;
    final set =
        _users.putIfAbsent(channel, () => LinkedHashSet<String>());
    set.remove(displayName);
    set.add(displayName);
    while (set.length > _maxPerChannel) {
      set.remove(set.first);
    }
  }

  Iterable<String> usersForChannel(String channel) {
    return _users[channel] ?? const Iterable<String>.empty();
  }

  void removeChannel(String channel) {
    _users.remove(channel);
  }
}
