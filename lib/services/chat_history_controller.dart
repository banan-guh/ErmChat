import 'dart:async';

import '../chat/chat.dart';
import '../client/session.dart';
import '../models/twitch_message.dart';
import '../util/log.dart';
import 'ignore_manager.dart';
import 'message_policy.dart';
import 'ping_manager.dart';
import 'recent_messages.dart';
import 'user_store.dart';

/// Owns the history backfill paths (boot, join, reconnect): the ignore filter,
/// user learning, self rewrite, mention-only ping tint, and the kernel merge.
/// Pipeline-layer logic only; the UI observes the kernel notifiers it bumps.
class ChatHistoryController {
  ChatHistoryController({
    required this.chat,
    required this.session,
    required this.recentMessages,
    required this.ignoreManager,
    required this.pingManager,
    required this.userStore,
    required this.maxMessages,
    required this.recentMessagesLimit,
  }) : _policy = ChatMessagePolicy(
         ignoreManager: ignoreManager,
         pingManager: pingManager,
         userStore: userStore,
         session: session,
       );

  final Chat chat;
  final Session session;
  final RecentMessagesService recentMessages;
  final IgnoreManager? ignoreManager;
  final PingManager? pingManager;
  final UserStore userStore;
  final int Function() maxMessages;
  final int Function() recentMessagesLimit;

  final ChatMessagePolicy _policy;
  final _refetchingChannels = <String>{};

  /// Merges robotty history into the channel buffer (newest-first). Single
  /// owner for the history checklist: ignore filter, user learning, the
  /// You/were rewrite, mention-only ping tint, then the channel verb which
  /// owns dedup, id-less fold, sort, gap note, truncate, and thread index.
  void mergeHistory(String channel, List<TwitchMessage> history) {
    final prepared = <TwitchMessage>[];
    for (final msg in history) {
      if (_policy.shouldDropForIgnore(msg)) continue;
      if (!msg.isSystem && msg.login.isNotEmpty) {
        _policy.learnUser(channel, msg);
      }
      _policy.applySelfRewrite(msg);
      _policy.applyPingHighlight(msg, mentionOnly: true);
      prepared.add(msg);
    }
    final c = chat.ensure(channel);
    final inserted = c.receiveHistory(
      prepared,
      rawHistory: history,
      maxMessages: maxMessages(),
    );
    final mirrored = [
      for (final m in inserted)
        if (m.highlight?.hasMention ?? false) m,
    ];
    if (mirrored.isNotEmpty) {
      chat.mentions.add(mirrored, maxMessages: maxMessages());
    }
    c.info.touch();
    c.moveConnectedToTop();
  }

  /// Refetches every joined channel's history after a reconnect. The kernel
  /// version bumps drive the UI; there is no setState batch to run here.
  void refetchAll() {
    for (final channel in List.of(chat.names)) {
      unawaited(refetchHistory(channel));
    }
  }

  Future<void> refetchHistory(String channel) async {
    if (!(chat.channelFor(channel)?.info.historyLoaded ?? false) ||
        _refetchingChannels.contains(channel)) {
      return;
    }
    _refetchingChannels.add(channel);
    try {
      final history = await recentMessages.fetchRecent(
        channel,
        limit: recentMessagesLimit(),
      );
      if (!chat.contains(channel)) return;
      final existing = chat.channelFor(channel)?.messages;
      if (existing == null || history.isEmpty) return;
      // Messages recovered from history after a reconnect gap are marked as
      // backfill so they render greyed out, distinct from live chat.
      for (final msg in history) {
        msg.isBackfill = true;
      }
      mergeHistory(channel, history);
    } catch (e) {
      logDebug(
        '[ChatHistoryController] history re-fetch failed for $channel: $e',
      );
    } finally {
      _refetchingChannels.remove(channel);
    }
  }
}
