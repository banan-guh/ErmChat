import '../models/twitch_message.dart';

/// Which fields a chat search matches against.
enum ChatSearchScope { all, messages, chatters }

final _userToken = RegExp(r'(?:^|\s)user:(\S+)');

/// A chat search, lowercased. `user:name` in the query limits it to chatters
/// whose login or display name holds name, with the rest matched against the
/// text; otherwise [ChatSearchScope] picks the fields. Only a search for a
/// chatter alone matches system rows, by their text naming the chatter, so
/// timeouts and bans show up. The search panel and the archive share it.
class ChatQuery {
  const ChatQuery._(this.text, this.user, {this.either = false});

  factory ChatQuery.parse(String query, ChatSearchScope scope) {
    final q = query.trim().toLowerCase();
    final m = _userToken.firstMatch(q);
    if (m != null) {
      final rest = q.replaceRange(m.start, m.end, ' ').trim();
      return ChatQuery._(rest.replaceAll(RegExp(r'\s+'), ' '), m[1]);
    }
    return switch (scope) {
      ChatSearchScope.messages => ChatQuery._(q, null),
      ChatSearchScope.chatters => ChatQuery._('', q.isEmpty ? null : q),
      ChatSearchScope.all => ChatQuery._(q, q, either: q.isNotEmpty),
    };
  }

  /// Text the message must hold; empty for any.
  final String text;

  /// Text the login or display name must hold; null for any.
  final String? user;

  /// A match by [text] or by [user] is enough.
  final bool either;

  bool get isEmpty => text.isEmpty && user == null;

  /// System rows naming [user] match: only for a search by chatter alone.
  String? get systemText => text.isEmpty ? user : null;

  /// Whether every match of this query also matches [wider], so this
  /// query's matches are [wider]'s matches it passes.
  bool narrows(ChatQuery wider) {
    final u = wider.user;
    return !wider.isEmpty &&
        either == wider.either &&
        text.contains(wider.text) &&
        (u == null || (user?.contains(u) ?? false));
  }

  bool matches(TwitchMessage msg) {
    if (isEmpty) return true;
    if (msg.isSystem) {
      final s = systemText;
      return s != null && msg.text.toLowerCase().contains(s);
    }
    final u = user;
    final inUser =
        u != null &&
        (msg.login.toLowerCase().contains(u) ||
            msg.displayName.toLowerCase().contains(u));
    final inText = text.isNotEmpty && msg.text.toLowerCase().contains(text);
    if (either) return inText || inUser;
    return (u == null || inUser) && (text.isEmpty || inText);
  }
}
