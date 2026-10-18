import 'dart:collection';
import 'dart:math' show max, min;
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
/// out of the thread index). [removed] holds rows dropped in place, such as gap
/// notes a later fetch bridged, which callers must drop from the archive too.
class MergeOutcome {
  const MergeOutcome({
    required this.inserted,
    required this.evicted,
    this.removed = const [],
  });

  final List<TwitchMessage> inserted;
  final List<TwitchMessage> evicted;
  final List<TwitchMessage> removed;
}

/// Kernel-authored system rows. The app injects their display text, so the
/// kernel folds by kind and never matches user-visible copy.
enum SystemLine {
  connected,
  reconnected,
  disconnected,
  reconnecting,
  loadingHistory,
  historyGap,

  /// "Signed in as …" under the first Connected line; empty when anonymous.
  signedIn,
}

/// One channel's message buffer and its laws: newest-first ordering, dedup,
/// system-line folding, slack-batched thread-aware truncation, and in-place
/// mutations. Owns no policy: callers filter, rewrite, and evaluate pings
/// before handing a message or batch in.
class Messages {
  Messages({
    required this.channel,
    DateTime Function()? now,
    String Function(SystemLine line)? systemText,
  }) : now = now ?? clock.now,
       systemText = systemText ?? _systemLineName;

  /// Channel this buffer belongs to. Stamped onto system rows because
  /// [TwitchMessage.channel] is final and downstream keys on it.
  final String channel;
  final DateTime Function() now;

  /// Display text for kernel-authored rows, read when the row is inserted.
  final String Function(SystemLine line) systemText;

  // With no app text there is no account to name, so signedIn stays empty.
  static String _systemLineName(SystemLine line) =>
      line == SystemLine.signedIn ? '' : line.name;

  final List<TwitchMessage> _items = [];
  // Every buffered row carrying an id, for O(1) dedup and lookup.
  final Map<String, TwitchMessage> _byId = {};

  // Buffer cap from the latest mutation, so [chatRows] never shows more than
  // it between trims. Zero until the first capped call.
  int _cap = 0;

  // Visible rows beyond [_cap] at the last trim (thread rows kept in view).
  int _chatExtra = 0;

  // Rows retained by the last trim. Thread-exempt rows can hold the buffer
  // above the cap, so the next trim waits for slack past this, not the cap.
  int _retainedAtTrim = 0;

  // Oldest row inside the message limit at the last truncate. Older rows are
  // kept only for their threads. Null when nothing is held past the limit.
  TwitchMessage? _limitEnd;
  int _nextSystemMessageId = 0;

  /// Bumped on any list change (insert, trim, bulk delete). Drives row lists.
  final ValueNotifier<int> version = ValueNotifier(0);

  /// Lossless, synchronous fan-out of in-place mutation ids. A ValueNotifier
  /// would coalesce two different ids mutated in one frame (a raid deleting
  /// many rows at once), leaving stale tiles. Null id means an uncached row
  /// changed and consumers no-op. This is the one typed mutation channel; it
  /// is not a generic event bus.
  final MessageMutations mutations = MessageMutations();

  // Live trims wait until the buffer is this far past the cap, then trim back
  // to it, so a full buffer pays one trim per slack rows instead of one per
  // message. Small caps scale down to a quarter of the cap.
  static int _slackFor(int maxMessages) => min(256, max(1, maxMessages ~/ 4));
  static const _systemDedupWindow = Duration(seconds: 10);

  /// A recovery announced within this window of the previous one is the same
  /// outage flapping, so it folds instead of stacking another line.
  static const _reconnectFoldWindow = Duration(seconds: 30);

  /// Per-thread member cap applied during truncation.
  static const maxPinnedThreadMembers = 20;

  /// Connect-state rows carry a `sys_conn:<state>:<n>` id: unique per row, so
  /// two Reconnected lines never share a tile, while folding matches the state
  /// prefix instead of user-visible copy.
  static const _connIdPrefix = 'sys_conn:';

  /// Stable id for the loading-history row.
  static const loadingHistoryId = 'sys_loading';

  /// Id prefix of "not all messages retrieved" notes; the rest is the epoch
  /// ms they sit at.
  static const historyGapIdPrefix = 'sys_gap:';

  /// Id prefix of the "signed in as" row that sits under the first
  /// Connected line.
  static const _signedInIdPrefix = 'sys_signedin:';

  static bool _isSignedIn(TwitchMessage m) =>
      m.isSystem && (m.messageId?.startsWith(_signedInIdPrefix) ?? false);

  static bool _isConnRow(TwitchMessage m) =>
      m.isSystem && (m.messageId?.startsWith(_connIdPrefix) ?? false);
  static bool _isConn(TwitchMessage? m, SystemLine state) =>
      m != null &&
      m.isSystem &&
      (m.messageId?.startsWith('$_connIdPrefix${state.name}:') ?? false);

  // ---- Reads ---------------------------------------------------------------

  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;
  UnmodifiableListView<TwitchMessage> get items => UnmodifiableListView(_items);

  /// Rows the channel chat shows: [items] up to the message limit. Thread rows
  /// held past the limit stay in [items] for thread views only.
  late final List<TwitchMessage> chatRows = _ChatRows(this);

  // [_chatLength] memo, keyed on the buffer version and length.
  int _chatLengthAt = -1;
  int _chatLengthOf = -1;
  int _chatLengthMemo = 0;

  int get _chatLength {
    final end = _limitEnd;
    final visible = _cap <= 0 ? _items.length : _cap + _chatExtra;
    if (end == null) return min(_items.length, visible);
    if (_chatLengthAt == version.value && _chatLengthOf == _items.length) {
      return min(_chatLengthMemo, visible);
    }
    _chatLengthAt = version.value;
    _chatLengthOf = _items.length;
    _chatLengthMemo = _items.length;
    // The held rows sit at the oldest end, so the scan is short.
    for (var i = _items.length - 1; i >= 0; i--) {
      if (identical(_items[i], end)) {
        _chatLengthMemo = i + 1;
        break;
      }
    }
    return min(_chatLengthMemo, visible);
  }

  bool containsId(String id) => _byId.containsKey(id);

  TwitchMessage? byId(String id) => _byId[id];

  // ---- Live ingest ---------------------------------------------------------

  /// Dedup by message id, insert at the top, and slack-truncate. Returns
  /// whether the row was inserted plus anything trimmed out. Exemptions are
  /// built lazily: [buildExemptions] runs only when a truncate pass runs,
  /// never on the steady-state path.
  BufferChange add(
    TwitchMessage msg, {
    required int maxMessages,
    TruncateExemptions Function()? buildExemptions,
  }) {
    final id = msg.messageId;
    if (id != null && _byId.containsKey(id)) {
      return const BufferChange();
    }
    _items.insert(0, msg);
    if (id != null) _byId[id] = msg;
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
    if (id != null && _byId.containsKey(id)) {
      return const BufferChange();
    }
    final target = _items.indexWhere((m) => m.messageId == targetId);
    if (target < 0) return const BufferChange();
    _items.insert(target + 1, msg);
    if (id != null) _byId[id] = msg;
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
    // Newest held chat row: a fetch reaching back to it overlaps in time
    // even when ids cannot match (archived rows drop theirs).
    DateTime? newestHeld;
    for (final m in _items) {
      if (!m.isSystem) {
        newestHeld = m.timestamp;
        break;
      }
    }
    final bridged = _bridgedGapNotes(rawHistory);

    final inserted = <TwitchMessage>[];
    final insertedIds = <String?>{};
    // System rows by text, built on the first id-less system row so the dedup
    // check is a lookup instead of a scan of the whole buffer.
    Map<String, List<DateTime>>? systemTimes;
    for (final msg in prepared) {
      final id = msg.messageId;
      if (id == null && msg.isSystem) {
        systemTimes ??= _systemTimesByText();
        if (_isDuplicateSystemEvent(systemTimes, msg)) continue;
      }
      final isNew =
          id == null ||
          (!existingIds.contains(id) && !insertedIds.contains(id));
      if (isNew) {
        if (id != null) {
          insertedIds.add(id);
          _byId[id] = msg;
        }
        _items.add(msg);
        inserted.add(msg);
        if (msg.isSystem) {
          systemTimes?.putIfAbsent(msg.text, () => []).add(msg.timestamp);
        }
      }
    }

    if (hasExistingNonSystem &&
        inserted.isNotEmpty &&
        // Overlap is checked against the raw fetch, not the filtered batch:
        // an ignored row that overlapped the buffer must still suppress the
        // gap note.
        !rawHistory.any(
          (m) =>
              (m.messageId != null && existingIds.contains(m.messageId)) ||
              (!m.isSystem && !m.timestamp.isAfter(newestHeld!)),
        )) {
      // Timestamp comes from the oldest raw row, not the oldest prepared
      // row: an ignored oldest row must still anchor the note below it.
      final rawList = rawHistory.toList();
      final anchor = rawList.isEmpty ? prepared : rawList;
      final oldestHistory = anchor
          .map((m) => m.timestamp)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      // Keyed by time and returned as inserted, so the archive keeps it and
      // scrolling back through history still shows the gap.
      final at = oldestHistory.subtract(const Duration(milliseconds: 1));
      final id = '$historyGapIdPrefix${at.millisecondsSinceEpoch}';
      if (!_byId.containsKey(id) && _chatBefore(at)) {
        final note = TwitchMessage(
          login: '',
          text: systemText(SystemLine.historyGap),
          isSystem: true,
          messageId: id,
          channel: channel,
          timestamp: at,
        );
        _items.add(note);
        _byId[id] = note;
        inserted.add(note);
      }
    }

    if (bridged.isNotEmpty) _removeRows(bridged.contains);
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
    return MergeOutcome(
      inserted: resident,
      evicted: evicted,
      removed: bridged.toList(),
    );
  }

  /// Re-resolves rows baked before their catalog was complete, live or
  /// history. Healing only adds: a row adopts the reparse when it keeps every
  /// emote the row already shows and finds more, so an emote removed since
  /// stays on old rows. A row stops being a candidate once its catalog is
  /// complete. Bumps [version] and emits one mutation per touched id (a
  /// whole-channel evict when an id-less row changed). Returns rows healed.
  int restampPartialEmotes(
    ({List<EmoteToken>? tokens, bool complete}) Function(TwitchMessage msg)
    resolve,
  ) => _restamp(_items.where((m) => m.emotesPartial), (msg) {
    final (:tokens, :complete) = resolve(msg);
    if (complete) msg.emotesPartial = false;
    return tokens;
  });

  /// Re-resolves every row, partial or not, for a manual emote reload: a row
  /// baked "complete" can still lack emotes when a provider failed. Adds
  /// emotes only, like [restampPartialEmotes].
  int restampAllEmotes(
    ({List<EmoteToken>? tokens, bool complete}) Function(TwitchMessage msg)
    resolve,
  ) => _restamp(_items, (msg) {
    final (:tokens, :complete) = resolve(msg);
    if (complete) msg.emotesPartial = false;
    return tokens;
  });

  /// Re-resolves the newest [window] rows sent by [userIds] after their
  /// personal emotes landed: the set often arrives just after the message
  /// that announced it (chatterino7 re-parses the sender's last message the
  /// same way). Adds emotes only, like [restampPartialEmotes].
  int restampSenderEmotes(
    Set<String> userIds,
    List<EmoteToken>? Function(TwitchMessage msg) resolve, {
    int window = 100,
  }) {
    if (userIds.isEmpty) return 0;
    return _restamp(
      _items.take(window).where((m) => userIds.contains(m.userId)),
      resolve,
    );
  }

  int _restamp(
    Iterable<TwitchMessage> rows,
    List<EmoteToken>? Function(TwitchMessage msg) resolve,
  ) {
    final touchedIds = <String>[];
    var touchedIdless = false;
    var healed = 0;
    for (final msg in rows) {
      if (msg.isSystem) continue;
      final tokens = resolve(msg);
      if (tokens == null || !_addsEmotes(msg.emoteTokens, tokens)) continue;
      msg.emoteTokens = tokens;
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

  /// Whether [next] shows every emote [current] does, at the same span, plus
  /// at least one more.
  static bool _addsEmotes(List<EmoteToken>? current, List<EmoteToken> next) {
    final had = current ?? const <EmoteToken>[];
    if (next.length <= had.length) return false;
    final spans = {for (final t in next) (t.start, t.end, t.emote?.id)};
    return had.every((t) => spans.contains((t.start, t.end, t.emote?.id)));
  }

  /// Merges mention-tier rows into this (the @mentions pseudo) buffer: dedup by
  /// id, sort newest-first, cap. No signals beyond [version].
  void mergeMentions(List<TwitchMessage> msgs, {required int maxMessages}) {
    if (msgs.isEmpty) return;
    final added = <TwitchMessage>[];
    for (final msg in msgs) {
      final id = msg.messageId;
      if (id != null) {
        if (_byId.containsKey(id)) continue;
        _byId[id] = msg;
      }
      added.add(msg);
    }
    if (added.isEmpty) return;
    if (_headsBuffer(added)) {
      _items.insertAll(0, added);
    } else {
      _items.addAll(added);
      _sortNewestFirst();
    }
    _cap = maxMessages;
    if (_items.length > maxMessages) {
      for (var i = maxMessages; i < _items.length; i++) {
        _unindex(_items[i]);
      }
      _items.removeRange(maxMessages, _items.length);
    }
    _bump();
  }

  // Whether [added] already sits where the stable sort would put it: newest
  // first among itself and strictly newer than the top row (a tie keeps the
  // resident row first), so it can go in front without a sort.
  bool _headsBuffer(List<TwitchMessage> added) {
    for (var i = 1; i < added.length; i++) {
      if (added[i - 1].timestamp.compareTo(added[i].timestamp) < 0) {
        return false;
      }
    }
    return _items.isEmpty ||
        added.last.timestamp.compareTo(_items.first.timestamp) > 0;
  }

  // ---- System lines --------------------------------------------------------

  /// Set by the first Connected. Outlives its row, which a busy channel
  /// truncates away, so a later connect still reads as a reconnect.
  bool _connectedOnce = false;

  /// The account the last "signed in as" row named, and the connect row it
  /// rides under. Null while anonymous.
  String? _namedAccount;
  String? _signedInPartnerId;

  /// Inserts a connect-state row at the top with status folding: a repeat
  /// connect reads as Reconnected, recoveries clear the outage marker, and
  /// flapping folds. [status] is one of the four connect lines. Returns false
  /// when folding dropped it.
  bool addConnStatus(SystemLine status) {
    assert(status.index <= SystemLine.reconnecting.index);
    var resolved = status;
    if (resolved == SystemLine.connected &&
        (_connectedOnce || _items.any(_isConnRow))) {
      resolved = SystemLine.reconnected;
    }
    // A connect under a different account names it, even one that reads as
    // a reconnect, so an account switch shows who is now signed in.
    final signedIn = status == SystemLine.connected
        ? systemText(SystemLine.signedIn)
        : '';
    if (status == SystemLine.connected && signedIn.isEmpty) {
      _namedAccount = null;
    }
    final newAccount = signedIn.isNotEmpty && signedIn != _namedAccount;
    final top = _items.isEmpty ? null : _items.first;
    if (resolved == SystemLine.reconnected) {
      var newestRecovery = -1;
      for (var i = 0; i < _items.length; i++) {
        final m = _items[i];
        if (_isConn(m, SystemLine.reconnected)) {
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
      _removeRows(
        (m) =>
            _isConn(m, SystemLine.disconnected) ||
            _isConn(m, SystemLine.reconnecting),
      );
      if (recentRecovery && !newAccount) {
        if (_items.length != before) _bump();
        return false;
      }
      if (!hasActivity) {
        _removeRows((m) => _isConn(m, SystemLine.reconnected));
      }
    } else if (resolved == SystemLine.reconnecting) {
      if (_items.any((m) => _isConn(m, SystemLine.disconnected))) return false;
      if (_isConn(top, SystemLine.reconnecting)) return false;
    } else if (resolved == SystemLine.disconnected) {
      if (_isConn(top, SystemLine.disconnected)) return false;
      _removeRows((m) => _isConn(m, SystemLine.reconnecting));
    }
    if (resolved == SystemLine.connected) _connectedOnce = true;
    // The account row sits just under its connect row; anonymous sessions
    // resolve the line to empty and skip it.
    final connId = '$_connIdPrefix${resolved.name}:${_nextSystemMessageId++}';
    if (newAccount) {
      _namedAccount = signedIn;
      _signedInPartnerId = connId;
      _insertSystem(
        signedIn,
        messageId: '$_signedInIdPrefix${_nextSystemMessageId++}',
      );
    }
    return _insertSystem(systemText(resolved), messageId: connId);
  }

  /// Inserts a system row at the top with id-less text dedup. Returns false
  /// when dedup dropped it.
  bool addSystem(String text, {Color? accent, String? messageId}) {
    if (messageId != null &&
        _items.any((m) => m.isSystem && m.messageId == messageId)) {
      return false;
    }

    if (messageId == null) {
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
    return _insertSystem(text, accent: accent, messageId: messageId);
  }

  bool _insertSystem(String text, {Color? accent, String? messageId}) {
    final row = TwitchMessage(
      login: '',
      text: text,
      messageId: messageId ?? 'sys_${_nextSystemMessageId++}',
      isSystem: true,
      systemAccent: accent,
      channel: channel,
      timestamp: now(),
    );
    _items.insert(0, row);
    _byId[row.messageId!] = row;
    _bump();
    return true;
  }

  /// Inserts a system row carrying [messageId] at its [at] position in the
  /// newest-first buffer, so a row reporting a past event lands among the
  /// chat of that time. Returns false when the id is already present.
  bool addSystemAt(
    String text, {
    required String messageId,
    required DateTime at,
    Color? accent,
  }) {
    if (_byId.containsKey(messageId)) return false;
    final row = TwitchMessage(
      login: '',
      text: text,
      messageId: messageId,
      isSystem: true,
      systemAccent: accent,
      channel: channel,
      timestamp: at,
    );
    var i = 0;
    while (i < _items.length && !_items[i].timestamp.isBefore(at)) {
      i++;
    }
    _items.insert(i, row);
    _byId[messageId] = row;
    _bump();
    return true;
  }

  /// Notes a gap at [at] after a history fetch failed: messages from before
  /// then may be missing. Nothing when no chat sits before [at], or when the
  /// last thing before it is already a gap note, so a fetch failing again at
  /// the same place adds no second note. Returns the note added.
  TwitchMessage? noteHistoryGap(DateTime at) {
    if (!_chatBefore(at)) return null;
    final id = '$historyGapIdPrefix${at.millisecondsSinceEpoch}';
    if (_byId.containsKey(id)) return null;
    final note = TwitchMessage(
      login: '',
      text: systemText(SystemLine.historyGap),
      isSystem: true,
      messageId: id,
      channel: channel,
      timestamp: at,
    );
    _items.add(note);
    _byId[id] = note;
    _sortNewestFirst();
    _bump();
    return note;
  }

  /// Whether the last chat or gap note at or before [at] is chat, so a note
  /// there would mark a new place.
  bool _chatBefore(DateTime at) {
    for (final m in _items) {
      if (m.timestamp.isAfter(at)) continue;
      if (_isGapNote(m)) return false;
      if (!m.isSystem) return true;
    }
    return false;
  }

  /// Gap notes that [raw] fills: it reaches back to the chat held just
  /// before a note, so nothing between them is missing any more.
  Set<TwitchMessage> _bridgedGapNotes(Iterable<TwitchMessage> raw) {
    DateTime? oldest;
    for (final m in raw) {
      if (!m.isSystem && (oldest == null || m.timestamp.isBefore(oldest))) {
        oldest = m.timestamp;
      }
    }
    final bridged = Set<TwitchMessage>.identity();
    if (oldest == null) return bridged;
    // Newest first, so each pending note meets the chat right below it.
    final pending = <TwitchMessage>[];
    for (final m in _items) {
      if (_isGapNote(m)) {
        pending.add(m);
      } else if (!m.isSystem && pending.isNotEmpty) {
        if (!oldest.isAfter(m.timestamp)) bridged.addAll(pending);
        pending.clear();
      }
    }
    return bridged;
  }

  static bool _isGapNote(TwitchMessage m) =>
      m.isSystem && (m.messageId?.startsWith(historyGapIdPrefix) ?? false);

  /// Removes the system row carrying [messageId]. Returns true when one went.
  bool removeSystem(String messageId) {
    final changed =
        _removeRows((m) => m.isSystem && m.messageId == messageId) > 0;
    if (changed) _bump();
    return changed;
  }

  /// Removes every row matching [test]. Returns the number removed.
  int removeWhere(bool Function(TwitchMessage) test) {
    final removed = _removeRows(test);
    if (removed > 0) _bump();
    return removed;
  }

  int _removeRows(bool Function(TwitchMessage) test) {
    final before = _items.length;
    _items.removeWhere((m) {
      if (!test(m)) return false;
      _unindex(m);
      return true;
    });
    return before - _items.length;
  }

  // Drops [m] from the id map unless a different row now holds its id.
  void _unindex(TwitchMessage m) {
    final id = m.messageId;
    if (id != null && identical(_byId[id], m)) _byId.remove(id);
  }

  bool removeLoadingHistory() => removeSystem(loadingHistoryId);

  /// Moves the newest connect-state system line back to the top.
  bool moveConnectedToTop() {
    if (_items.length < 2) return false;
    var idx = _items.indexWhere((m) => _isConn(m, SystemLine.reconnected));
    final recovered = idx >= 0;
    idx = recovered
        ? idx
        : _items.indexWhere((m) => _isConn(m, SystemLine.connected));
    if (idx < 0) return false;
    var moved = false;
    if (idx > 0) {
      final msg = _items.removeAt(idx);
      _items.insert(0, msg);
      if (identical(msg, _limitEnd)) _limitEnd = null;
      moved = true;
    }
    // The connect row that named the account keeps its row just under it.
    if (_items.first.messageId == _signedInPartnerId) {
      final at = _items.indexWhere(_isSignedIn);
      if (at > 1) {
        final row = _items.removeAt(at);
        _items.insert(1, row);
        if (identical(row, _limitEnd)) _limitEnd = null;
        moved = true;
      }
    }
    if (moved) _bump();
    return moved;
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
    _cap = maxMessages;
    if (_items.length <= maxMessages) {
      _retainedAtTrim = 0;
      _chatExtra = 0;
      return const <TwitchMessage>[];
    }
    final exemptions = buildExemptions?.call() ?? TruncateExemptions.empty;

    // Fast path: without reply rows or exemptions nothing is pinned, so the
    // newest [maxMessages] rows are kept and the tail is evicted. Avoids the
    // per-row thread map allocation, which is the cost of a plain chat buffer.
    if (exemptions.savedRootIds.isEmpty &&
        exemptions.pinnedMessageIds.isEmpty &&
        !_hasThreadRows()) {
      final evicted = <TwitchMessage>[];
      for (int i = maxMessages; i < _items.length; i++) {
        _unindex(_items[i]);
        evicted.add(_items[i]);
      }
      _items.removeRange(maxMessages, _items.length);
      _limitEnd = null;
      _chatExtra = 0;
      _retainedAtTrim = _items.length;
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
    TwitchMessage? limitEnd;
    var limitEndLen = 0;
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
        if (keep) {
          kept++;
          limitEnd = m;
          limitEndLen = retained.length + 1;
        }
      } else {
        final key = threadKeyFor(m, parentOf);
        final isOrphanThread =
            id != null &&
            rootKey == null &&
            key != null &&
            threadGroups.containsKey(key);
        keep = !isOrphanThread && kept < maxMessages;
        if (keep) {
          kept++;
          limitEnd = m;
          limitEndLen = retained.length + 1;
        }
      }
      if (keep) {
        retained.add(m);
      } else if (id != null) {
        _unindex(m);
        evicted.add(m);
      }
    }

    _items
      ..clear()
      ..addAll(retained);
    _limitEnd = kept >= maxMessages ? limitEnd : null;
    _chatExtra = max(
      0,
      (_limitEnd == null ? _items.length : limitEndLen) - maxMessages,
    );
    _retainedAtTrim = _items.length;
    _chatLengthAt = -1;
    return evicted;
  }

  List<TwitchMessage> _maybeTruncate(
    int maxMessages,
    TruncateExemptions Function()? buildExemptions,
  ) {
    if (maxMessages <= 0) return const <TwitchMessage>[];
    _cap = maxMessages;
    final floor = max(maxMessages, _retainedAtTrim);
    if (_items.length <= floor + _slackFor(maxMessages)) {
      return const <TwitchMessage>[];
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

  Map<String, List<DateTime>> _systemTimesByText() {
    final byText = <String, List<DateTime>>{};
    for (final row in _items) {
      if (row.isSystem) {
        byText.putIfAbsent(row.text, () => []).add(row.timestamp);
      }
    }
    return byText;
  }

  bool _isDuplicateSystemEvent(
    Map<String, List<DateTime>> systemTimes,
    TwitchMessage candidate,
  ) {
    final times = systemTimes[candidate.text];
    if (times == null) return false;
    for (final t in times) {
      if (t.difference(candidate.timestamp).abs() <= _systemDedupWindow) {
        return true;
      }
    }
    return false;
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
    _byId.clear();
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

/// Live read-only view of [Messages.chatRows].
class _ChatRows extends ListBase<TwitchMessage> {
  _ChatRows(this._messages);

  final Messages _messages;

  @override
  int get length => _messages._chatLength;

  @override
  set length(int _) => throw UnsupportedError('read-only');

  @override
  TwitchMessage operator [](int index) => _messages._items[index];

  @override
  void operator []=(int index, TwitchMessage value) =>
      throw UnsupportedError('read-only');
}
