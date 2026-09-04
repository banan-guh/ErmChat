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

/// Requests that are pure UI effects rather than state changes (a toast,
/// keyboard focus). The pipeline emits them; the view layer translates.
enum ChatNoticeKind { info, focusInput }

class ChatNotice {
  final ChatNoticeKind kind;
  final String? message;

  const ChatNotice.info(this.message) : kind = ChatNoticeKind.info;
  const ChatNotice.focusInput()
    : kind = ChatNoticeKind.focusInput,
      message = null;
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

/// Read-only summary of one tracked thread for the threads dashboard. The
/// dashboard is per-channel and sorted by [lastActivity] (newest first).
class ThreadSummary {
  final String rootId;
  final TwitchMessage? root;
  final DateTime lastActivity;
  final int replyCount;

  const ThreadSummary({
    required this.rootId,
    required this.root,
    required this.lastActivity,
    required this.replyCount,
  });
}

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

  /// Per-channel data-load failures (emotes/badges/history) that the user can
  /// retry. Keyed by channel; the inner set lists which loads failed.
  final Map<String, Set<String>> channelLoadFailures = {};

  /// Channels with at least one failed data load, for UI retry affordances.
  final ValueNotifier<Set<String>> loadFailedChannels = ValueNotifier(const {});

  void recordLoadFailure(String channel, String kind) {
    final set = channelLoadFailures.putIfAbsent(channel, () => {});
    final added = set.add(kind);
    if (added && !loadFailedChannels.value.contains(channel)) {
      loadFailedChannels.value = {...loadFailedChannels.value, channel};
    }
  }

  void clearLoadFailure(String channel, [String? kind]) {
    final set = channelLoadFailures[channel];
    if (set == null) return;
    if (kind != null) set.remove(kind);
    if (kind == null || set.isEmpty) channelLoadFailures.remove(channel);
    loadFailedChannels.value = {
      ...channelLoadFailures.keys.where(
        (c) => channelLoadFailures[c]!.isNotEmpty,
      ),
    };
  }

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

  /// Bumped whenever a channel enters or leaves the unread (or unread-mention)
  /// sets, so tab labels rebuild only when their unread membership changes
  /// instead of on every incoming message.
  final ValueNotifier<int> unreadVersion = ValueNotifier(0);

  /// Pipeline-path login write: assigns and fires [onLoginApplied].
  void applyLogin(String? login) {
    session.login = login;
    onLoginApplied?.call(login);
  }

  // ---- Change signals -----------------------------------------------------

  final _versions = <String, ValueNotifier<int>>{};
  final _messageCounters = <String, ValueNotifier<int>>{};
  final _events = StreamController<ChatStoreEvent>.broadcast(sync: true);
  final _notices = StreamController<ChatNotice>.broadcast(sync: true);

  /// Fired on every mutation; synchronous so a listener's view bookkeeping
  /// (cache eviction) lands before anything reads it in the same turn.
  Stream<ChatStoreEvent> get events => _events.stream;

  /// UI-effect requests emitted by the pipeline; the view translates them.
  Stream<ChatNotice> get notices => _notices.stream;

  /// Pipeline asks for a toast. The store does not decide copy beyond what
  /// the caller passes.
  void notifyInfo(String message) {
    _notices.add(ChatNotice.info(message));
  }

  /// Pipeline asks for the composer to take keyboard focus.
  void requestComposerFocus() {
    _notices.add(const ChatNotice.focusInput());
  }

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
    messageKeys.removeWhere((k) => k.startsWith('$channel:'));
    savedThreadKeys.removeWhere((k) => k.startsWith('$channel:'));
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
    _notices.close();
  }

  // ---- Threads (derived state) -------------------------------------------

  static const _maxTrackedThreadsPerChannel = 64;
  final _channelThreads = <String, Map<String, ThreadEntry>>{};

  /// Saved threads (`$channel:$rootId`, channel lowercased) are exempt from
  /// truncation, decay, and the per-channel thread cap: a saved thread keeps
  /// every message in memory and on disk forever. HomeScreen syncs this set
  /// from SavedThreadsStore after each toggle/load.
  final Set<String> savedThreadKeys = {};
  int _nextSystemMessageId = 0;

  /// Inserts a system message at the top of [channel]'s buffer, applying the
  /// status-marker folding rules: Connected/Disconnected/Reconnected lines
  /// replace or dedup each other instead of stacking on socket flaps.
  /// [messageId] carries a stable event identity (USERNOTICE labels); when
  /// provided and already present on a buffered row the insert is skipped so
  /// backfill cannot double an event that arrived live. Returns false when
  /// folding dropped the message entirely (no insert happened); callers skip
  /// their truncate/notify signals in that case.
  bool addSystemMessage(
    String channel,
    String text, {
    Color? accent,
    String? messageId,
  }) {
    final msgs = channelMessages.putIfAbsent(channel, () => []);

    if (messageId != null) {
      final exists = msgs.any((m) => m.isSystem && m.messageId == messageId);
      if (exists) return false;
    }

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
        messageId: messageId ?? 'sys_${_nextSystemMessageId++}',
        isSystem: true,
        systemAccent: accent,
        channel: channel,
      ),
    );
    return true;
  }

  /// Updates the system row carrying [messageId] in place, inserting it at
  /// the top of [channel]'s buffer when absent. Built for live progress
  /// markers (join-queue countdowns) whose text changes every tick; no
  /// status folding applies. Returns true when the buffer changed.
  bool upsertSystemMessage(
    String channel,
    String text, {
    required String messageId,
    Color? accent,
  }) {
    final msgs = channelMessages.putIfAbsent(channel, () => []);
    for (final m in msgs) {
      if (m.isSystem && m.messageId == messageId) {
        if (m.text == text) return false;
        m.text = text;
        return true;
      }
    }
    msgs.insert(
      0,
      TwitchMessage(
        login: '',
        text: text,
        messageId: messageId,
        isSystem: true,
        systemAccent: accent,
        channel: channel,
      ),
    );
    return true;
  }

  /// Removes the system row carrying [messageId]; returns true when a row
  /// went away. Retires transient markers (e.g. a join countdown once the
  /// channel confirms).
  bool removeSystemMessage(String channel, String messageId) {
    final msgs = channelMessages[channel];
    if (msgs == null || msgs.isEmpty) return false;
    final before = msgs.length;
    msgs.removeWhere((m) => m.isSystem && m.messageId == messageId);
    return msgs.length != before;
  }

  /// Kernel ingestion verb for one already-gated live message. Dedups against
  /// [messageKeys] (returns false and mutates nothing on a duplicate),
  /// applies unread/mention bookkeeping, inserts into the channel buffer,
  /// mirrors mention-tier highlights into [mentionsChannel], indexes threads,
  /// schedules coalesced truncation at [maxMessages], and fires
  /// [noteNewMessage]. Returns true when the message was inserted.
  bool ingestMessage(
    TwitchMessage msg, {
    required int maxMessages,
    String? selectedChannel,
    String? mentionsChannel,
  }) {
    final channel = msg.channel;
    if (channel == null) return false;

    if (msg.messageId != null &&
        messageKeys.contains('$channel:${msg.messageId}')) {
      return false;
    }

    final login = session.login?.toLowerCase();
    final state = msg.highlight;
    if (state != null && state.hasMention && msg.login != login) {
      if (!msg.isHistory && channel != selectedChannel) {
        unreadMentions++;
        mentionsBump.value++;
        channelsWithUnreadMentions.add(channel);
        unreadVersion.value++;
        unreadMentionsPerChannel[channel] =
            (unreadMentionsPerChannel[channel] ?? 0) + 1;
      }
    }

    channelMessages.putIfAbsent(channel, () => []);
    channelMessages[channel]!.insert(0, msg);
    truncateWithCoalesce(channel, maxMessages: maxMessages);

    if (msg.messageId != null) {
      messageKeys.add('$channel:${msg.messageId}');
    }
    indexMessages(channel, [msg]);

    // Only mention-tier highlights land in the mentions tab; event tints
    // (redemptions, first messages, ...) stay in the channel only.
    if (state != null && state.hasMention && mentionsChannel != null) {
      mirrorMentions(mentionsChannel, [msg], maxMessages: maxMessages);
    }

    if (channel != selectedChannel && !msg.isHistory && !msg.isSystem) {
      channelsWithUnread.add(channel);
      unreadVersion.value++;
    }
    noteNewMessage(channel);
    return true;
  }

  /// Kernel verb mirroring mention-tier messages into the @mentions buffer:
  /// dedupes against the buffer by message id (null-id messages always add),
  /// keeps the buffer sorted newest-first regardless of caller iteration
  /// order, and caps it at [maxMessages].
  void mirrorMentions(
    String mentionsChannel,
    List<TwitchMessage> msgs, {
    required int maxMessages,
  }) {
    if (msgs.isEmpty) return;
    channelMessages.putIfAbsent(mentionsChannel, () => []);
    final list = channelMessages[mentionsChannel]!;
    final seen = {
      for (final m in list)
        if (m.messageId != null) m.messageId!,
    };
    final added = <TwitchMessage>[];
    for (final msg in msgs) {
      final id = msg.messageId;
      if (id != null && !seen.add(id)) continue;
      added.add(msg);
    }
    if (added.isEmpty) return;
    list.addAll(added);
    // Callers iterate buffers and history batches in arbitrary directions;
    // sorting once here keeps every writer to a single ordering contract.
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (list.length > maxMessages) {
      list.removeRange(maxMessages, list.length);
    }
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
    if (id == null || msg.isSystem) return;
    final threads = _channelThreads.putIfAbsent(channel, () => {});
    final rootId = msg.replyThreadRootId;

    if (rootId == null || rootId == id) {
      // A potential root: adopt it into an orphan entry created earlier by a
      // reply whose root was not on screen yet. Adoption alone is not new
      // activity, so lastActivity stays put.
      final entry = threads[id];
      if (entry != null && entry.root == null && !msg.isSystem) {
        entry.root = msg;
      } else if (entry != null && entry.root != null) {
        // Fresher instance of an already-pinned root (history + live dup):
        // carry over mutation flags instead of freezing the stale object.
        entry.root!.deleted = entry.root!.deleted || msg.deleted;
        if (entry.root!.text != msg.text && msg.text.isNotEmpty) {
          entry.root!.text = msg.text;
        }
      }
      return;
    }

    final isNewEntry = !threads.containsKey(rootId);
    final entry = threads.putIfAbsent(
      rootId,
      () => ThreadEntry()..lastActivity = now(),
    );
    if (entry.hasMessage(id)) return;
    entry.lastActivity = now();
    entry.root ??= _lookupBufferRoot(channel, rootId);
    entry.replies.add(msg);
    if (isNewEntry) _enforceThreadCap(channel, threads);
  }

  // Keeps the per-channel thread map bounded: oldest-touched non-saved
  // entries fall off first. Saved threads never count toward the cap.
  void _enforceThreadCap(String channel, Map<String, ThreadEntry> threads) {
    while (true) {
      final unsaved = threads.entries
          .where((e) => !savedThreadKeys.contains('$channel:${e.key}'))
          .toList();
      if (unsaved.length <= _maxTrackedThreadsPerChannel) break;
      unsaved.sort(
        (a, b) => a.value.lastActivity.compareTo(b.value.lastActivity),
      );
      threads.remove(unsaved.first.key);
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

  /// Live thread overview for [channel], newest activity first. Only threads
  /// with more than one reply are listed (single replies stay reachable via
  /// the message menu's View thread, but don't earn a dashboard row).
  /// Decayed entries (pinned root whose replies all scrolled away) and empty
  /// ones are skipped; orphan entries (replies seen before their root) are
  /// included so the dashboard never hides a live thread.
  List<ThreadSummary> activeThreads(String channel) {
    final threads = _channelThreads[channel];
    if (threads == null || threads.isEmpty) return const [];
    final out = <ThreadSummary>[];
    for (final e in threads.entries) {
      if (e.value.replies.length <= 1) continue;
      out.add(
        ThreadSummary(
          rootId: e.key,
          root: e.value.root,
          lastActivity: e.value.lastActivity,
          replyCount: e.value.replies.length,
        ),
      );
    }
    out.sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
    return out;
  }

  /// Decays evicted messages out of the thread map: replies that left the
  /// channel buffer drop from their entry. Saved threads never decay, and
  /// entries whose replies all decayed are reaped so they stop occupying a
  /// cap slot. Pinned roots of unsaved threads survive for the single-thread
  /// view but hide from the dashboard (see [activeThreads]).
  void decayEvicted(String channel, Iterable<TwitchMessage> evicted) {
    final threads = _channelThreads[channel];
    if (threads == null || threads.isEmpty) return;
    for (final msg in evicted) {
      final id = msg.messageId;
      if (id == null) continue;
      final rootId = msg.replyThreadRootId;
      // Roots stay pinned; only reply membership decays.
      if (rootId == null || rootId == id) continue;
      if (savedThreadKeys.contains('$channel:$rootId')) continue;
      final entry = threads[rootId];
      if (entry == null) continue;
      entry.replies.removeWhere((r) => identical(r, msg) || r.messageId == id);
      if (entry.replies.isEmpty && entry.root == null) {
        threads.remove(rootId);
      }
    }
  }

  /// Marks every non-system message from [login] in [channel] as deleted
  /// (bans, timeouts) and signals once.
  void markUserMessagesDeleted(String channel, String login) {
    final msgs = channelMessages[channel];
    if (msgs == null) return;
    var touched = false;
    for (final msg in msgs) {
      if (msg.login == login.toLowerCase() && !msg.isSystem && !msg.deleted) {
        msg.deleted = true;
        touched = true;
      }
    }
    if (touched) touchChannel(channel);
  }

  /// Newest-first non-system messages from [login] in [channel].
  List<TwitchMessage> recentMessagesFromUser(
    String channel,
    String login, {
    int limit = 50,
  }) {
    final want = login.toLowerCase();
    if (want.isEmpty || limit <= 0) return [];
    final msgs = channelMessages[channel];
    if (msgs == null) return [];
    final out = <TwitchMessage>[];
    for (final msg in msgs) {
      if (out.length >= limit) break;
      if (msg.isSystem || msg.login.toLowerCase() != want) continue;
      out.add(msg);
    }
    return out;
  }

  /// Marks the non-system message with [messageId] as deleted (CLEARMSG,
  /// mod deletes). Returns false when no such live row exists.
  bool markMessageDeleted(String channel, String messageId) {
    final msgs = channelMessages[channel];
    if (msgs == null) return false;
    for (final msg in msgs) {
      if (msg.messageId == messageId && !msg.isSystem && !msg.deleted) {
        msg.deleted = true;
        messageMutated(channel, msg.messageId);
        return true;
      }
    }
    return false;
  }

  /// Marks every non-system message in the buffer deleted (/clear, EventSub
  /// clear). Emits no signal; callers repaint via touchChannel.
  void markAllMessagesDeleted(String channel) {
    final msgs = channelMessages[channel];
    if (msgs == null) return;
    for (final m in msgs) {
      if (!m.isSystem) m.deleted = true;
    }
  }

  /// Edits a message body in place (ban-stack text folding) and signals it.
  void updateMessageText(String channel, String messageId, String newText) {
    final msgs = channelMessages[channel];
    if (msgs == null) return;
    for (final m in msgs) {
      if (m.messageId == messageId) {
        m.text = newText;
        messageMutated(channel, messageId);
        return;
      }
    }
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

    // Saved threads are exempt from pruning entirely: every member stays in
    // memory (and on disk via SavedThreadsStore) forever, outside the
    // maxMessages budget.
    final savedIds = <String>{};
    for (final entry in threadGroups.entries) {
      if (savedThreadKeys.contains('$channel:${entry.key}')) {
        for (final m in entry.value) {
          if (m.messageId != null) savedIds.add(m.messageId!);
        }
      }
    }

    // Phase 4: collect indices to keep. System markers ride along for free;
    // only chat messages spend the maxMessages budget.
    final keepIndices = <int>{};
    int nonThreadKept = 0;
    for (int i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      if (m.isSystem) {
        keepIndices.add(i);
        continue;
      }
      final isSavedThread =
          m.messageId != null && savedIds.contains(m.messageId!);
      final isActiveThread =
          m.messageId != null && threadIds.contains(m.messageId!);
      if (isSavedThread || isActiveThread) {
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
