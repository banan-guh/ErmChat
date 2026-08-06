import '../models/twitch_message.dart';

final _wordSplitRe = RegExp(r'[\s,;:.!?()\[\]{}<>"/\\|@#$%^&*+=~`]+');

bool isMention(String text, String login) {
  final words = text.split(_wordSplitRe);
  for (final w in words) {
    final lower = w.toLowerCase();
    if (lower == '@$login' || lower == login) return true;
  }
  return false;
}

/// Whether [msg] should count as a mention of [login]: a direct ping or a
/// reply to that user. System messages and the user's own messages never
/// count. Shared by the live pipeline, history merge, and backfill scans.
bool isMentionOf(TwitchMessage msg, String login) {
  if (msg.isSystem || msg.login.toLowerCase() == login) return false;
  final isReplyToMe =
      msg.replyToUser != null && msg.replyToUser!.toLowerCase() == login;
  return isMention(msg.text, login) || isReplyToMe;
}
