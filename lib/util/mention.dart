import '../models/twitch_message.dart';

final _wordSplitRe = RegExp(r'[\s,;:.!?()\[\]{}<>"/\\|@#$%^&*+=~`]+');

/// Whole-word match of [name] in [text], optionally @-prefixed.
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

/// Whether [msg] mentions [login] (direct ping or reply to that user). Excludes system messages and self.
bool isMentionOf(TwitchMessage msg, String login) {
  if (msg.isSystem || msg.login.toLowerCase() == login) return false;
  final isReplyToMe =
      msg.replyToUser != null && msg.replyToUser!.toLowerCase() == login;
  return isMention(msg.text, login) || isReplyToMe;
}
