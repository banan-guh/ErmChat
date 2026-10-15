import '../models/twitch_message.dart';

/// Which fields a chat search matches against.
enum ChatSearchScope { all, messages, chatters }

/// Whether [msg] matches the lowercased query [qLower] in [scope]: a
/// case-insensitive substring of the text, or of the login or display name.
/// System rows never match. The search panel and the archive share it.
bool searchMatchesLower(
  TwitchMessage msg,
  String qLower,
  ChatSearchScope scope,
) {
  if (qLower.isEmpty) return true;
  if (msg.isSystem) return false;
  final inText = msg.text.toLowerCase().contains(qLower);
  final inUser =
      msg.login.toLowerCase().contains(qLower) ||
      msg.displayName.toLowerCase().contains(qLower);
  return switch (scope) {
    ChatSearchScope.messages => inText,
    ChatSearchScope.chatters => inUser,
    ChatSearchScope.all => inText || inUser,
  };
}
