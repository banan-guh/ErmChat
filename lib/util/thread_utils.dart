import '../models/twitch_message.dart';

final _wsCollapseRe = RegExp(r'\s+');

/// Single-line reply preview: trims, collapses runs, truncates.
String formatReplyPreview(String text, {int maxLen = 60}) {
  final collapsed = text.trim().replaceAll(_wsCollapseRe, ' ');
  if (collapsed.length > maxLen) {
    // Never split a surrogate pair; a lone half crashes text layout.
    final high = collapsed.codeUnitAt(maxLen - 1);
    final end = high >= 0xD800 && high <= 0xDBFF ? maxLen - 1 : maxLen;
    return '${collapsed.substring(0, end)}...';
  }
  return collapsed;
}

String resolveThreadRootId(String messageId, Map<String, String> parentOf) {
  var cur = messageId;
  final seen = <String>{cur};
  while (parentOf.containsKey(cur)) {
    cur = parentOf[cur]!;
    // Corrupt inputs can cycle; stop instead of hanging the UI isolate.
    if (!seen.add(cur)) break;
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

/// How long Twitch accepts a threaded reply. The server rejects older roots
/// with "Message cannot be replied to", so the composer closes at the same
/// point instead of sending an unthreaded message.
const threadReplyWindow = Duration(hours: 24);

/// Whether [root] is young enough to take a reply at [now].
bool threadRepliesOpen(TwitchMessage? root, DateTime now) =>
    root != null && now.difference(root.timestamp) < threadReplyWindow;

/// The row a send from an open thread should reply to. Rows without an id
/// cannot carry a reply tag, so they are skipped. The thread root is the
/// fallback, and null means there is nothing addressable to reply to.
TwitchMessage? threadReplyTarget({
  required List<TwitchMessage> threadMsgs,
  required String? rootId,
  required bool replyToRoot,
  required String channel,
}) {
  TwitchMessage stub(String id) =>
      TwitchMessage(login: '', text: '', messageId: id, channel: channel);

  if (!replyToRoot) {
    final latest = threadMsgs.where((m) => m.messageId != null).firstOrNull;
    if (latest != null) return latest;
  } else {
    final root = threadMsgs.where((m) => m.messageId == rootId).firstOrNull;
    if (root != null) return root;
  }
  return rootId == null ? null : stub(rootId);
}
