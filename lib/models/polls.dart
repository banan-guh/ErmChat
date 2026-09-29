/// A Helix poll (`GET /polls`).
class Poll {
  const Poll({
    required this.id,
    required this.title,
    required this.status,
    required this.choices,
    this.endsAt,
  });

  factory Poll.fromJson(Map<String, dynamic> json) => Poll(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    status: json['status'] as String? ?? '',
    choices: [
      for (final c in json['choices'] as List? ?? const [])
        if (c is Map<String, dynamic>) PollChoice.fromJson(c),
    ],
    endsAt: DateTime.tryParse(json['ends_at'] as String? ?? '')?.toLocal(),
  );

  final String id;
  final String title;

  /// ACTIVE, COMPLETED, TERMINATED, ARCHIVED, MODERATED or INVALID.
  final String status;
  final List<PollChoice> choices;
  final DateTime? endsAt;

  bool get isActive => status == 'ACTIVE';

  int get totalVotes => choices.fold(0, (sum, c) => sum + c.votes);
}

class PollChoice {
  const PollChoice({required this.id, required this.title, this.votes = 0});

  factory PollChoice.fromJson(Map<String, dynamic> json) => PollChoice(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    votes: (json['votes'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String title;
  final int votes;
}

/// A Helix prediction (`GET /predictions`).
class Prediction {
  const Prediction({
    required this.id,
    required this.title,
    required this.status,
    required this.outcomes,
  });

  factory Prediction.fromJson(Map<String, dynamic> json) => Prediction(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    status: json['status'] as String? ?? '',
    outcomes: [
      for (final o in json['outcomes'] as List? ?? const [])
        if (o is Map<String, dynamic>) PredictionOutcome.fromJson(o),
    ],
  );

  final String id;
  final String title;

  /// ACTIVE, LOCKED, RESOLVED or CANCELED.
  final String status;
  final List<PredictionOutcome> outcomes;

  bool get isActive => status == 'ACTIVE';
  bool get isLocked => status == 'LOCKED';

  /// Still awaiting a result: taking predictions or locked.
  bool get isOpen => isActive || isLocked;

  /// The outcome whose 1-based position or title (any case) is [selector].
  PredictionOutcome? outcomeFor(String selector) {
    final index = int.tryParse(selector);
    if (index != null && index >= 1 && index <= outcomes.length) {
      return outcomes[index - 1];
    }
    final lower = selector.toLowerCase();
    for (final o in outcomes) {
      if (o.title.toLowerCase() == lower) return o;
    }
    return null;
  }
}

class PredictionOutcome {
  const PredictionOutcome({
    required this.id,
    required this.title,
    this.users,
    this.channelPoints,
  });

  factory PredictionOutcome.fromJson(Map<String, dynamic> json) =>
      PredictionOutcome(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        users: (json['users'] as num?)?.toInt(),
        channelPoints: (json['channel_points'] as num?)?.toInt(),
      );

  final String id;
  final String title;
  final int? users;
  final int? channelPoints;
}
