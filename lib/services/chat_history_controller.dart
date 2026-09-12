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
    this.isBlocked,
  }) : _policy = ChatMessagePolicy(
         ignoreManager: ignoreManager,
         pingManager: pingManager,
         userStore: userStore,
         session: session,
         isBlocked: isBlocked,
       );

  final Chat chat;
  final Session session;
  final RecentMessagesService recentMessages;
  final IgnoreManager? ignoreManager;
  final PingManager? pingManager;
  final UserStore userStore;
  final int Function() maxMessages;
  final int Function() recentMessagesLimit;
  final bool Function(String login)? isBlocked;

  final ChatMessagePolicy _policy;
  final _refetchingChannels = <String>{};

  /// Merges robotty history into the channel buffer (newest-first). Single
  /// owner for the history checklist: ignore and block filters, user learning,
  /// the You/were rewrite, mention-only ping tint, then the chat root verb
  /// which owns the mention mirror and the channel's dedup, id-less fold, sort,
  /// gap note, truncate, and thread index.
  void mergeHistory(String channel, List<TwitchMessage> history) {
    final prepared = <TwitchMessage>[];
    for (final msg in history) {
      if (_policy.shouldDropForIgnore(msg)) continue;
      if (_policy.shouldDropForBlockedUser(msg)) continue;
      if (_policy.shouldDropForBlockedPhrase(msg)) continue;
      if (!msg.isSystem && msg.login.isNotEmpty) {
        _policy.learnUser(channel, msg);
      }
      _policy.applySelfRewrite(msg);
      _policy.applyPingHighlight(msg, mentionOnly: true);
      prepared.add(msg);
    }
    chat.receiveHistory(
      channel,
      prepared,
      rawHistory: history,
      maxMessages: maxMessages(),
      ownLogin: session.login,
    );
  }

  /// Retroactive mention scan, run once on login: evaluates ping rules against
  /// rows already buffered and mirrors the hits. Does not count unread.
  void scanForMentions() {
    if (session.login == null) return;
    final hits = <TwitchMessage>[];
    for (final name in chat.names) {
      final items = chat.channelFor(name)?.messages.items;
      if (items == null) continue;
      for (final msg in items) {
        if (msg.highlight != null) continue;
        _policy.applyPingHighlight(msg, mentionOnly: true);
        if (msg.highlight?.hasMention ?? false) hits.add(msg);
      }
    }
    if (hits.isNotEmpty) {
      chat.mirrorMentions(hits, maxMessages: maxMessages());
    }
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
