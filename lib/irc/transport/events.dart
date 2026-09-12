enum IrcConnectionStatus { disconnected, connecting, connected }

/// Why a channel JOIN never completed.
enum JoinFailureReason {
  /// The server sent NOTICE msg-id=msg_channel_suspended: the channel is
  /// suspended or deleted. Permanent for this socket; no point re-JOINing.
  suspended,

  /// The server never confirmed the JOIN (no ROOMSTATE) and the fast rejoin
  /// sweep gave up: usually a nonexistent channel, whose JOINs Twitch silently
  /// drops, or persistent burst loss.
  noResponse,
}

class IrcJoinFailureEvent {
  final String channel;
  final JoinFailureReason reason;

  IrcJoinFailureEvent({required this.channel, required this.reason});
}

/// Which socket this connection is: the chat write socket or the read-only
/// socket. Mirrors DankChat's ChatConnectionType: the connection loop,
/// keepalive, JOIN handling and backoff are identical for both; only the
/// message semantics differ (the write socket sends PRIVMSG, the read socket
/// only watches for own echoes).
enum IrcSocketRole { read, write }
