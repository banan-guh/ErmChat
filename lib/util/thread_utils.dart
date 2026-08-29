import '../models/twitch_message.dart';

String resolveThreadRootId(String messageId, Map<String, String> parentOf) {
  var cur = messageId;
  while (parentOf.containsKey(cur)) {
    cur = parentOf[cur]!;
  }
  return cur;
}

/// Thread root: explicit reply root, or walk-to-root of parent chain, or own id.
String? threadKeyFor(TwitchMessage m, Map<String, String> parentOf) {
  if (m.replyThreadRootId != null) return m.replyThreadRootId;
  if (m.messageId != null && parentOf.containsKey(m.messageId)) {
    return resolveThreadRootId(m.messageId!, parentOf);
  }
  return m.messageId;
}
