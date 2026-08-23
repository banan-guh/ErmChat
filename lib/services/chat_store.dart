import '../models/twitch_message.dart';

/// Owns the shared chat state: the per-channel buffers the connection
/// pipeline writes and the UI renders. One instance is created by
/// HomeScreen and handed to [ChatConnectionManager]; both sides hold the
/// same collection instances, so mutations are visible everywhere.
///
/// This is the seam between "what chat state exists" (here) and who
/// changes it (the manager) or displays it (the screen). Persistence and
/// derived view state (tile caches, panel data) stay out on purpose.
class ChatStore {
  ChatStore({
    required this.channels,
    required this.channelMessages,
    required this.messageKeys,
    required this.chatStatus,
    required this.channelsWithUnread,
    required this.channelsWithUnreadMentions,
    required this.unreadMentionsPerChannel,
    required this.historyLoaded,
    required this.channelsEmotesResolved,
    required this.channelUserIds,
    required this.lastSentWireText,
  });

  /// Joined channels in tab order.
  final List<String> channels;

  /// Live message buffer per channel, newest first.
  final Map<String, List<TwitchMessage>> channelMessages;

  /// Dedup keys (`$channel:$messageId`) guarding live/history double
  /// delivery while a message is on screen.
  final Set<String> messageKeys;

  /// Composed status line per channel (room modes + stream info).
  final Map<String, String> chatStatus;

  /// Channels with unseen messages (drives tab unread markers).
  final Set<String> channelsWithUnread;

  /// Channels with unseen messages mentioning the user.
  final Set<String> channelsWithUnreadMentions;

  /// Unread mention count per channel.
  final Map<String, int> unreadMentionsPerChannel;

  /// Channels whose recent-messages history was already fetched.
  final Set<String> historyLoaded;

  /// Channels whose third-party emote sets were resolved at least once.
  final Set<String> channelsEmotesResolved;

  /// Broadcaster user id per channel (ROOMSTATE fallback included).
  final Map<String, String> channelUserIds;

  /// Last wire text sent per channel, for duplicate-send bypassing.
  final Map<String, String> lastSentWireText;
}
