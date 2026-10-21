import 'package:flutter/foundation.dart';

import '../models/twitch_message.dart';
import 'channel/channel.dart';
import 'channel/messages.dart' show MergeOutcome, SystemLine;
import 'chat_filter.dart';
import 'mentions.dart';

/// Cross-channel chat root: registry and aggregate totals. Per-channel laws
/// live in [Channel]; this owns ordering and drop paths. Identity lives in
/// `Session`, outside the kernel.
class Chat {
  Chat({
    String mentionsChannel = '@mentions',
    DateTime Function()? now,
    this.systemText,
  }) : _now = now ?? DateTime.now,
       mentions = Mentions(channel: mentionsChannel, now: now) {
    filter.changed.add(_recountAll);
  }

  final DateTime Function() _now;

  /// Display text for kernel-authored system rows in every channel.
  final String Function(SystemLine line)? systemText;

  final Map<String, Channel> _channels = {};
  final List<String> _order = [];

  final Mentions mentions;

  /// Rows every channel hides; they are kept, never counted.
  final filter = ChatFilter();

  int _unreadMentions = 0;

  /// Unread mention total across all channels.
  int get unreadMentions => _unreadMentions;
  final ValueNotifier<int> mentionsBump = ValueNotifier(0);
  final ValueNotifier<int> unreadVersion = ValueNotifier(0);

  final ValueNotifier<Set<String>> loadFailedChannels = ValueNotifier(const {});

  List<String> get names => List.unmodifiable(_order);
  int get length => _order.length;
  bool contains(String name) => _channels.containsKey(name);
  Channel? channelFor(String name) => _channels[name];

  void recordLoadFailure(String channel, String kind) {
    _channels[channel]?.info.recordLoadFailure(kind);
    rebuildLoadFailures();
  }

  void clearLoadFailure(String channel, [String? kind]) {
    _channels[channel]?.info.clearLoadFailure(kind);
    rebuildLoadFailures();
  }

  void reorder(List<String> reordered) {
    _order
      ..clear()
      ..addAll(reordered.where(_channels.containsKey));
  }

  Channel ensure(String name) {
    final existing = _channels[name];
    if (existing != null) return existing;
    final channel = Channel(name: name, now: _now, systemText: systemText);
    _channels[name] = channel;
    _order.add(name);
    return channel;
  }

  // ---- Ingest --------------------------------------------------------------

  /// One live message: the channel verb plus the root-owned cross-channel
  /// writes. The root mirrors mention rows into the @mentions buffer and moves
  /// the totals, so callers never perform those writes and the two ingest paths
  /// cannot drift apart.
  ReceiveResult receive(
    String channel,
    TwitchMessage msg, {
    required int maxMessages,
    required bool isSelected,
    required String? ownLogin,
  }) {
    final target = _channels[channel];
    if (target == null) {
      return const ReceiveResult(
        inserted: false,
        mentioned: false,
        countMention: false,
      );
    }
    final result = target.receive(
      msg,
      maxMessages: maxMessages,
      isSelected: isSelected,
      ownLogin: ownLogin,
      hidden: filter.hides(msg),
    );
    if (!result.inserted) return result;
    if (result.mentioned) {
      mirrorMentions([msg], maxMessages: maxMessages);
    }
    if (result.countMention) {
      noteMention();
    } else if (result.unreadFlipped) {
      // A dot already on renders the same, so repeat rows skip the tab rebuild.
      noteUnread();
    }
    return result;
  }

  /// One history batch: the channel verb plus the root-owned mention mirror.
  /// Backfill never counts unread, and own rows are not mirrored, so live and
  /// history share one mention predicate.
  MergeOutcome receiveHistory(
    String channel,
    List<TwitchMessage> prepared, {
    required Iterable<TwitchMessage> rawHistory,
    required int maxMessages,
    required String? ownLogin,
  }) {
    final outcome = ensure(channel).receiveHistory(
      prepared,
      rawHistory: rawHistory,
      maxMessages: maxMessages,
    );
    final mirrored = [
      for (final m in outcome.inserted)
        if (_isMentionRow(m, ownLogin)) m,
    ];
    if (mirrored.isNotEmpty) {
      mirrorMentions(mirrored, maxMessages: maxMessages);
    }
    return outcome;
  }

  /// Single writer for the @mentions mirror. Live ingest, history backfill, and
  /// the retroactive scan all route through it.
  void mirrorMentions(List<TwitchMessage> rows, {required int maxMessages}) {
    mentions.add(rows, maxMessages: maxMessages);
  }

  void _recountAll() {
    for (final c in _channels.values) {
      _recountUnread(c);
    }
  }

  /// Recomputes a channel's unread mention count from the rows it still
  /// shows after a rule change. Dots survive only while a countable mention
  /// row remains.
  void _recountUnread(Channel c) {
    final unread = c.unread;
    final before = unread.mentionCount;
    if (before == 0) return;
    final remaining = c.messages.items
        .where(
          (m) =>
              !m.isSystem &&
              !m.isHistory &&
              (m.highlight?.hasMention ?? false) &&
              !filter.hides(m),
        )
        .length;
    final dropped = unread.dropMentions(remaining);
    if (dropped == 0) return;
    _setUnreadMentions(_unreadMentions - dropped);
    unreadVersion.value++;
  }

  bool _isMentionRow(TwitchMessage m, String? ownLogin) {
    if (!(m.highlight?.hasMention ?? false) || filter.hides(m)) return false;
    return ownLogin == null || m.login.toLowerCase() != ownLogin.toLowerCase();
  }

  // ---- Aggregates ----------------------------------------------------------

  /// Single writer for [unreadMentions]. Every real change bumps [mentionsBump]
  /// so the bell can never go stale; callers that also move channel dots bump
  /// [unreadVersion] themselves.
  void _setUnreadMentions(int value) {
    final next = value < 0 ? 0 : value;
    if (next == _unreadMentions) return;
    _unreadMentions = next;
    mentionsBump.value++;
  }

  void noteMention() {
    _setUnreadMentions(_unreadMentions + 1);
    unreadVersion.value++;
  }

  void noteUnread() {
    unreadVersion.value++;
  }

  /// A whisper arrived while its tab was hidden.
  void noteWhisper() {
    _setUnreadMentions(_unreadMentions + 1);
  }

  /// Whisper traffic that carries no unread (system lines, own sends,
  /// bell-tap clears still refresh the badge).
  void touchMentions() {
    mentionsBump.value++;
  }

  /// The whispers tab consumed [count] unseen whispers.
  void markWhispersSeen(int count) {
    _setUnreadMentions(_unreadMentions - count);
  }

  /// Selection cleared one channel's dots. Returns cleared mention count.
  int clearUnread(String channel) {
    final c = _channels[channel];
    if (c == null) return 0;
    final unread = c.unread;
    if (!unread.hasUnread && !unread.hasMention) return 0;
    final cleared = unread.clear();
    if (cleared > 0) {
      _setUnreadMentions(_unreadMentions - cleared);
    }
    unreadVersion.value++;
    return cleared;
  }

  void clearAllUnread() {
    for (final c in _channels.values) {
      c.unread.clear();
    }
    _setUnreadMentions(0);
    unreadVersion.value++;
  }

  /// Rebuilds the load-failure aggregate from per-channel info.
  void rebuildLoadFailures() {
    final next = <String>{};
    for (final entry in _channels.entries) {
      if (entry.value.info.hasLoadFailure) next.add(entry.key);
    }
    loadFailedChannels.value = next;
  }

  /// Drops account-scoped per-channel state on an account switch. Keeps
  /// messages, threads, and saved bookmarks; identity lives in `Session`.
  void clearAccountScopedState() {
    for (final c in _channels.values) {
      c.clearForAccountSwitch();
    }
    mentions.clearForAccountSwitch();
    _setUnreadMentions(0);
    unreadVersion.value++;
    rebuildLoadFailures();
  }

  /// The only way to remove a channel. Frees all per-channel state.
  void remove(String name) {
    final channel = _channels.remove(name);
    if (channel == null) return;
    _order.remove(name);
    final droppedMentions = channel.unread.mentionCount;
    if (droppedMentions > 0) {
      _setUnreadMentions(_unreadMentions - droppedMentions);
    }
    channel.dispose();
    mentions.removeWhere((m) => m.channel == name);
    unreadVersion.value++;
    rebuildLoadFailures();
  }

  void dispose() {
    for (final c in _channels.values) {
      c.dispose();
    }
    _channels.clear();
    _order.clear();
    mentions.dispose();
    filter.changed.clear();
    mentionsBump.dispose();
    unreadVersion.dispose();
    loadFailedChannels.dispose();
  }
}
