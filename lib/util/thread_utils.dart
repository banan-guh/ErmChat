import '../models/twitch_message.dart';

String resolveThreadRootId(String messageId, Map<String, String> parentOf) {
  var cur = messageId;
  while (parentOf.containsKey(cur)) {
    cur = parentOf[cur]!;
  }
  return cur;
}

/// The thread identity of a message: an explicit reply root when present,
/// otherwise the walk-to-root result of its reply-parent chain, otherwise the
/// message's own id (a standalone thread of one).
String? threadKeyFor(TwitchMessage m, Map<String, String> parentOf) {
  if (m.replyThreadRootId != null) return m.replyThreadRootId;
  if (m.messageId != null && parentOf.containsKey(m.messageId)) {
    return resolveThreadRootId(m.messageId!, parentOf);
  }
  return m.messageId;
}
