import 'package:flutter/foundation.dart';

import 'channel/channel.dart';
import 'mentions.dart';

/// Cross-channel chat root: registry and aggregate totals. Per-channel laws
/// live in [Channel]; this owns ordering and drop paths. Identity lives in
/// `Session`, outside the kernel.
class Chat {
  Chat({String mentionsChannel = '@mentions', DateTime Function()? now})
    : _now = now ?? DateTime.now,
      mentions = Mentions(channel: mentionsChannel, now: now);

  final DateTime Function() _now;

  final Map<String, Channel> _channels = {};
  final List<String> _order = [];

  final Mentions mentions;

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
    final channel = Channel(name: name, now: _now);
    _channels[name] = channel;
    _order.add(name);
    return channel;
  }

  void noteMention() {
    _unreadMentions++;
    mentionsBump.value++;
    unreadVersion.value++;
  }

  void noteUnread() {
    unreadVersion.value++;
  }

  /// A whisper arrived while its tab was hidden.
  void noteWhisper() {
    _unreadMentions++;
    mentionsBump.value++;
  }

  /// Whisper traffic that carries no unread (system lines, own sends,
  /// bell-tap clears still refresh the badge).
  void touchMentions() {
    mentionsBump.value++;
  }

  /// The whispers tab consumed [count] unseen whispers.
  void markWhispersSeen(int count) {
    _unreadMentions -= count;
    if (_unreadMentions < 0) _unreadMentions = 0;
    mentionsBump.value++;
  }

  /// Selection cleared one channel's dots. Returns cleared mention count.
  int clearUnread(String channel) {
    final c = _channels[channel];
    if (c == null) return 0;
    final cleared = c.unread.clear();
    if (cleared > 0) {
      _unreadMentions -= cleared;
      if (_unreadMentions < 0) _unreadMentions = 0;
    }
    unreadVersion.value++;
    return cleared;
  }

  void clearAllUnread() {
    for (final c in _channels.values) {
      c.unread.clear();
    }
    _unreadMentions = 0;
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
    _unreadMentions = 0;
    mentionsBump.value++;
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
      _unreadMentions -= droppedMentions;
      if (_unreadMentions < 0) _unreadMentions = 0;
      mentionsBump.value++;
    }
    channel.dispose();
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
    mentionsBump.dispose();
    unreadVersion.dispose();
    loadFailedChannels.dispose();
  }
}
