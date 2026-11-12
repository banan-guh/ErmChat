import '../models/twitch_message.dart';

/// Repeat groups found in a run of chat rows, oldest first.
class ChatCompaction {
  const ChatCompaction({required this.counts, required this.hidden});

  /// Summary row index to the number of messages it represents.
  final Map<int, int> counts;

  /// Hidden row index to the summary row index it belongs under.
  final Map<int, int> hidden;
}

/// Longest gap between two copies of a text that still joins them into one
/// run. A longer pause starts a new run, so waves do not merge forever.
const chatCompactSeconds = 10;

/// Rows one run may span, so a fast wave cannot grow without bound.
const chatCompactRows = 100;

/// Rows needed before a text folds. Two keeps the second row from painting
/// and then retracting, which reads as a stutter.
const chatCompactMin = 2;

final _spaces = RegExp(r'\s+');
final _edgePunctuation = RegExp(r'^\p{P}+|\p{P}+$', unicode: true);

/// Groups copies of one text into runs. Text matches after trimming,
/// collapsing spaces, folding case and dropping edge punctuation. Copies
/// join a run while each lands within [chatCompactSeconds] of the previous
/// one and the run spans fewer than [chatCompactRows] rows. A run's summary
/// is its first row. Excluded rows stay visible, uncounted.
ChatCompaction compactChat(
  List<TwitchMessage> rows, {
  bool Function(TwitchMessage)? skip,
}) {
  final counts = <int, int>{};
  final hidden = <int, int>{};
  if (rows.isEmpty) return const ChatCompaction(counts: {}, hidden: {});

  void emit(_Run run) {
    final members = run.members;
    if (members.length < chatCompactMin) return;
    final summary = members.first;
    counts[summary] = members.length;
    for (var i = 1; i < members.length; i++) {
      hidden[members[i]] = summary;
    }
  }

  final runs = <String, _Run>{};
  for (var i = 0; i < rows.length; i++) {
    final msg = rows[i];
    if (!_groupable(msg, skip)) continue;
    final text = msg.text.trim().replaceAll(_spaces, ' ');
    if (text.isEmpty) continue;
    final folded = text.toLowerCase().replaceAll(_edgePunctuation, '');
    final key = '${msg.channel ?? ''}\u0000$folded';
    final run = runs[key];
    if (run != null) {
      final gap = msg.timestamp.difference(run.last).inMilliseconds;
      if (gap >= 0 &&
          gap < chatCompactSeconds * Duration.millisecondsPerSecond &&
          i - run.start < chatCompactRows) {
        run.members.add(i);
        run.last = msg.timestamp;
        continue;
      }
      emit(run);
    }
    runs[key] = _Run(i, msg.timestamp);
  }
  for (final run in runs.values) {
    emit(run);
  }
  return ChatCompaction(counts: counts, hidden: hidden);
}

bool _groupable(TwitchMessage msg, bool Function(TwitchMessage)? skip) {
  if (msg.isHeld || msg.isSystem || msg.deleted || msg.isHighlighted) {
    return false;
  }
  if (msg.isFirstMessage || msg.replyToUser != null) return false;
  if (msg.customRewardId != null || msg.redemptionPoints != null) return false;
  if (msg.redemptionImageUrl != null || msg.bitsAmount != null) return false;
  if (msg.pinnedPaidAmount != null) return false;
  if (msg.msgId == 'highlighted-message') return false;
  return !(skip?.call(msg) ?? false);
}

class _Run {
  _Run(this.start, this.last) : members = [start];

  /// Row index of the first copy, which becomes the summary.
  final int start;
  final List<int> members;

  /// Time of the newest copy, for the gap test.
  DateTime last;
}
