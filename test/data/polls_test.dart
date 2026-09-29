import 'package:ermchat/models/polls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Poll reads choices, votes and the end time', () {
    final poll = Poll.fromJson({
      'id': 'p1',
      'title': 'Best map?',
      'status': 'ACTIVE',
      'ends_at': '2026-01-01T00:05:00Z',
      'choices': [
        {'id': 'c1', 'title': 'Dust', 'votes': 3},
        {'id': 'c2', 'title': 'Mirage', 'votes': 4},
      ],
    });
    expect(poll.isActive, isTrue);
    expect(poll.choices.map((c) => c.title), ['Dust', 'Mirage']);
    expect(poll.totalVotes, 7);
    expect(poll.endsAt, DateTime.utc(2026, 1, 1, 0, 5).toLocal());
  });

  test('Poll tolerates missing fields', () {
    final poll = Poll.fromJson(const {});
    expect(poll.choices, isEmpty);
    expect(poll.endsAt, isNull);
    expect(poll.isActive, isFalse);
  });

  group('Prediction', () {
    final prediction = Prediction.fromJson({
      'id': 'pr1',
      'title': 'Win?',
      'status': 'LOCKED',
      'outcomes': [
        {'id': 'o1', 'title': 'Yes', 'users': 5, 'channel_points': 900},
        {'id': 'o2', 'title': 'No'},
      ],
    });

    test('reads status and outcomes', () {
      expect(prediction.isOpen, isTrue);
      expect(prediction.isLocked, isTrue);
      expect(prediction.isActive, isFalse);
      expect(prediction.outcomes.first.channelPoints, 900);
      expect(prediction.outcomes.last.users, isNull);
    });

    test('outcomeFor matches a 1-based index or a title', () {
      expect(prediction.outcomeFor('2')?.id, 'o2');
      expect(prediction.outcomeFor('yes')?.id, 'o1');
      expect(prediction.outcomeFor('3'), isNull);
      expect(prediction.outcomeFor('maybe'), isNull);
    });
  });
}
