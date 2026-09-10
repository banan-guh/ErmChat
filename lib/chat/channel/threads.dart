import '../../models/twitch_message.dart';
import 'messages.dart' show TruncateExemptions;

/// One tracked reply thread: the pinned root (null when the root was never
/// seen) plus replies still present in the channel buffer.
class ThreadEntry {
  TwitchMessage? root;
  DateTime lastActivity = DateTime.now();
  final List<TwitchMessage> replies = [];

  bool hasMessage(String messageId) =>
      root?.messageId == messageId ||
      replies.any((r) => r.messageId == messageId);
}

/// Read-only summary of one tracked thread for the threads dashboard.
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

/// Per-channel reply index. Laws moved verbatim from ChatStore: 64 thread
/// cap, saved and on-screen holds exempt, decay on evict.
class Threads {
  Threads({DateTime Function()? now}) : now = now ?? DateTime.now;

  final DateTime Function() now;

  static const maxTrackedThreads = 64;

  final Map<String, ThreadEntry> _threads = {};

  final Set<String> _savedRootIds = {};
  final Set<String> _pinnedMessageIds = {};

  int get length => _threads.length;

  TruncateExemptions get exemptions => TruncateExemptions(
    savedRootIds: Set.of(_savedRootIds),
    pinnedMessageIds: Set.of(_pinnedMessageIds),
  );

  void pin(String messageId) {
    _pinnedMessageIds.add(messageId);
  }

  void unpin(String messageId) {
    _pinnedMessageIds.remove(messageId);
  }

  void clearPinned() {
    _pinnedMessageIds.clear();
  }

  /// Syncs the per-channel saved view from global `$channel:$rootId` keys.
  void syncSavedKeys(String channel, Set<String> globalKeys) {
    final prefix = '$channel:';
    final next = <String>{};
    for (final k in globalKeys) {
      if (k.startsWith(prefix)) next.add(k.substring(prefix.length));
    }
    if (next.length == _savedRootIds.length &&
        next.containsAll(_savedRootIds)) {
      return;
    }
    _savedRootIds
      ..clear()
      ..addAll(next);
  }

  void index(
    Iterable<TwitchMessage> msgs, {
    TwitchMessage? Function(String rootId)? lookupRoot,
  }) {
    for (final msg in msgs) {
      _indexOne(msg, lookupRoot);
    }
  }

  bool _indexOne(
    TwitchMessage msg,
    TwitchMessage? Function(String rootId)? lookupRoot,
  ) {
    final id = msg.messageId;
    if (id == null || msg.isSystem) return false;
    final rootId = msg.replyThreadRootId;

    if (rootId == null || rootId == id) {
      final entry = _threads[id];
      if (entry != null && entry.root == null && !msg.isSystem) {
        entry.root = msg;
        return true;
      } else if (entry != null && entry.root != null) {
        entry.root!.deleted = entry.root!.deleted || msg.deleted;
        if (entry.root!.text != msg.text && msg.text.isNotEmpty) {
          entry.root!.text = msg.text;
        }
        return true;
      }
      return false;
    }

    final isNewEntry = !_threads.containsKey(rootId);
    final entry = _threads.putIfAbsent(
      rootId,
      () => ThreadEntry()..lastActivity = now(),
    );
    if (entry.hasMessage(id)) return false;
    entry.lastActivity = now();
    entry.root ??= lookupRoot?.call(rootId);
    entry.replies.add(msg);
    if (isNewEntry) _enforceCap();
    return true;
  }

  void _enforceCap() {
    while (true) {
      final unsaved = _threads.entries
          .where((e) => !_savedRootIds.contains(e.key) && !_isHeld(e.key))
          .toList();
      if (unsaved.length <= maxTrackedThreads) break;
      unsaved.sort(
        (a, b) => a.value.lastActivity.compareTo(b.value.lastActivity),
      );
      _threads.remove(unsaved.first.key);
    }
  }

  bool _isHeld(String rootId) {
    if (_pinnedMessageIds.contains(rootId)) return true;
    final entry = _threads[rootId];
    if (entry == null) return false;
    if (entry.root?.messageId != null &&
        _pinnedMessageIds.contains(entry.root!.messageId!)) {
      return true;
    }
    return entry.replies.any(
      (r) => r.messageId != null && _pinnedMessageIds.contains(r.messageId!),
    );
  }

  List<TwitchMessage>? threadFor(String rootId) {
    final entry = _threads[rootId];
    if (entry == null) return null;
    return [if (entry.root != null) entry.root!, ...entry.replies];
  }

  List<ThreadSummary> activeThreads() {
    if (_threads.isEmpty) return const [];
    final out = <ThreadSummary>[];
    for (final e in _threads.entries) {
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

  void decay(Iterable<TwitchMessage> evicted) {
    if (_threads.isEmpty) return;
    final heldCache = <String, bool>{};
    for (final msg in evicted) {
      final id = msg.messageId;
      if (id == null) continue;
      final rootId = msg.replyThreadRootId;
      if (rootId == null || rootId == id) continue;
      if (_savedRootIds.contains(rootId)) continue;
      final held = heldCache.putIfAbsent(rootId, () => _isHeld(rootId));
      if (held) continue;
      final entry = _threads[rootId];
      if (entry == null) continue;
      entry.replies.removeWhere((r) => identical(r, msg) || r.messageId == id);
      if (entry.replies.isEmpty && entry.root == null) {
        _threads.remove(rootId);
      }
    }
  }

  void dispose() {
    _threads.clear();
    _savedRootIds.clear();
    _pinnedMessageIds.clear();
  }
}
