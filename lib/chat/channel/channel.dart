import 'dart:ui' show Color;

import '../../models/twitch_message.dart';
import 'info.dart';
import 'messages.dart';
import 'moderation.dart';
import 'points.dart';
import 'threads.dart';
import 'unread.dart';

/// Outcome of one live ingest, computed once inside the verb. The caller
/// drives cross-channel aggregates from these flags instead of re-deciding
/// the same rules, so the two can never drift apart.
class ReceiveResult {
  const ReceiveResult({
    required this.inserted,
    required this.mentioned,
    required this.countMention,
    required this.countUnread,
  });

  final bool inserted;

  /// Mention-tier row from someone else: mirror it and notify.
  final bool mentioned;

  /// Mention aggregate rule: mention, not own, not history, not selected.
  final bool countMention;

  /// Bulk unread rule: not selected, not history, not system.
  final bool countUnread;
}

/// One joined channel: composition root for its single-concern owners.
/// Ingest runs here so dedup, truncate, thread index, and unread stay atomic.
class Channel {
  Channel({required this.name, DateTime Function()? now})
    : messages = Messages(channel: name, now: now),
      threads = Threads(now: now),
      unread = Unread(),
      moderation = Moderation(now: now),
      points = Points(),
      info = ChannelInfo();

  final String name;

  /// Read these freely. Mutate only through the [Channel] verbs ([receive],
  /// [receiveHistory], [truncate], [removeMessages]); row-scoped moderation
  /// edits may use the narrow `Messages` verbs. Mutating a child from outside
  /// skips the dedup, decay, index, and unread steps those verbs guarantee.
  final Messages messages;
  final Threads threads;
  final Unread unread;
  final Moderation moderation;
  final Points points;
  final ChannelInfo info;

  /// One live message. Runs children in order: add, decay, index, unread.
  ReceiveResult receive(
    TwitchMessage msg, {
    required int maxMessages,
    required bool isSelected,
    required String? ownLogin,
  }) {
    final change = messages.add(
      msg,
      maxMessages: maxMessages,
      buildExemptions: () => threads.exemptions,
    );
    if (!change.inserted) {
      return const ReceiveResult(
        inserted: false,
        mentioned: false,
        countMention: false,
        countUnread: false,
      );
    }
    threads.decay(change.evicted);
    threads.index([msg], lookupRoot: messages.byId);
    final own =
        ownLogin != null && msg.login.toLowerCase() == ownLogin.toLowerCase();
    final mention = msg.highlight?.hasMention ?? false;
    if (own) {
      return const ReceiveResult(
        inserted: true,
        mentioned: false,
        countMention: false,
        countUnread: false,
      );
    }
    unread.note(
      isMention: mention,
      isHistory: msg.isHistory,
      isSystem: msg.isSystem,
      isSelected: isSelected,
      isOwn: false,
    );
    return ReceiveResult(
      inserted: true,
      mentioned: mention,
      countMention: mention && !msg.isHistory && !isSelected,
      countUnread: !isSelected && !msg.isHistory && !msg.isSystem,
    );
  }

  /// History/backfill batch. No unread or mention counting. Touches activity
  /// and lifts the connect line in the same step, so callers never write
  /// channel children directly.
  List<TwitchMessage> receiveHistory(
    List<TwitchMessage> prepared, {
    required Iterable<TwitchMessage> rawHistory,
    required int maxMessages,
  }) {
    final outcome = messages.mergeHistory(
      prepared,
      rawHistory: rawHistory,
      maxMessages: maxMessages,
      buildExemptions: () => threads.exemptions,
    );
    threads.decay(outcome.evicted);
    if (outcome.inserted.isNotEmpty) {
      threads.index(outcome.inserted, lookupRoot: messages.byId);
    }
    info.touch();
    moveConnectedToTop();
    return outcome.inserted;
  }

  bool moveConnectedToTop() => messages.moveConnectedToTop();

  /// Adds the loading-history line with a stable id so removal is exact.
  void addLoadingHistory() => messages.addSystem(
    'Loading chat history...',
    messageId: Messages.loadingHistoryId,
  );

  /// Removes the loading-history line by its stable id.
  bool removeLoadingHistory() => messages.removeLoadingHistory();

  /// Single writer for the history-loaded flag.
  void setHistoryLoaded(bool loaded) => info.setHistoryLoaded(loaded);

  /// Single writer for the held-moderation queue (channel leave, account switch).
  void clearHeldModeration() => moderation.clearHeld();

  /// Removes every row matching [test] plus its thread index entries in one
  /// step. Returns the removed rows. Blocked-message sweeps use this so a
  /// caller cannot forget the decay.
  List<TwitchMessage> removeMessages(bool Function(TwitchMessage) test) {
    final removed = messages.items.where(test).toList();
    if (removed.isEmpty) return const [];
    messages.removeWhere(test);
    threads.decay(removed);
    return removed;
  }

  /// Standalone prune outside ingest (settings cap change, join progress).
  /// Truncates plus decays in one step; bumps when rows fell off.
  void truncate(int maxMessages) {
    final evicted = messages.truncate(maxMessages, () => threads.exemptions);
    if (evicted.isEmpty) return;
    threads.decay(evicted);
    messages.version.value++;
  }

  /// Inserts a system row and prunes the buffer in one step. Returns false
  /// without pruning when [Messages.addSystem] folded the row away.
  bool addSystemMessage(
    String text, {
    Color? accent,
    String? messageId,
    required int maxMessages,
  }) {
    if (!messages.addSystem(text, accent: accent, messageId: messageId)) {
      return false;
    }
    truncate(maxMessages);
    return true;
  }

  /// Single writer for the join-queue progress row. A null [text] retires the
  /// line; otherwise it is upserted under the stable id. Returns whether the
  /// row changed, and truncates in the same step when it did.
  bool setJoinWait(String? text, {required int maxMessages}) {
    final changed = text == null
        ? messages.removeSystem(Messages.joinWaitId)
        : messages.upsertSystem(text, messageId: Messages.joinWaitId);
    if (!changed) return false;
    truncate(maxMessages);
    return true;
  }

  void clearForAccountSwitch() {
    unread.clearForAccountSwitch();
    moderation.clearForAccountSwitch();
    points.clearForAccountSwitch();
  }

  void dispose() {
    messages.dispose();
    threads.dispose();
    unread.dispose();
    moderation.dispose();
    points.dispose();
    info.dispose();
  }
}
