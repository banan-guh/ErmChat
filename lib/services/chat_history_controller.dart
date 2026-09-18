import 'dart:async';

import '../chat/chat.dart';
import '../client/session.dart';
import '../emotes/emote.dart';
import '../models/twitch_message.dart';
import '../util/log.dart';
import 'emote_manager.dart';
import 'emote_store.dart';
import 'ignore_manager.dart';
import 'message_policy.dart';
import 'ping_manager.dart';
import 'recent_messages.dart';
import 'twitch_badge_service.dart';
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
    required this.emoteManager,
    required this.badgeService,
    required this.maxMessages,
    required this.recentMessagesLimit,
    this.isBlocked,
  }) : _policy = ChatMessagePolicy(
         ignoreManager: ignoreManager,
         pingManager: pingManager,
         userStore: userStore,
         session: session,
         isBlocked: isBlocked,
       ) {
    emoteManager.store.addListener(_onCatalogChanged);
  }

  final Chat chat;
  final Session session;
  final RecentMessagesService recentMessages;
  final IgnoreManager? ignoreManager;
  final PingManager? pingManager;
  final UserStore userStore;
  final EmoteManager emoteManager;
  final TwitchBadgeService badgeService;
  final int Function() maxMessages;
  final int Function() recentMessagesLimit;
  final bool Function(String login)? isBlocked;

  final ChatMessagePolicy _policy;
  final _refetchingChannels = <String>{};

  /// Catalog version already restamped. Version bumps mark full data
  /// changes; live 7TV deltas and config-only updates skip the bump, so
  /// comparing here keeps those off the restamp path by construction.
  int _restampedVersion = 0;

  /// Merges robotty history into the channel buffer (newest-first). Single
  /// owner for the history checklist: ignore and block filters, user learning,
  /// the You/were rewrite, mention-only ping tint, then the chat root verb
  /// which owns the mention mirror and the channel's dedup, id-less fold, sort,
  /// gap note, truncate, and thread index.
  void mergeHistory(String channel, List<TwitchMessage> history) {
    // A channel removed while its history was in flight must not be
    // resurrected by the root verb's ensure.
    if (!chat.contains(channel)) return;
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
      _stampEmoteResolution(msg, channel);
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

  /// Parses [msg]'s emotes once at merge time and stores them on the
  /// message, so scrolling back renders what history arrived with.
  void _stampEmoteResolution(TwitchMessage msg, String channel) {
    if (msg.isSystem) return;
    msg.emoteTokens = _parseForChannel(msg, channel);
  }

  /// Shared lookup: shared-chat rows resolve against the source channel.
  List<EmoteToken>? _parseForChannel(TwitchMessage msg, String channel) {
    if (msg.isSystem) return null;
    final source = msg.sourceBroadcasterId;
    final lookupChannel = source == null
        ? channel
        : badgeService.resolveChannelLogin(source) ?? channel;
    return emoteManager.parseMessageEmotes(msg, lookupChannel: lookupChannel);
  }

  /// Restamps one channel after its catalog landed. Only history rows baked
  /// as empty are candidates; live rows stay frozen. Returns healed rows.
  int restampChannelEmotes(String channel) {
    final channelState = chat.channelFor(channel);
    if (channelState == null) return 0;
    return channelState.restampHistoryEmotes(
      (msg) => _parseForChannel(msg, channel),
    );
  }

  /// Restamps every joined channel after a global catalog change.
  void restampAllChannels() {
    for (final name in List.of(chat.names)) {
      restampChannelEmotes(name);
    }
  }

  /// Heals history baked before its catalog arrived: a full channel commit
  /// restamps that channel, a full global commit restamps all. Version
  /// comparison skips live deltas and config-only updates, which never
  /// bump, so rendered rows keep their freeze outside real data changes.
  void _onCatalogChanged(EmoteChange change) {
    if (change.version == _restampedVersion) return;
    _restampedVersion = change.version;
    final channel = change.channel;
    if (channel != null) {
      restampChannelEmotes(channel);
    } else {
      restampAllChannels();
    }
  }

  /// Detaches the catalog listener. The provider owns teardown.
  void dispose() {
    emoteManager.store.removeListener(_onCatalogChanged);
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
