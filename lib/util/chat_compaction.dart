import '../models/twitch_message.dart';

/// Repeat groups found in a run of chat rows, oldest first.
class ChatCompaction {
  const ChatCompaction({required this.counts, required this.hidden});

  /// Summary row index to the number of messages it represents.
  final Map<int, int> counts;

  /// Hidden row index to the summary row index it belongs under.
  final Map<int, int> hidden;
}

/// Seconds of chat that share one repeat grouping.
const chatCompactSeconds = 10;

/// Rows in one grouping, so a fast wave cannot grow without bound.
const chatCompactRows = 100;

/// Rows needed before a text folds. Two keeps the second row from painting
/// and then retracting, which reads as a stutter.
const chatCompactMin = 2;

final _spaces = RegExp(r'\s+');
final _edgePunctuation = RegExp(r'^\p{P}+|\p{P}+$', unicode: true);

/// Groups identical texts inside fixed time buckets. Text matches after
/// trimming, collapsing spaces, folding case and dropping edge punctuation.
/// A group's summary is its first row. Excluded rows stay visible, uncounted.
ChatCompaction compactChat(
  List<TwitchMessage> rows, {
  bool Function(TwitchMessage)? skip,
}) {
  final counts = <int, int>{};
  final hidden = <int, int>{};
  if (rows.isEmpty) return const ChatCompaction(counts: {}, hidden: {});

  var bucket = -1;
  var bucketRows = 0;
  var groups = <String, List<int>>{};

  void flush() {
    for (final members in groups.values) {
      if (members.length < chatCompactMin) continue;
      final summary = members.first;
      counts[summary] = members.length;
      for (var i = 1; i < members.length; i++) {
        hidden[members[i]] = summary;
      }
    }
    groups = {};
  }

  for (var i = 0; i < rows.length; i++) {
    final msg = rows[i];
    final at =
        msg.timestamp.millisecondsSinceEpoch ~/
        (chatCompactSeconds * Duration.millisecondsPerSecond);
    if (at != bucket || bucketRows >= chatCompactRows) {
      flush();
      bucket = at;
      bucketRows = 0;
    }
    bucketRows++;
    if (!_groupable(msg, skip)) continue;
    final text = msg.text.trim().replaceAll(_spaces, ' ');
    if (text.isEmpty) continue;
    final folded = text.toLowerCase().replaceAll(_edgePunctuation, '');
    (groups['${msg.channel ?? ''}\u0000$folded'] ??= []).add(i);
  }
  flush();
  return ChatCompaction(counts: counts, hidden: hidden);
}

bool _groupable(TwitchMessage msg, bool Function(TwitchMessage)? skip) {
  if (msg.isSystem || msg.deleted || msg.isHighlighted) return false;
  if (msg.isFirstMessage || msg.replyToUser != null) return false;
  if (msg.customRewardId != null || msg.redemptionPoints != null) return false;
  if (msg.redemptionImageUrl != null || msg.bitsAmount != null) return false;
  if (msg.pinnedPaidAmount != null) return false;
  if (msg.msgId == 'highlighted-message') return false;
  return !(skip?.call(msg) ?? false);
}
