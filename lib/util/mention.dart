import '../models/twitch_message.dart';

final _wordSplitRe = RegExp(r'[\s,;:.!?()\[\]{}<>"/\\|@#$%^&*+=~`]+');

/// Whether [text] contains [name] as a whole word, optionally @-prefixed.
/// Shared by the mention check and the ping engine's username rule.
bool wordMatches(String text, String name) {
  if (name.isEmpty) return false;
  final lower = name.toLowerCase();
  final lowerText = text.toLowerCase();
  for (final w in lowerText.split(_wordSplitRe)) {
    if (w == '@$lower' || w == lower) return true;
  }
  return false;
}

bool isMention(String text, String login) => wordMatches(text, login);

/// Whether [msg] should count as a mention of [login]: a direct ping or a
/// reply to that user. System messages and the user's own messages never
/// count. Shared by the live pipeline, history merge, and backfill scans.
bool isMentionOf(TwitchMessage msg, String login) {
  if (msg.isSystem || msg.login.toLowerCase() == login) return false;
  final isReplyToMe =
      msg.replyToUser != null && msg.replyToUser!.toLowerCase() == login;
  return isMention(msg.text, login) || isReplyToMe;
}
