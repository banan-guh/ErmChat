// Spike B: mutable vs immutable chat-kernel ingest.
//
// Mirrors the hot path of lib/chat/channel at a simplified but
// operation-identical level so both models move the same data:
//   - newest-first buffer, inserted at index 0 (messages.dart:121).
//   - dedup by message id via a Set<String> (messages.dart:117-122).
//   - cap 500 (kMaxMessagesPerChannelDefault, constants.dart:34) with the
//     kernel's coalesced live truncation: skip a pass within the 250ms window
//     unless the buffer exceeds 2x cap (messages.dart:74-78, 556-572). The
//     pass itself is simplified to tail-trimming to the cap; the kernel's
//     thread-aware retention (messages.dart:427-554) keeps pinned members but
//     is the same per-pass big-O, so it is omitted here.
//   - thread index root id -> replies, capped at 64 tracked threads
//     (threads.dart:38, 80-136).
//   - unread flag plus mention count (unread.dart:13-27).
//
// The immutable path is deliberate copy-on-write: every receive allocates a
// fresh items list, id set, and thread map, then applies the same rules. It is
// a representative immutable rewrite, not an exhaustive survey: a hand-rolled
// persistent vector or HAMT could cut the per-insert copying, but Dart's core
// libraries ship no persistent collections, so COW is what a pure-Dart rewrite
// reaches for first. A variant keeps the dedup set as a shared mutable index to
// show how much of the gap comes from rehashing ids versus copying the buffer.
//
// Usage:
//   dart run tool/spikes/hot_path_bench.dart

import 'dart:io';
import 'dart:math';

const int kCap = 500;
const int kBursts = 25;
const int kBurstSize = 200;
const int kTotal = kBursts * kBurstSize;
const int kIterations = 11;
const int kWarmups = 2;
const int kReadRecent = 100;
const int kMaxTrackedThreads = 64;
const Duration kBurstGap = Duration(milliseconds: 300);
const Duration kCoalesceWindow = Duration(milliseconds: 250);
const int kHardCapFactor = 2;

class BenchMessage {
  const BenchMessage(
    this.id,
    this.replyRootId, {
    this.isSystem = false,
    this.isHistory = false,
    this.hasMention = false,
  });

  final String id;

  /// Root id when this row is a reply, null for a root row.
  final String? replyRootId;
  final bool isSystem;
  final bool isHistory;
  final bool hasMention;
}

class ThreadEntry {
  ThreadEntry({this.root, this.activity = 0});

  BenchMessage? root;
  int activity;
  final List<BenchMessage> replies = [];

  ThreadEntry copy() =>
      ThreadEntry(root: root, activity: activity)..replies.addAll(replies);
}

abstract class KernelStore {
  void advance(Duration d);

  bool receive(BenchMessage msg, {required bool isSelected, String? ownId});

  List<BenchMessage> recent(int n);

  List<BenchMessage>? lookupThread(String rootId);

  String? firstThreadRoot();

  int get length;
  bool get hasUnread;
  int get mentionCount;
}

/// Kernel-style mutable store: one list, one id set, one thread map, one
/// unread counter, all mutated in place. Mirrors Channel.receive ordering:
/// dedup, insert, truncate, thread decay, thread index, unread.
class MutableStore implements KernelStore {
  final List<BenchMessage> _items = [];
  final Set<String> _seenIds = {};
  final Map<String, ThreadEntry> _threads = {};
  int _mentionCount = 0;
  bool _hasUnread = false;
  DateTime _clock = DateTime.utc(2026);
  DateTime? _lastTruncateAt;

  @override
  int get length => _items.length;
  @override
  bool get hasUnread => _hasUnread;
  @override
  int get mentionCount => _mentionCount;

  @override
  void advance(Duration d) => _clock = _clock.add(d);

  @override
  bool receive(BenchMessage msg, {required bool isSelected, String? ownId}) {
    if (_seenIds.contains(msg.id)) return false;
    _items.insert(0, msg);
    _seenIds.add(msg.id);
    final evicted = _maybeTruncate();
    _decayThreads(evicted);
    _indexThread(msg);
    if (ownId == msg.id) return true;
    final mention = msg.hasMention;
    if (mention && !msg.isHistory && !isSelected) _mentionCount++;
    if (!isSelected && !msg.isHistory && !msg.isSystem) _hasUnread = true;
    return true;
  }

  List<BenchMessage> _maybeTruncate() {
    if (_items.length <= kCap) return const [];
    final since = _lastTruncateAt == null
        ? null
        : _clock.difference(_lastTruncateAt!);
    final overHard = _items.length > kCap * kHardCapFactor;
    if (since != null && since < kCoalesceWindow && !overHard) return const [];
    _lastTruncateAt = _clock;
    final evicted = <BenchMessage>[];
    while (_items.length > kCap) {
      final m = _items.removeLast();
      _seenIds.remove(m.id);
      evicted.add(m);
    }
    return evicted;
  }

  void _indexThread(BenchMessage msg) {
    final rootId = msg.replyRootId;
    if (rootId == null) return;
    final isNew = !_threads.containsKey(rootId);
    final entry = _threads.putIfAbsent(rootId, ThreadEntry.new);
    if (entry.replies.any((r) => r.id == msg.id)) return;
    entry.activity++;
    entry.root ??= _findById(rootId);
    entry.replies.add(msg);
    if (isNew) _enforceThreadCap();
  }

  void _enforceThreadCap() {
    while (_threads.length > kMaxTrackedThreads) {
      String? oldestKey;
      var oldest = 1 << 62;
      for (final e in _threads.entries) {
        if (e.value.activity < oldest) {
          oldest = e.value.activity;
          oldestKey = e.key;
        }
      }
      if (oldestKey == null) return;
      _threads.remove(oldestKey);
    }
  }

  void _decayThreads(List<BenchMessage> evicted) {
    if (_threads.isEmpty) return;
    for (final msg in evicted) {
      final rootId = msg.replyRootId;
      if (rootId == null) continue;
      final entry = _threads[rootId];
      if (entry == null) continue;
      entry.replies.removeWhere((r) => r.id == msg.id);
      if (entry.replies.isEmpty && entry.root == null) _threads.remove(rootId);
    }
  }

  BenchMessage? _findById(String id) {
    for (final m in _items) {
      if (m.id == id) return m;
    }
    return null;
  }

  @override
  List<BenchMessage> recent(int n) {
    final end = min(n, _items.length);
    return _items.sublist(0, end);
  }

  @override
  List<BenchMessage>? lookupThread(String rootId) {
    final entry = _threads[rootId];
    if (entry == null) return null;
    return [if (entry.root != null) entry.root!, ...entry.replies];
  }

  @override
  String? firstThreadRoot() {
    for (final e in _threads.entries) {
      if (e.value.replies.isNotEmpty) return e.key;
    }
    return null;
  }
}

/// Copy-on-write store. Every receive builds a fresh items list, id set, and
/// thread map from the previous version, then applies the same laws. Set
/// [copySeen] to false to keep the dedup set as a shared mutable index, which
/// isolates rehash cost from buffer-copy cost.
class ImmutableStore implements KernelStore {
  ImmutableStore({this.copySeen = true});

  final bool copySeen;

  List<BenchMessage> _items = const [];
  Set<String> _seenIds = {};
  Map<String, ThreadEntry> _threads = const {};
  int _mentionCount = 0;
  bool _hasUnread = false;
  DateTime _clock = DateTime.utc(2026);
  DateTime? _lastTruncateAt;

  @override
  int get length => _items.length;
  @override
  bool get hasUnread => _hasUnread;
  @override
  int get mentionCount => _mentionCount;

  @override
  void advance(Duration d) => _clock = _clock.add(d);

  @override
  bool receive(BenchMessage msg, {required bool isSelected, String? ownId}) {
    if (_seenIds.contains(msg.id)) return false;

    final nextItems = <BenchMessage>[msg, ..._items];
    final nextSeen = copySeen ? <String>{..._seenIds} : _seenIds;
    final nextThreads = <String, ThreadEntry>{
      for (final e in _threads.entries) e.key: e.value.copy(),
    };

    final evicted = <BenchMessage>[];
    if (nextItems.length > kCap) {
      final since = _lastTruncateAt == null
          ? null
          : _clock.difference(_lastTruncateAt!);
      final overHard = nextItems.length > kCap * kHardCapFactor;
      if (since == null || since >= kCoalesceWindow || overHard) {
        _lastTruncateAt = _clock;
        while (nextItems.length > kCap) {
          final m = nextItems.removeLast();
          nextSeen.remove(m.id);
          evicted.add(m);
        }
      }
    }
    nextSeen.add(msg.id);
    _items = nextItems;
    _seenIds = nextSeen;
    _threads = nextThreads;

    _decayThreads(evicted);
    _indexThread(msg);
    if (ownId == msg.id) return true;
    final mention = msg.hasMention;
    if (mention && !msg.isHistory && !isSelected) _mentionCount++;
    if (!isSelected && !msg.isHistory && !msg.isSystem) _hasUnread = true;
    return true;
  }

  void _indexThread(BenchMessage msg) {
    final rootId = msg.replyRootId;
    if (rootId == null) return;
    final isNew = !_threads.containsKey(rootId);
    final entry = _threads.putIfAbsent(rootId, ThreadEntry.new);
    if (entry.replies.any((r) => r.id == msg.id)) return;
    entry.activity++;
    entry.root ??= _findById(rootId);
    entry.replies.add(msg);
    if (isNew) _enforceThreadCap();
  }

  void _enforceThreadCap() {
    while (_threads.length > kMaxTrackedThreads) {
      String? oldestKey;
      var oldest = 1 << 62;
      for (final e in _threads.entries) {
        if (e.value.activity < oldest) {
          oldest = e.value.activity;
          oldestKey = e.key;
        }
      }
      if (oldestKey == null) return;
      _threads.remove(oldestKey);
    }
  }

  void _decayThreads(List<BenchMessage> evicted) {
    if (_threads.isEmpty) return;
    for (final msg in evicted) {
      final rootId = msg.replyRootId;
      if (rootId == null) continue;
      final entry = _threads[rootId];
      if (entry == null) continue;
      entry.replies.removeWhere((r) => r.id == msg.id);
      if (entry.replies.isEmpty && entry.root == null) _threads.remove(rootId);
    }
  }

  BenchMessage? _findById(String id) {
    for (final m in _items) {
      if (m.id == id) return m;
    }
    return null;
  }

  @override
  List<BenchMessage> recent(int n) {
    final end = min(n, _items.length);
    return _items.sublist(0, end);
  }

  @override
  List<BenchMessage>? lookupThread(String rootId) {
    final entry = _threads[rootId];
    if (entry == null) return null;
    return [if (entry.root != null) entry.root!, ...entry.replies];
  }

  @override
  String? firstThreadRoot() {
    for (final e in _threads.entries) {
      if (e.value.replies.isNotEmpty) return e.key;
    }
    return null;
  }
}

/// 5000 rows in 25 bursts of 200. About 5 percent are duplicates of an earlier
/// id, about 10 percent are replies whose root is an earlier row. The workload
/// is built once and fed identically to every store so message construction is
/// excluded from timings.
List<List<BenchMessage>> buildBursts() {
  final rng = Random(0xBEEF);
  final bursts = <List<BenchMessage>>[];
  final seen = <BenchMessage>[];
  var counter = 0;
  for (var b = 0; b < kBursts; b++) {
    final burst = <BenchMessage>[];
    for (var i = 0; i < kBurstSize; i++) {
      if (seen.isNotEmpty && rng.nextDouble() < 0.05) {
        burst.add(seen[rng.nextInt(seen.length)]);
        continue;
      }
      String? rootId;
      if (seen.isNotEmpty && rng.nextDouble() < 0.10) {
        final parent = seen[rng.nextInt(seen.length)];
        rootId = parent.replyRootId ?? parent.id;
      }
      final msg = BenchMessage(
        'm${counter++}',
        rootId,
        hasMention: rng.nextDouble() < 0.02,
      );
      burst.add(msg);
      seen.add(msg);
    }
    bursts.add(burst);
  }
  return bursts;
}

void ingest(KernelStore store, List<List<BenchMessage>> bursts) {
  for (final burst in bursts) {
    store.advance(kBurstGap);
    for (final msg in burst) {
      store.receive(msg, isSelected: false);
    }
  }
}

int read(KernelStore store) {
  var acc = 0;
  for (final m in store.recent(kReadRecent)) {
    acc += m.id.length;
  }
  final root = store.firstThreadRoot();
  final thread = root == null ? null : store.lookupThread(root);
  if (thread != null) {
    for (final m in thread) {
      acc += m.id.length;
    }
  }
  acc += store.mentionCount + (store.hasUnread ? 1 : 0);
  return acc;
}

List<double> measure(
  KernelStore Function() create,
  List<List<BenchMessage>> bursts,
) {
  for (var w = 0; w < kWarmups; w++) {
    final store = create();
    ingest(store, bursts);
    read(store);
  }
  final samples = <double>[];
  for (var i = 0; i < kIterations; i++) {
    final store = create();
    final sw = Stopwatch()..start();
    ingest(store, bursts);
    read(store);
    sw.stop();
    samples.add(sw.elapsedMicroseconds / 1000.0);
  }
  return samples;
}

class Stats {
  Stats(List<double> samples) : sorted = [...samples]..sort();

  final List<double> sorted;

  double get median => _pct(0.5);
  double get p90 => _pct(0.9);

  double _pct(double p) {
    final idx = (p * sorted.length).ceil() - 1;
    return sorted[idx.clamp(0, sorted.length - 1)];
  }
}

void printRow(String name, List<double> samples, int rssDeltaKb) {
  final s = Stats(samples);
  final perMsgUs = s.median * 1000.0 / kTotal;
  final nameCol = name.padRight(28);
  final med = s.median.toStringAsFixed(2).padLeft(9);
  final p90 = s.p90.toStringAsFixed(2).padLeft(9);
  final per = perMsgUs.toStringAsFixed(2).padLeft(10);
  final rss = '$rssDeltaKb'.padLeft(8);
  stdout.writeln('$nameCol$med$p90$per$rss');
}

void main() {
  final bursts = buildBursts();
  final total = bursts.fold<int>(0, (a, b) => a + b.length);
  stdout.writeln(
    'Spike B: chat-kernel ingest, $total messages in $kBursts bursts',
  );
  stdout.writeln('cap=$kCap  dedup=id set  order=newest-first  thread cap=64');
  stdout.writeln(
    'iterations=$kIterations (warmup=$kWarmups)  time=ingest+read',
  );
  stdout.writeln('');

  final before = ProcessInfo.currentRss;
  final mutable = measure(MutableStore.new, bursts);
  final mutableRss = ProcessInfo.currentRss - before;

  final beforeFull = ProcessInfo.currentRss;
  final immutableFull = measure(() => ImmutableStore(), bursts);
  final immutableFullRss = ProcessInfo.currentRss - beforeFull;

  final beforeShared = ProcessInfo.currentRss;
  final immutableShared = measure(
    () => ImmutableStore(copySeen: false),
    bursts,
  );
  final immutableSharedRss = ProcessInfo.currentRss - beforeShared;

  final header =
      '${'store'.padRight(28)}${'median ms'.padLeft(9)}'
      '${'p90 ms'.padLeft(9)}${'us/msg'.padLeft(10)}${'rss dKB'.padLeft(8)}';
  stdout.writeln(header);
  stdout.writeln('-' * header.length);
  printRow('mutable', mutable, mutableRss ~/ 1024);
  printRow('immutable COW (all)', immutableFull, immutableFullRss ~/ 1024);
  printRow(
    'immutable COW (seen shared)',
    immutableShared,
    immutableSharedRss ~/ 1024,
  );
  stdout.writeln('');

  final mutableMed = Stats(mutable).median;
  final mutableP90 = Stats(mutable).p90;
  final fullMed = Stats(immutableFull).median;
  final fullP90 = Stats(immutableFull).p90;
  final sharedMed = Stats(immutableShared).median;
  final sharedP90 = Stats(immutableShared).p90;
  stdout.writeln(
    'ratio immutable/mutable (median): '
    '${(fullMed / mutableMed).toStringAsFixed(2)}x',
  );
  stdout.writeln(
    'ratio immutable/mutable (p90):    '
    '${(fullP90 / mutableP90).toStringAsFixed(2)}x',
  );
  stdout.writeln(
    'ratio shared-seen/mutable (median): '
    '${(sharedMed / mutableMed).toStringAsFixed(2)}x',
  );
  stdout.writeln(
    'ratio shared-seen/mutable (p90):    '
    '${(sharedP90 / mutableP90).toStringAsFixed(2)}x',
  );
  stdout.writeln('');
  stdout.writeln(
    'rss is a rough process-wide signal; no GC control, treat as advisory.',
  );
}
