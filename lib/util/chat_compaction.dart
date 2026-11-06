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

/// Matches needed before a text becomes a repeat group.
const chatCompactMin = 3;

/// Matches needed when the previous chunk already had this group.
const chatCompactResumeMin = 2;

/// Tokens a fuzzy match needs, so short replies never merge.
const chatFuzzyMinTokens = 3;

/// Characters a fuzzy match needs, for the same reason.
const chatFuzzyMinChars = 12;

final _spaces = RegExp(r'\s+');
final _edgePunctuation = RegExp(
  "^[.,!?;:\"'\u2018\u2019\u201c\u201d()\\[\\]{}]+"
  "|[.,!?;:\"'\u2018\u2019\u201c\u201d()\\[\\]{}]+\$",
);

/// Tokens by message, dropped when the message text changes. A regroup runs
/// on every live arrival, so old rows must not be tokenized again.
final _tokenCache = Expando<(String, List<String>)>();

/// Groups repeats inside fixed time buckets. Exact text forms a group first,
/// then one-word variants join it. A group's summary is its first row. Rows
/// the caller excludes stay visible and do not count.
ChatCompaction compactChat(
  List<TwitchMessage> rows, {
  bool Function(TwitchMessage)? skip,
}) {
  final counts = <int, int>{};
  final hidden = <int, int>{};
  if (rows.isEmpty) return const ChatCompaction(counts: {}, hidden: {});

  var bucket = -1;
  var bucketRows = 0;
  var groups = <String, _Group>{};
  var seeds = <_Seed>[];

  void flush() {
    seeds = _emit(groups.values, counts, hidden, seeds);
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
    final channel = msg.channel ?? '';
    final key = '$channel\u0000$text';
    final tokens = _tokensFor(msg, text);
    (groups[key] ??= _Group(channel, text, i, tokens)).members.add(i);
  }
  flush();
  return ChatCompaction(counts: counts, hidden: hidden);
}

/// Builds groups from exact texts, then folds similar ones together. Two
/// strong exact groups stay apart unless their words match after case and
/// punctuation folding, so two copypastas never merge by one word.
List<_Seed> _emit(
  Iterable<_Group> exact,
  Map<int, int> counts,
  Map<int, int> hidden,
  List<_Seed> seeds,
) {
  if (exact.isEmpty) return const [];
  final groups = exact.toList()
    ..sort((a, b) {
      final bySize = b.members.length.compareTo(a.members.length);
      return bySize != 0 ? bySize : a.start.compareTo(b.start);
    });
  final clusters = <_Cluster>[];
  final small = <_Group>[];

  for (final group in groups) {
    final resumed = _matchesSeed(group, seeds);
    final min = resumed ? chatCompactResumeMin : chatCompactMin;
    if (group.members.length < min) {
      small.add(group);
      continue;
    }
    _Cluster? same;
    if (_eligible(group)) {
      for (final cluster in clusters) {
        if (group.channel == cluster.anchor.channel &&
            _eligible(cluster.anchor) &&
            _distance(group.tokens, cluster.anchor.tokens) == 0) {
          same = cluster;
          break;
        }
      }
    }
    if (same != null) {
      same.groups.add(group);
      same.resumed |= resumed;
    } else {
      clusters.add(_Cluster(group, resumed));
    }
  }

  for (final group in [...small]) {
    for (final cluster in clusters) {
      if (_similar(group, cluster.anchor)) {
        cluster.groups.add(group);
        cluster.resumed |= _matchesSeed(group, seeds);
        small.remove(group);
        break;
      }
    }
  }

  for (final group in [...small]) {
    if (!small.remove(group)) continue;
    final cluster = _Cluster(group, _matchesSeed(group, seeds));
    for (final other in [...small]) {
      if (_similar(other, cluster.anchor) && small.remove(other)) {
        cluster.groups.add(other);
        cluster.resumed |= _matchesSeed(other, seeds);
      }
    }
    clusters.add(cluster);
  }

  final next = <_Seed>[];
  for (final cluster in clusters) {
    final members = <int>[for (final group in cluster.groups) ...group.members]
      ..sort();
    final min = cluster.resumed ? chatCompactResumeMin : chatCompactMin;
    if (members.length < min) continue;
    final summary = members.first;
    counts[summary] = members.length;
    for (var i = 1; i < members.length; i++) {
      hidden[members[i]] = summary;
    }
    next.add(_Seed(cluster.anchor.channel, cluster.anchor.tokens));
  }
  return next;
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

bool _eligible(_Group group) =>
    group.tokens.length >= chatFuzzyMinTokens &&
    group.foldedLength >= chatFuzzyMinChars;

bool _eligibleTokens(List<String> tokens) =>
    tokens.length >= chatFuzzyMinTokens &&
    tokens.join(' ').length >= chatFuzzyMinChars;

bool _matchesSeed(_Group group, List<_Seed> seeds) {
  for (final seed in seeds) {
    if (seed.channel == group.channel &&
        _seedSimilar(group.tokens, seed.tokens)) {
      return true;
    }
  }
  return false;
}

bool _seedSimilar(List<String> a, List<String> b) {
  if (_eligibleTokens(a) && _eligibleTokens(b)) {
    return _distance(a, b) <= 1;
  }
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _similar(_Group a, _Group b) =>
    a.channel == b.channel &&
    _eligible(a) &&
    _eligible(b) &&
    _distance(a.tokens, b.tokens) <= 1;

/// Token edit distance capped at 2. URLs, mentions and hashtags never match
/// approximately.
int _distance(List<String> a, List<String> b) {
  if (a.length == b.length) {
    var changes = 0;
    for (var i = 0; i < a.length; i++) {
      if (a[i] == b[i]) continue;
      if (_protected(a[i]) || _protected(b[i])) return 2;
      if (++changes > 1) return 2;
    }
    return changes;
  }
  if ((a.length - b.length).abs() != 1) return 2;
  final longer = a.length > b.length ? a : b;
  final shorter = a.length > b.length ? b : a;
  var removed = -1;
  for (var skip = 0; skip < longer.length; skip++) {
    var same = true;
    for (var i = 0, j = 0; i < longer.length; i++) {
      if (i == skip) continue;
      if (longer[i] != shorter[j]) {
        same = false;
        break;
      }
      j++;
    }
    if (!same) continue;
    if (_protected(longer[skip]) || removed != -1) return 2;
    removed = skip;
  }
  return removed == -1 ? 2 : 1;
}

bool _protected(String token) =>
    token.startsWith('@') ||
    token.startsWith('#') ||
    token.startsWith('http') ||
    token.startsWith('www.') ||
    token.contains('/') ||
    token.contains('.');

List<String> _tokensFor(TwitchMessage msg, String text) {
  final cached = _tokenCache[msg];
  if (cached != null && cached.$1 == text) return cached.$2;
  final tokens = [
    for (final raw in text.split(_spaces))
      raw.toLowerCase().replaceAll(_edgePunctuation, ''),
  ].where((token) => token.isNotEmpty).toList();
  _tokenCache[msg] = (text, tokens);
  return tokens;
}

class _Group {
  _Group(this.channel, this.text, this.start, this.tokens)
    : foldedLength = tokens.join(' ').length;

  final String channel;
  final String text;
  final int start;
  final List<String> tokens;
  final int foldedLength;
  final List<int> members = [];
}

class _Cluster {
  _Cluster(this.anchor, this.resumed) : groups = [anchor];

  final _Group anchor;
  final List<_Group> groups;
  bool resumed;
}

class _Seed {
  const _Seed(this.channel, this.tokens);

  final String channel;
  final List<String> tokens;
}
