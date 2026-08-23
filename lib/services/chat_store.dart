import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:clock/clock.dart';

import 'dart:ui' show Color;

import '../models/twitch_message.dart';
import '../util/thread_utils.dart';

/// The account the chat pipeline currently acts as.
class ActiveSession {
  String? login;
  String? userId;
}

/// What changed inside the store; the UI subscribes once and routes each
/// signal to its view bookkeeping (tile-cache eviction, panel refresh).
enum ChatStoreSignal { newContent, channelTouched, messageMutated }

class ChatStoreEvent {
  final ChatStoreSignal signal;
  final String channel;
  final String? messageId;

  const ChatStoreEvent(this.signal, this.channel, {this.messageId});
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
/// One tracked reply thread: the pinned root (null when the root was never
/// seen on screen) plus replies still present in the channel buffer.
class ThreadEntry {
  TwitchMessage? root;
  DateTime lastActivity = DateTime.now();
  final List<TwitchMessage> replies = [];

  bool hasMessage(String messageId) =>
      root?.messageId == messageId ||
      replies.any((r) => r.messageId == messageId);
}

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
    DateTime Function()? now,
    this.truncateCoalesceWindow = const Duration(milliseconds: 250),
  }) : now = now ?? clock.now;

  /// Injectable clock for deterministic tests (truncation + thread LRU).
  final DateTime Function() now;

  /// Minimum interval between full truncation passes on the hot path.
  final Duration truncateCoalesceWindow;

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

  // ---- Change signals -----------------------------------------------------

  final _versions = <String, ValueNotifier<int>>{};
  final _messageCounters = <String, ValueNotifier<int>>{};
  final _events = StreamController<ChatStoreEvent>.broadcast(sync: true);

  /// Fired on every mutation; synchronous so a listener's view bookkeeping
  /// (cache eviction) lands before anything reads it in the same turn.
  Stream<ChatStoreEvent> get events => _events.stream;

  /// Per-channel render epoch: bumped when the whole channel re-renders.
  ValueNotifier<int> versionNotifier(String channel) =>
      _versions.putIfAbsent(channel, () => ValueNotifier(0));

  /// Per-channel content counter: bumped whenever buffer content changes
  /// (new rows or in-place edits).
  ValueNotifier<int> messageCountNotifier(String channel) =>
      _messageCounters.putIfAbsent(channel, () => ValueNotifier(0));

  /// New content landed in [channel] (scroll-position bookkeeping).
  void noteNewMessage(String channel) {
    messageCountNotifier(channel).value++;
    _events.add(ChatStoreEvent(ChatStoreSignal.newContent, channel));
  }

  /// Channel-level state changed (status line, metadata): full re-render.
  void touchChannel(String channel) {
    versionNotifier(channel).value++;
    _events.add(ChatStoreEvent(ChatStoreSignal.channelTouched, channel));
  }

  /// A single message was edited in place ([messageId] null means an uncached
  /// row; nothing to evict).
  void messageMutated(String channel, String? messageId) {
    messageCountNotifier(channel).value++;
    _events.add(
      ChatStoreEvent(
        ChatStoreSignal.messageMutated,
        channel,
        messageId: messageId,
      ),
    );
  }

  /// Drops per-channel notifiers (channel removed from the app).
  void forgetChannel(String channel) {
    _versions.remove(channel)?.dispose();
    _messageCounters.remove(channel)?.dispose();
    _channelThreads.remove(channel);
  }

  void dispose() {
    for (final n in _versions.values) {
      n.dispose();
    }
    for (final n in _messageCounters.values) {
      n.dispose();
    }
    mentionsBump.dispose();
    _events.close();
  }

  // ---- Threads (derived state) -------------------------------------------

  static const _maxTrackedThreadsPerChannel = 64;
  final _channelThreads = <String, Map<String, ThreadEntry>>{};
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

  // ---- Threads ------------------------------------------------------------

  /// Indexes messages into the thread map (idempotent).
  void indexMessages(String channel, Iterable<TwitchMessage> msgs) {
    for (final msg in msgs) {
      _indexThreadMember(channel, msg);
    }
  }

  void _indexThreadMember(String channel, TwitchMessage msg) {
    final id = msg.messageId;
    if (id == null) return;
    final threads = _channelThreads.putIfAbsent(channel, () => {});
    final rootId = msg.replyThreadRootId;

    if (rootId == null || rootId == id) {
      // A potential root: adopt it into an orphan entry created earlier by a
      // reply whose root was not on screen yet.
      final entry = threads[id];
      if (entry != null && entry.root == null && !msg.isSystem) {
        entry.root = msg;
        entry.lastActivity = now();
      }
      return;
    }

    final isNewEntry = !threads.containsKey(rootId);
    final entry = threads.putIfAbsent(rootId, ThreadEntry.new);
    if (entry.hasMessage(id)) return;
    entry.lastActivity = now();
    entry.root ??= _lookupBufferRoot(channel, rootId);
    entry.replies.add(msg);
    if (isNewEntry) _enforceThreadCap(threads);
  }

  // Keeps the per-channel thread map bounded: oldest-touched entries fall off
  // first. Only runs when a new entry pushes past the cap.
  void _enforceThreadCap(Map<String, ThreadEntry> threads) {
    while (threads.length > _maxTrackedThreadsPerChannel) {
      String? oldestKey;
      DateTime? oldestAt;
      for (final e in threads.entries) {
        if (oldestAt == null || e.value.lastActivity.isBefore(oldestAt)) {
          oldestAt = e.value.lastActivity;
          oldestKey = e.key;
        }
      }
      if (oldestKey == null) break;
      threads.remove(oldestKey);
    }
  }

  TwitchMessage? _lookupBufferRoot(String channel, String rootId) {
    final msgs = channelMessages[channel];
    if (msgs == null) return null;
    for (final m in msgs) {
      if (!m.isSystem && m.messageId == rootId) return m;
    }
    return null;
  }

  /// The indexed thread for [rootId], or null when none of its messages were
  /// ever ingested. A pinned root is included even though it may no longer be
  /// in the channel buffer; callers sort by timestamp themselves.
  List<TwitchMessage>? threadFor(String channel, String rootId) {
    final entry = _channelThreads[channel]?[rootId];
    if (entry == null) return null;
    return [if (entry.root != null) entry.root!, ...entry.replies];
  }

  /// Decays evicted messages out of the thread map: replies that left the
  /// channel buffer drop from their entry, while the pinned root survives so
  /// the thread stays viewable after every member has scrolled away.
  void decayEvicted(String channel, Iterable<TwitchMessage> evicted) {
    final threads = _channelThreads[channel];
    if (threads == null || threads.isEmpty) return;
    for (final msg in evicted) {
      final id = msg.messageId;
      if (id == null) continue;
      final rootId = msg.replyThreadRootId;
      // Roots stay pinned; only reply membership decays.
      if (rootId == null || rootId == id) continue;
      final entry = threads[rootId];
      if (entry == null) continue;
      entry.replies.removeWhere((r) => identical(r, msg) || r.messageId == id);
    }
  }

  /// Drops a channel's thread entries (channel removed from the app).
  void clearThreads(String channel) {
    _channelThreads.remove(channel);
  }

  // ---- Truncation ---------------------------------------------------------

  DateTime? _lastTruncateAt;
  static const _truncateHardCapFactor = 2;

  /// Thread-aware buffer pruning: keeps complete reply threads intact even
  /// when most messages are pruned. Walks parent chains (no cycle detection),
  /// identifies active/orphan threads, and removes orphan members as a group.
  void truncateChannel(String channel, {required int maxMessages}) {
    if (maxMessages <= 0) return;
    final msgs = channelMessages[channel];
    if (msgs == null || msgs.length <= maxMessages) return;
    _lastTruncateAt = now();

    // Phase 1: group messages by thread identity.
    final parentOf = <String, String>{};
    for (final m in msgs) {
      if (m.replyToParentId != null && m.messageId != null) {
        parentOf[m.messageId!] = m.replyToParentId!;
      }
    }

    final threadGroups = <String, List<TwitchMessage>>{};
    for (final m in msgs) {
      final key = threadKeyFor(m, parentOf);
      if (key != null) {
        threadGroups.putIfAbsent(key, () => <TwitchMessage>[]).add(m);
      }
    }
    threadGroups.removeWhere((_, ms) => ms.length <= 1);

    // Phase 2: a thread is active if any member sits within the first
    // maxMessages non-system messages (newest-first).
    final activeThreadKeys = <String>{};
    int visibleCount = 0;
    for (final m in msgs) {
      if (m.isSystem) continue;
      if (visibleCount >= maxMessages) break;
      visibleCount++;
      final key = threadKeyFor(m, parentOf);
      if (key != null && threadGroups.containsKey(key)) {
        activeThreadKeys.add(key);
      }
    }

    // Phase 3: collect every message id belonging to an active thread.
    final threadIds = <String>{};
    for (final key in activeThreadKeys) {
      for (final m in threadGroups[key]!) {
        if (m.messageId != null) threadIds.add(m.messageId!);
      }
    }

    // Phase 4: collect indices to keep.
    final keepIndices = <int>{};
    int nonThreadKept = 0;
    for (int i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      final isActiveThread =
          m.messageId != null && threadIds.contains(m.messageId!);
      if (isActiveThread) {
        keepIndices.add(i);
      } else {
        final key = threadKeyFor(m, parentOf);
        final isOrphanThread =
            m.messageId != null &&
            !isActiveThread &&
            key != null &&
            threadGroups.containsKey(key);
        if (!isOrphanThread && nonThreadKept < maxMessages) {
          keepIndices.add(i);
          nonThreadKept++;
        }
      }
    }

    // Phase 5: build retained list in O(n).
    final retained = <TwitchMessage>[];
    final evicted = <TwitchMessage>[];
    for (int i = 0; i < msgs.length; i++) {
      if (keepIndices.contains(i)) {
        retained.add(msgs[i]);
      } else if (msgs[i].messageId != null) {
        // Drop the dedup key for messages that fell off the buffer; the key
        // exists to catch live/history double delivery while a message is on
        // screen, not to accumulate for the whole session.
        messageKeys.remove('$channel:${msgs[i].messageId}');
        evicted.add(msgs[i]);
      }
    }
    // Keep the thread map in sync with the trimmed buffer: replies that fell
    // off decay out of their entry, pinned roots note their eviction.
    if (evicted.isNotEmpty) {
      decayEvicted(channel, evicted);
    }
    msgs
      ..clear()
      ..addAll(retained);
  }

  /// Coalesced variant of [truncateChannel] for the per-message hot path: the
  /// full pass only runs once per coalesce window (or when the buffer balloons
  /// past the hard cap), keeping steady-state cost bounded.
  void truncateWithCoalesce(String channel, {required int maxMessages}) {
    if (maxMessages <= 0) return;
    final msgs = channelMessages[channel];
    if (msgs == null || msgs.length <= maxMessages) return;

    final t = now();
    final sinceLast = _lastTruncateAt == null
        ? null
        : t.difference(_lastTruncateAt!);
    final overHardCap = msgs.length > maxMessages * _truncateHardCapFactor;
    if (sinceLast != null &&
        sinceLast < truncateCoalesceWindow &&
        !overHardCap) {
      return;
    }
    _lastTruncateAt = t;
    truncateChannel(channel, maxMessages: maxMessages);
  }
}
