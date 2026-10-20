import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/util/history_timeline.dart';
import 'package:ermchat/util/history_window.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 10, 13, 12);

/// One row a day at noon UTC, [daysAgo] days back.
TwitchMessage _row(int daysAgo, {bool id = true}) => TwitchMessage(
  login: 'u',
  text: 'day $daysAgo',
  timestamp: _now.subtract(Duration(days: daysAgo)),
  messageId: id ? 'm$daysAgo' : null,
);

List<String> _dayMarkers(HistoryWindow w) => [
  for (var p = w.first; p < w.end; p++)
    for (final m in w.markersAt(p))
      if (m.kind == HistoryMarkerKind.day) w[p].text,
];

void main() {
  test('an older read into an empty window marks its rows', () {
    // A list opening with nothing (mentions before any arrive) loads older
    // rows into an empty window; marking ran past the rows and threw.
    final w = HistoryWindow(now: () => _now, local: (t) => t);
    w.reset(const []);
    expect(w.prepend([_row(3), _row(2)]), 2);
    expect(_dayMarkers(w), ['day 2']);
  });

  test('markers and dedup hold across the seam of an older read', () {
    final w = HistoryWindow(now: () => _now, local: (t) => t);
    w.reset([_row(5), _row(4), _row(3)]);
    expect(_dayMarkers(w), [
      'day 4',
      'day 3',
    ], reason: 'the first row has no known predecessor yet');
    // The read overlaps the held first row; it must attach once.
    expect(w.prepend([_row(7), _row(6), _row(5)]), 2);
    expect(w.length, 5);
    expect(_dayMarkers(w), [
      'day 6',
      'day 5',
      'day 4',
      'day 3',
    ], reason: 'the old first row gains its marker once its predecessor loads');
    w.markOldest();
    expect(_dayMarkers(w).first, 'day 7', reason: 'oldest row marks its day');
    // Archive rows lose ids after a day; their key still dedups.
    w.append([_row(2, id: false)]);
    expect(
      w.append([_row(2, id: false)]),
      0,
      reason: 'id-less duplicate attached twice',
    );
  });

  test('trimmed rows read back in place, positions never shift', () {
    final w = HistoryWindow(now: () => _now, local: (t) => t);
    w.reset([for (var d = 9; d >= 3; d--) _row(d)]);
    final p5 = w.positionAt(_row(5).timestamp);
    expect(w[p5].text, 'day 5');

    w.trimBefore(p5);
    expect(w.first, p5, reason: 'positions keep their rows');
    expect(w.atOldest, isFalse);
    expect(w.markersAt(p5), isEmpty, reason: 'its predecessor is gone');
    w.trimFrom(p5 + 2);
    expect(w.atNewest, isFalse);
    expect(
      [for (var p = w.first; p < w.end; p++) w[p].text],
      ['day 5', 'day 4'],
    );

    expect(
      w.prepend([_row(7), _row(6), _row(5)]),
      2,
      reason: 'trimmed rows must attach again, not dedup against stale keys',
    );
    expect(w.append([_row(4), _row(3)]), 1);
    expect(w[p5].text, 'day 5', reason: 'a re-read lands at the same spot');
    expect(w.markersAt(p5), isNotEmpty, reason: 'its marker comes back');

    // Rows sharing a time: the first of them is where that time starts.
    final tie = _row(3).timestamp;
    w.append([
      TwitchMessage(login: 'u', text: 'tie a', timestamp: tie, messageId: 'a'),
      TwitchMessage(login: 'u', text: 'tie b', timestamp: tie, messageId: 'b'),
    ]);
    expect(w[w.positionAt(tie)].text, 'day 3');
    expect(w.positionAt(_now), w.end, reason: 'past the newest is the end');
  });
}
