import 'package:flutter/foundation.dart' show ValueNotifier;

import 'dart:ui' show Color;

import '../models/twitch_message.dart';

/// The account the chat pipeline currently acts as.
class ActiveSession {
  String? login;
  String? userId;
}

/// Owns the shared chat state: the per-channel buffers the connection

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

  /// The active account. Writes go through [applyLogin] when they represent
  /// the pipeline resolving or switching identity; direct field writes are
  /// reserved for HomeScreen's special paths (init seeding, auth-switch
  /// drop) which manage their own side effects.
  final ActiveSession session = ActiveSession();

  /// Fires after [applyLogin]; HomeScreen hooks account-scoped refreshes
  /// (ping account, mention rescan, blocks, macro warm).
  void Function(String? login)? onLoginApplied;

  /// Unread mention total across all channels.
  int unreadMentions = 0;

  /// Change signal for [unreadMentions]; the app-bar badge listens to this,
  /// so writers must bump it after mutating the counter.
  final ValueNotifier<int> mentionsBump = ValueNotifier(0);

  /// Pipeline-path login write: assigns and fires [onLoginApplied].
  void applyLogin(String? login) {
    session.login = login;
    onLoginApplied?.call(login);
  }

  int _nextSystemMessageId = 0;

  /// Inserts a system message at the top of [channel]'s buffer, applying the
  /// status-marker folding rules: Connected/Disconnected/Reconnected lines
  /// replace or dedup each other instead of stacking on socket flaps. Returns
  /// false when folding dropped the message entirely (no insert happened);
  /// callers skip their truncate/notify signals in that case.
  bool addSystemMessage(String channel, String text, {Color? accent}) {
    final msgs = channelMessages.putIfAbsent(channel, () => []);

    const statusTexts = {
      'Connected',
      'Connected to IRC',
      'Disconnected',
      'Reconnected',
      'Chat reconnecting...',
    };
    if (statusTexts.contains(text)) {
      if (text == 'Connected' || text == 'Connected to IRC') {
        final hasPriorStatus = msgs.any(
          (m) => m.isSystem && statusTexts.contains(m.text),
        );
        text = hasPriorStatus ? 'Reconnected' : 'Connected';
      }
      final top = msgs.isEmpty ? null : msgs.first;
      if (text == 'Reconnected') {
        // The outage ended: fold the transient markers into this line rather
        // than leaving a bogus outage entry behind.
        msgs.removeWhere(
          (m) =>
              m.isSystem &&
              (m.text == 'Disconnected' || m.text == 'Chat reconnecting...'),
        );
        // The write and read sockets both report the recovery; keep a single
        // line instead of stacking duplicates.
        final newTop = msgs.isEmpty ? null : msgs.first;
        if (newTop != null && newTop.isSystem && newTop.text == 'Reconnected') {
          return false;
        }
      } else if (text == 'Disconnected' || text == 'Chat reconnecting...') {
        // "Disconnected" is the dominant outage marker: it describes the whole
        // app being down, so "Chat reconnecting..." never replaces it.
        if (text == 'Chat reconnecting...') {
          final hasDisconnected = msgs.any(
            (m) => m.isSystem && m.text == 'Disconnected',
          );
          if (hasDisconnected) return false;
          if (top != null && top.isSystem && top.text == text) return false;
        } else {
          // A flapping socket must not pile up markers.
          if (top != null && top.isSystem && top.text == text) return false;
          msgs.removeWhere(
            (m) => m.isSystem && m.text == 'Chat reconnecting...',
          );
        }
      }
    }

    msgs.insert(
      0,
      TwitchMessage(
        login: '',
        text: text,
        messageId: 'sys_${_nextSystemMessageId++}',
        isSystem: true,
        systemAccent: accent,
        channel: channel,
      ),
    );
    return true;
  }
}
