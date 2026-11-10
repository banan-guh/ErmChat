import '../models/twitch_message.dart';
import '../util/thread_utils.dart';

// Thread graph: which buffered messages belong to the thread under a root,
// and which message roots a reply. Both walk the reply-parent chain, so they
// live together away from the panel state machine.

/// The messages in the thread under [openThreadRoot], newest first. Reads the
/// thread store through [threadFor] and falls back to scanning the channel
/// buffer from [messagesFor].
List<TwitchMessage> computeThreadMessages({
  required TwitchMessage? openThreadRoot,
  required List<TwitchMessage>? Function(String channel) messagesFor,
  required List<TwitchMessage>? Function(String channel, String rootId)
  threadFor,
}) {
  final entry = openThreadRoot;
  if (entry == null) return const [];
  final channel = entry.channel;
  if (channel == null) return const [];
  final allMsgs = messagesFor(channel) ?? [];

  final entryKey = entry.replyThreadRootId ?? entry.messageId;
  if (entryKey == null) return const [];

  final parentOf = <String, String>{};
  for (final m in allMsgs) {
    if (m.replyToParentId != null && m.messageId != null) {
      parentOf[m.messageId!] = m.replyToParentId!;
    }
  }

  final resolvedKey = threadKeyFor(entry, parentOf);
  if (resolvedKey == null) return const [];

  // Prefer the incremental thread store: it survives scrollback trimming
  // (pinned root, decayed replies) where a pure buffer scan comes up empty.
  // Old-style parent-chain threads that were never tagged fall back to the
  // scan below.
  final threadMsgs =
      threadFor(channel, resolvedKey) ??
      allMsgs.where((m) => threadKeyFor(m, parentOf) == resolvedKey).toList();

  threadMsgs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return threadMsgs;
}

/// The message a thread hangs from: [msg] itself when it is a root, else the
/// topmost ancestor in its channel's buffer.
TwitchMessage? findThreadRoot(
  TwitchMessage msg, {
  required List<TwitchMessage>? Function(String channel) messagesFor,
}) {
  if (msg.replyThreadRootId != null) return msg;

  final channel = msg.channel;
  if (channel == null) return null;
  final msgs = messagesFor(channel);
  if (msgs == null) return null;

  if (msg.messageId != null &&
      msgs.any((m) => m.replyToParentId == msg.messageId)) {
    return msg;
  }

  if (msg.replyToParentId == null) return null;

  final visited = <String>{};
  TwitchMessage current = msg;
  while (current.replyToParentId != null &&
      visited.add(current.replyToParentId!)) {
    final parent = msgs
        .where((m) => m.messageId == current.replyToParentId)
        .firstOrNull;
    if (parent == null) break;
    current = parent;
  }
  return current;
}
