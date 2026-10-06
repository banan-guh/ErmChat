import '../client/session.dart';
import '../models/twitch_message.dart';
import 'ignore_manager.dart';
import 'ping_manager.dart';
import 'user_store.dart';

/// Per-message ingest policy shared by the live and history paths: local
/// ignores, Twitch blocks, keyword rules, ping highlighting, and user
/// learning. The live and history callers apply these
/// in their own order and keep the steps that differ between them.
///
/// Preserved differences (not aligned; decide separately):
/// - live rewrites keywords and overwrites any ping highlight; history only
///   backfills mention-tier highlights.
/// - live gates on chat-ready and shared-chat hide; history does not.
/// - live pings then learns users; history learns, then pings.
class ChatMessagePolicy {
  ChatMessagePolicy({
    required this.ignoreManager,
    required this.pingManager,
    required this.userStore,
    required this.session,
    this.isBlocked,
  });

  final IgnoreManager? ignoreManager;
  final PingManager? pingManager;
  final UserStore userStore;
  final Session session;
  final bool Function(String login)? isBlocked;

  /// Ignored users' messages drop outright; system messages always pass.
  bool shouldDropForIgnore(TwitchMessage msg) {
    return !msg.isSystem && ignoreManager?.isIgnored(msg.login) == true;
  }

  /// Twitch-blocked users' messages drop outright; system messages always pass.
  bool shouldDropForBlockedUser(TwitchMessage msg) {
    return !msg.isSystem && (isBlocked?.call(msg.login) ?? false);
  }

  /// Block-mode keyword matches drop the whole message.
  bool shouldDropForBlockedPhrase(TwitchMessage msg) {
    return !msg.isSystem && ignoreManager?.isBlockedPhrase(msg.text) == true;
  }

  /// Rewrites the text (with emote position realignment) for non-block
  /// keyword rules.
  void rewriteKeywords(TwitchMessage msg) {
    final ignores = ignoreManager;
    if (ignores == null) return;
    rewriteMessageKeywords(msg, ignores);
  }

  /// Evaluates ping rules and stores the resulting highlight. With
  /// [mentionOnly] it only backfills mention-tier highlights onto messages
  /// that have none (the history path).
  void applyPingHighlight(TwitchMessage msg, {bool mentionOnly = false}) {
    if (mentionOnly && msg.highlight != null) return;
    final state = pingManager?.evaluate(msg);
    if (state == null) return;
    if (mentionOnly && !state.hasMention) return;
    msg.highlight = state;
  }

  /// Learns the sender's preferred display name for autocomplete.
  void learnUser(String channel, TwitchMessage msg) {
    final preferredName =
        msg.displayName.toLowerCase() == msg.login.toLowerCase()
        ? msg.displayName
        : msg.login;
    userStore.addUser(channel, preferredName);
  }
}
