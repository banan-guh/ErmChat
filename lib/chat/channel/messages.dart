import 'dart:collection';
import 'dart:ui' show Color;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;

import '../../emotes/emote.dart';
import '../../models/twitch_message.dart';
import '../../util/thread_utils.dart';

/// Thread exemptions passed into truncation from the thread index: saved roots
/// and on-screen pinned message ids never count toward the buffer budget.
class TruncateExemptions {
  const TruncateExemptions({
    this.savedRootIds = const {},
    this.pinnedMessageIds = const {},
  });

  final Set<String> savedRootIds;
  final Set<String> pinnedMessageIds;

  static const empty = TruncateExemptions();
}

/// Result of a buffer mutation that may have trimmed the list.
class BufferChange {
  const BufferChange({this.inserted = false, this.evicted = const []});

  final bool inserted;
  final List<TwitchMessage> evicted;
}

/// Result of a history merge: rows that were actually inserted (callers mirror
/// mention-tier ones) plus rows trimmed out of the buffer (callers decay them
/// out of the thread index).
class MergeOutcome {
  const MergeOutcome({required this.inserted, required this.evicted});

  final List<TwitchMessage> inserted;
  final List<TwitchMessage> evicted;
}

/// One channel's message buffer and its laws: newest-first ordering, dedup,
/// system-line folding, coalesced thread-aware truncation, and in-place
/// mutations. Owns no policy: callers filter, rewrite, and evaluate pings
/// before handing a message or batch in.
class Messages {
  Messages({
    required this.channel,
    DateTime Function()? now,
    this.truncateCoalesceWindow = const Duration(milliseconds: 250),
  }) : now = now ?? clock.now;

  /// Channel this buffer belongs to. Stamped onto system rows because
  /// [TwitchMessage.channel] is final and downstream keys on it.
  final String channel;
  final DateTime Function() now;
  final Duration truncateCoalesceWindow;

  final List<TwitchMessage> _items = [];
  final Set<String> _seenIds = {};
  DateTime? _lastTruncateAt;
  int _nextSystemMessageId = 0;

  /// Bumped on any list change (insert, trim, bulk delete). Drives row lists.
  final ValueNotifier<int> version = ValueNotifier(0);

  /// Lossless, synchronous fan-out of in-place mutation ids. A ValueNotifier
  /// would coalesce two different ids mutated in one frame (a raid deleting
  /// many rows at once), leaving stale tiles. Null id means an uncached row
  /// changed and consumers no-op. This is the one typed mutation channel; it
  /// is not a generic event bus.
  final MessageMutations mutations = MessageMutations();

  static const _truncateHardCapFactor = 2;
  static const _systemDedupWindow = Duration(seconds: 10);

  /// A recovery announced within this window of the previous one is the same
  /// outage flapping, so it folds instead of stacking another line.
  static const _reconnectFoldWindow = Duration(seconds: 30);

  /// Per-thread member cap applied during truncation.
  static const maxPinnedThreadMembers = 20;

  /// Connect-state rows carry a stable `sys_conn:<state>` id, so folding and
  /// lookup never match on user-visible copy. The map keys the incoming status
  /// text to its state.
  static const _connIdPrefix = 'sys_conn:';
  static const _statusStateByText = {
    'Connected': 'connected',
    'Connected to IRC': 'connected',
    'Disconnected': 'disconnected',
    'Reconnected': 'reconnected',
    'Chat reconnecting...': 'reconnecting',
  };

  /// Stable id for the loading-history row.
  static const loadingHistoryId = 'sys_loading';

  /// Stable id for the join-queue progress row.
  static const joinWaitId = 'join_wait';
  static const _gapNoteText = 'History: Not all messages retrieved';

  static String _connId(String state) => '$_connIdPrefix$state';
  static bool _isConnRow(TwitchMessage m) =>
      m.isSystem && (m.messageId?.startsWith(_connIdPrefix) ?? false);

  // ---- Reads ---------------------------------------------------------------

  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;
  UnmodifiableListView<TwitchMessage> get items => UnmodifiableListView(_items);

  bool containsId(String id) => _seenIds.contains(id);

  TwitchMessage? byId(String id) {
    for (final m in _items) {
      if (m.messageId == id) return m;
    }
    return null;
  }

  // ---- Live ingest ---------------------------------------------------------

  /// Dedup by message id, insert at the top, and coalesced-truncate. Returns
  /// whether the row was inserted plus anything trimmed out. Exemptions are
  /// built lazily: [buildExemptions] runs only when a truncate pass runs,
  /// never on the steady-state path.
  BufferChange add(
    TwitchMessage msg, {
    required int maxMessages,
    TruncateExemptions Function()? buildExemptions,
  }) {
    final id = msg.messageId;
    if (id != null && _seenIds.contains(id)) {
      return const BufferChange();
    }
    _items.insert(0, msg);
    if (id != null) _seenIds.add(id);
    final evicted = _maybeTruncate(maxMessages, buildExemptions);
    _bump();
    return BufferChange(inserted: true, evicted: evicted);
  }

  /// Inserts [msg] directly after (older than) the row carrying [targetId],
  /// so a late redemption header lands above its chat line in display order.
  /// Misses when the target is gone or the header id is a duplicate.
  BufferChange insertAfter(
    String targetId,
    TwitchMessage msg, {
    required int maxMessages,
    TruncateExemptions Function()? buildExemptions,
  }) {
    final id = msg.messageId;
    if (id != null && _seenIds.contains(id)) {
      return const BufferChange();
    }
    final target = _items.indexWhere((m) => m.messageId == targetId);
    if (target < 0) return const BufferChange();
    _items.insert(target + 1, msg);
    if (id != null) _seenIds.add(id);
    final evicted = _maybeTruncate(maxMessages, buildExemptions);
    _bump();
    return BufferChange(inserted: true, evicted: evicted);
  }

  // ---- History merge -------------------------------------------------------

  /// Merges an already-filtered, already-rewritten history batch. Owns buffer
  /// laws only: dedup against the buffer and the batch, id-less system folding,
  /// terminal newest-first sort, the gap note, and one truncate. Unread and
  /// mention counting are the caller's problem and are suppressed here.
  MergeOutcome mergeHistory(
    List<TwitchMessage> prepared, {
    required Iterable<TwitchMessage> rawHistory,
    required int maxMessages,
    TruncateExemptions Function()? buildExemptions,
  }) {
    if (prepared.isEmpty) return const MergeOutcome(inserted: [], evicted: []);
    final existingIds = _items.map((m) => m.messageId).toSet();
    final hasExistingNonSystem = _items.any((m) => !m.isSystem);

    final inserted = <TwitchMessage>[];
    final insertedIds = <String?>{};
    for (final msg in prepared) {
      final id = msg.messageId;
      if (id == null &&
          msg.isSystem &&
          _isDuplicateIdlessSystemRow(_items, inserted, msg)) {
        continue;
      }
      final isNew =
          id == null ||
          (!existingIds.contains(id) && !insertedIds.contains(id));
      if (isNew) {
        if (id != null) insertedIds.add(id);
        _items.add(msg);
        inserted.add(msg);
      }
      if (id != null) _seenIds.add(id);
    }

    if (hasExistingNonSystem &&
        inserted.isNotEmpty &&
        // Overlap is checked against the raw fetch, not the filtered batch:
        // an ignored row that overlapped the buffer must still suppress the
        // gap note.
        !rawHistory.any(
          (m) => m.messageId != null && existingIds.contains(m.messageId),
        )) {
      // Timestamp comes from the oldest raw row, not the oldest prepared
      // row: an ignored oldest row must still anchor the note below it.
      final rawList = rawHistory.toList();
      final anchor = rawList.isEmpty ? prepared : rawList;
      final oldestHistory = anchor
          .map((m) => m.timestamp)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      _items.add(
        TwitchMessage(
          login: '',
          text: _gapNoteText,
          isSystem: true,
          channel: channel,
          timestamp: oldestHistory.subtract(const Duration(milliseconds: 1)),
        ),
      );
    }

    _sortNewestFirst();
    final evicted = truncate(maxMessages, buildExemptions);
    final evictedSet = evicted.toSet();
    // A row that was inserted and then trimmed is not resident, so it must not
    // reach the thread index; otherwise the index keeps ghost entries.
    final resident = [
      for (final m in inserted)
        if (!evictedSet.contains(m)) m,
    ];
    _bump();
    return MergeOutcome(inserted: resident, evicted: evicted);
  }

  /// Re-resolves history rows baked before their catalog landed. Only
  /// history rows holding empty tokens are candidates; live rows and
  /// resolved rows keep their tokens, so later catalog deltas never rewrite
  /// the visible buffer. Empty reparse results are not assigned, so
  /// pure-text rows rescan without churning. Bumps [version] and emits one
  /// mutation per touched id (a whole-channel evict when an id-less row
  /// changed). Returns how many rows healed.
  int restampHistoryEmotes(
    List<EmoteToken>? Function(TwitchMessage msg) resolve,
  ) {
    final touchedIds = <String>[];
    var touchedIdless = false;
    var healed = 0;
    for (final msg in _items) {
      if (msg.isSystem || !msg.isHistory) continue;
      final tokens = msg.emoteTokens;
      if (tokens == null || tokens.isNotEmpty) continue;
      final resolved = resolve(msg);
      if (resolved == null || resolved.isEmpty) continue;
      msg.emoteTokens = resolved;
      healed++;
      final id = msg.messageId;
      if (id != null) {
        touchedIds.add(id);
      } else {
        touchedIdless = true;
      }
    }
    if (healed == 0) return 0;
    _bump();
    if (touchedIdless) {
      mutations.emitAll();
    } else {
      for (final id in touchedIds) {
        mutations.emit(id);
      }
    }
    return healed;
  }

  /// Merges mention-tier rows into this (the @mentions pseudo) buffer: dedup by
  /// id, sort newest-first, cap. No signals beyond [version].
  void mergeMentions(List<TwitchMessage> msgs, {required int maxMessages}) {
    if (msgs.isEmpty) return;
    final seen = {
      for (final m in _items)
        if (m.messageId != null) m.messageId!,
    };
    final added = <TwitchMessage>[];
    for (final msg in msgs) {
      final id = msg.messageId;
      if (id != null && !seen.add(id)) continue;
      added.add(msg);
    }
    if (added.isEmpty) return;
    _items.addAll(added);
    _sortNewestFirst();
    if (_items.length > maxMessages) {
      _items.removeRange(maxMessages, _items.length);
    }
    _bump();
  }

  // ---- System lines --------------------------------------------------------

  /// Inserts a system row at the top, applying status folding (Connected /
  /// Disconnected / Reconnected / reconnecting) and id-less text dedup.
  /// Returns false when folding dropped it.
  bool addSystem(String text, {Color? accent, String? messageId}) {
    if (messageId != null &&
        _items.any((m) => m.isSystem && m.messageId == messageId)) {
      return false;
    }

    final state = _statusStateByText[text];
    if (state != null) {
      var resolved = state;
      if (resolved == 'connected') {
        final hasPriorStatus = _items.any(_isConnRow);
        resolved = hasPriorStatus ? 'reconnected' : 'connected';
        text = hasPriorStatus ? 'Reconnected' : 'Connected';
      }
      final top = _items.isEmpty ? null : _items.first;
      if (resolved == 'reconnected') {
        var newestRecovery = -1;
        for (var i = 0; i < _items.length; i++) {
          final m = _items[i];
          if (_isConnRow(m) && m.messageId == _connId('reconnected')) {
            newestRecovery = i;
            break;
          }
        }
        // A recovery close to the previous one is the same outage flapping,
        // not a new event. Chat since an older recovery keeps both lines.
        final recentRecovery =
            newestRecovery != -1 &&
            now().difference(_items[newestRecovery].timestamp).abs() <=
                _reconnectFoldWindow;
        final hasActivity =
            !recentRecovery &&
            newestRecovery != -1 &&
            _items.take(newestRecovery).any((m) => !_isConnRow(m));
        // The transient outage marker never survives a recovery.
        final before = _items.length;
        _items.removeWhere(
          (m) =>
              m.isSystem &&
              (m.messageId == _connId('disconnected') ||
                  m.messageId == _connId('reconnecting')),
        );
        if (recentRecovery) {
          if (_items.length != before) _bump();
          return false;
        }
        if (!hasActivity) {
          _items.removeWhere(
            (m) => m.isSystem && m.messageId == _connId('reconnected'),
          );
        }
      } else if (resolved == 'disconnected' || resolved == 'reconnecting') {
        if (resolved == 'reconnecting') {
          final hasDisconnected = _items.any(
            (m) => m.isSystem && m.messageId == _connId('disconnected'),
          );
          if (hasDisconnected) return false;
          if (top != null && top.messageId == _connId('reconnecting')) {
            return false;
          }
        } else {
          if (top != null && top.messageId == _connId('disconnected')) {
            return false;
          }
          _items.removeWhere(
            (m) => m.isSystem && m.messageId == _connId('reconnecting'),
          );
        }
      }
      messageId = _connId(resolved);
    }

    if (messageId == null && state == null) {
      final at = now();
      for (final m in _items) {
        if (!m.isSystem || m.text != text) continue;
        final id = m.messageId;
        if (id != null && !id.startsWith('sys_')) continue;
        if (at.difference(m.timestamp).abs() <= _systemDedupWindow) {
          return false;
        }
      }
    }

    _items.insert(
      0,
      TwitchMessage(
        login: '',
        text: text,
        messageId: messageId ?? 'sys_${_nextSystemMessageId++}',
        isSystem: true,
        systemAccent: accent,
        channel: channel,
        timestamp: now(),
      ),
    );
    _bump();
    return true;
  }

  /// Updates the system row carrying [messageId] in place, inserting it when
  /// absent. Bumps [version] and emits the id in both cases; callers must
  /// not bump or evict again. Returns true when the buffer changed.
  bool upsertSystem(String text, {required String messageId, Color? accent}) {
    for (final m in _items) {
      if (m.isSystem && m.messageId == messageId) {
        if (m.text == text) return false;
        m.text = text;
        _noteMutation(messageId);
        return true;
      }
    }
    _items.insert(
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
    _noteMutation(messageId);
    return true;
  }

  /// Removes the system row carrying [messageId]. Returns true when one went.
  bool removeSystem(String messageId) {
    final before = _items.length;
    _items.removeWhere((m) => m.isSystem && m.messageId == messageId);
    final changed = _items.length != before;
    if (changed) _bump();
    return changed;
  }

  /// Removes every row matching [test]. Returns the number removed.
  int removeWhere(bool Function(TwitchMessage) test) {
    final before = _items.length;
    _items.removeWhere((m) {
      if (!test(m)) return false;
      final id = m.messageId;
      if (id != null) _seenIds.remove(id);
      return true;
    });
    final removed = before - _items.length;
    if (removed > 0) _bump();
    return removed;
  }

  bool removeLoadingHistory() => removeSystem(loadingHistoryId);

  /// Moves the newest connect-state system line back to the top.
  bool moveConnectedToTop() {
    if (_items.length < 2) return false;
    var idx = _items.indexWhere(
      (m) => m.isSystem && m.messageId == _connId('reconnected'),
    );
    idx = idx < 0
        ? _items.indexWhere(
            (m) => m.isSystem && m.messageId == _connId('connected'),
          )
        : idx;
    if (idx <= 0) return false;
    final msg = _items.removeAt(idx);
    _items.insert(0, msg);
    _bump();
    return true;
  }

  // ---- Mutations -----------------------------------------------------------

  /// Marks every non-system message from [login] deleted. Emits one row
  /// mutation per affected id, so consumers keep unrelated cached tiles.
  bool markUserDeleted(String login) {
    final needle = login.toLowerCase();
    final touchedIds = <String>[];
    var touched = false;
    for (final msg in _items) {
      if (msg.login == needle && !msg.isSystem && !msg.deleted) {
        msg.deleted = true;
        touched = true;
        final id = msg.messageId;
        if (id != null) touchedIds.add(id);
      }
    }
    if (!touched) return false;
    _bump();
    for (final id in touchedIds) {
      mutations.emit(id);
    }
    return true;
  }

  /// Marks the non-system row with [messageId] deleted. Returns whether one
  /// changed.
  bool markDeleted(String messageId) {
    for (final msg in _items) {
      if (msg.messageId == messageId && !msg.isSystem && !msg.deleted) {
        msg.deleted = true;
        _noteMutation(messageId);
        return true;
      }
    }
    return false;
  }

  /// Marks every non-system message deleted. Emits one whole-channel evict.
  void markAllDeleted() {
    for (final m in _items) {
      if (!m.isSystem) m.deleted = true;
    }
    _bump();
    mutations.emitAll();
  }

  /// Replaces the text of the row with [messageId]. Returns whether one
  /// changed.
  bool updateText(String messageId, String text) {
    for (final m in _items) {
      if (m.messageId == messageId) {
        m.text = text;
        _noteMutation(messageId);
        return true;
      }
    }
    return false;
  }

  // ---- Truncation ----------------------------------------------------------

  /// Whether any buffered row participates in a reply thread. Cheap scan with
  /// no allocation; guards the truncate fast path.
  bool _hasThreadRows() {
    for (final m in _items) {
      if (m.replyThreadRootId != null || m.replyToParentId != null) return true;
    }
    return false;
  }

  List<TwitchMessage> truncate(
    int maxMessages, [
    TruncateExemptions Function()? buildExemptions,
  ]) {
    if (maxMessages <= 0) return const <TwitchMessage>[];
    if (_items.length <= maxMessages) return const <TwitchMessage>[];
    _lastTruncateAt = now();
    final exemptions = buildExemptions?.call() ?? TruncateExemptions.empty;

    // Fast path: without reply rows or exemptions nothing is pinned, so the
    // newest [maxMessages] rows are kept and the tail is evicted. Avoids the
    // per-row thread map allocation, which is the cost of a plain chat buffer.
    if (exemptions.savedRootIds.isEmpty &&
        exemptions.pinnedMessageIds.isEmpty &&
        !_hasThreadRows()) {
      final evicted = <TwitchMessage>[];
      for (int i = maxMessages; i < _items.length; i++) {
        final id = _items[i].messageId;
        if (id != null) _seenIds.remove(id);
        evicted.add(_items[i]);
      }
      _items.removeRange(maxMessages, _items.length);
      return evicted;
    }

    final parentOf = <String, String>{};
    for (final m in _items) {
      if (m.replyToParentId != null && m.messageId != null) {
        parentOf[m.messageId!] = m.replyToParentId!;
      }
    }

    // Only thread participants can form a group: reply rows plus the roots
    // they resolve to. A non-participant is its own root, so it lands in a
    // singleton group the filter below drops anyway. Skipping it avoids a map
    // entry and a list per buffered row.
    final referencedIds = <String>{...parentOf.values};
    for (final m in _items) {
      final root = m.replyThreadRootId;
      if (root != null) referencedIds.add(root);
    }
    final threadGroups = <String, List<TwitchMessage>>{};
    for (final m in _items) {
      final isReply = m.replyToParentId != null || m.replyThreadRootId != null;
      final isReferenced =
          m.messageId != null && referencedIds.contains(m.messageId);
      if (!isReply && !isReferenced) continue;
      final key = threadKeyFor(m, parentOf);
      if (key != null) {
        threadGroups.putIfAbsent(key, () => <TwitchMessage>[]).add(m);
      }
    }
    threadGroups.removeWhere((_, ms) => ms.length <= 1);

    final activeThreadKeys = <String>{};
    int visibleCount = 0;
    for (final m in _items) {
      if (visibleCount >= maxMessages) break;
      visibleCount++;
      if (m.isSystem) continue;
      final key = threadKeyFor(m, parentOf);
      if (key != null && threadGroups.containsKey(key)) {
        activeThreadKeys.add(key);
      }
    }

    final activeThreadRoot = <String, String>{};
    for (final key in activeThreadKeys) {
      for (final m in threadGroups[key]!) {
        if (m.messageId != null) activeThreadRoot[m.messageId!] = key;
      }
    }

    final savedIds = <String>{};
    for (final entry in threadGroups.entries) {
      if (exemptions.savedRootIds.contains(entry.key)) {
        for (final m in entry.value) {
          if (m.messageId != null) savedIds.add(m.messageId!);
        }
      }
    }

    final openIds = <String>{};
    if (exemptions.pinnedMessageIds.isNotEmpty) {
      for (final entry in threadGroups.entries) {
        var holds = false;
        for (final m in entry.value) {
          if (m.messageId != null &&
              exemptions.pinnedMessageIds.contains(m.messageId!)) {
            holds = true;
            break;
          }
        }
        if (holds) {
          for (final m in entry.value) {
            if (m.messageId != null) openIds.add(m.messageId!);
          }
        }
      }
    }

    // Split into retained and evicted in one pass: the kept rows keep buffer
    // order, so no index set is needed.
    final retained = <TwitchMessage>[];
    final evicted = <TwitchMessage>[];
    int kept = 0;
    final activeKept = <String, int>{};
    for (int i = 0; i < _items.length; i++) {
      final m = _items[i];
      final id = m.messageId;
      final rootKey = id == null ? null : activeThreadRoot[id];
      final bool keep;
      if (id != null && (savedIds.contains(id) || openIds.contains(id))) {
        keep = true;
      } else if (rootKey != null &&
          (activeKept[rootKey] ?? 0) < maxPinnedThreadMembers) {
        activeKept[rootKey] = (activeKept[rootKey] ?? 0) + 1;
        keep = true;
      } else if (m.isSystem) {
        keep = kept < maxMessages;
        if (keep) kept++;
      } else {
        final key = threadKeyFor(m, parentOf);
        final isOrphanThread =
            id != null &&
            rootKey == null &&
            key != null &&
            threadGroups.containsKey(key);
        keep = !isOrphanThread && kept < maxMessages;
        if (keep) kept++;
      }
      if (keep) {
        retained.add(m);
      } else if (id != null) {
        _seenIds.remove(id);
        evicted.add(m);
      }
    }

    _items
      ..clear()
      ..addAll(retained);
    return evicted;
  }

  List<TwitchMessage> _maybeTruncate(
    int maxMessages,
    TruncateExemptions Function()? buildExemptions,
  ) {
    if (maxMessages <= 0) return const <TwitchMessage>[];
    if (_items.length <= maxMessages) return const <TwitchMessage>[];
    final t = now();
    final last = _lastTruncateAt;
    final sinceLast = last == null ? null : t.difference(last);
    final overHardCap = _items.length > maxMessages * _truncateHardCapFactor;
    if (sinceLast != null &&
        sinceLast < truncateCoalesceWindow &&
        !overHardCap) {
      return const [];
    }
    return truncate(maxMessages, buildExemptions);
  }

  /// Newest-first sort that preserves prior relative order on timestamp ties.
  /// Dart's sort is unstable, so a reply could otherwise jump above its root
  /// when live and history rows share a boundary second.
  void _sortNewestFirst() {
    if (_items.length < 2) return;
    final indices = List<int>.generate(_items.length, (i) => i);
    indices.sort((a, b) {
      final byTime = _items[b].timestamp.compareTo(_items[a].timestamp);
      return byTime != 0 ? byTime : a.compareTo(b);
    });
    final sorted = [for (final i in indices) _items[i]];
    _items
      ..clear()
      ..addAll(sorted);
  }

  bool _isDuplicateIdlessSystemRow(
    List<TwitchMessage> existing,
    List<TwitchMessage> inserted,
    TwitchMessage candidate,
  ) {
    for (final row in existing) {
      if (_isSameSystemEvent(row, candidate)) return true;
    }
    for (final row in inserted) {
      if (_isSameSystemEvent(row, candidate)) return true;
    }
    return false;
  }

  bool _isSameSystemEvent(TwitchMessage a, TwitchMessage b) {
    return a.isSystem &&
        a.text == b.text &&
        a.timestamp.difference(b.timestamp).abs() <= _systemDedupWindow;
  }

  // ---- Signals -------------------------------------------------------------

  void _bump() => version.value++;

  /// In-place change: rebuild the list and hand the exact id to tile-cache
  /// consumers. Both happen, so a mutation is never silently dropped.
  void _noteMutation(String? id) {
    _bump();
    mutations.emit(id);
  }

  void dispose() {
    version.dispose();
    mutations.dispose();
    _items.clear();
    _seenIds.clear();
  }
}

/// Minimal synchronous listener set for [Messages.mutations]. Deliberately not
/// a ValueNotifier (equal-value coalescing) and not a generic event bus: it
/// carries exactly one thing, the id of an in-place mutated message.
class MessageMutations {
  final Set<void Function(String? id)> _listeners = {};
  final Set<void Function()> _allListeners = {};

  void addListener(void Function(String? id) listener) =>
      _listeners.add(listener);

  void removeListener(void Function(String? id) listener) =>
      _listeners.remove(listener);

  void addAllListener(void Function() listener) => _allListeners.add(listener);

  void removeAllListener(void Function() listener) =>
      _allListeners.remove(listener);

  bool get hasListeners => _listeners.isNotEmpty || _allListeners.isNotEmpty;

  void emit(String? id) {
    for (final listener in List.of(_listeners)) {
      listener(id);
    }
  }

  /// Whole-channel evict for mass deletes. Consumers drop all cached tiles
  /// for the channel. Distinct from [emit] so a null id keeps its
  /// uncached-row no-op meaning.
  void emitAll() {
    for (final listener in List.of(_allListeners)) {
      listener();
    }
  }

  void dispose() {
    _listeners.clear();
    _allListeners.clear();
  }
}
