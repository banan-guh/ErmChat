bool isMention(String text, String login) {
  final words = text.split(RegExp(r'[\s,;:.!?()\[\]{}<>"/\\|@#$%^&*+=~`]+'));
  for (final w in words) {
    final lower = w.toLowerCase();
    if (lower == '@$login' || lower == login) return true;
  }
  return false;
}
