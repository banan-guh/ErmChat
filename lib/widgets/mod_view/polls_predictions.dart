import 'package:flutter/material.dart';

import '../../models/polls.dart';
import '../../util/date_format.dart';
import '../dialogs.dart';
import 'dialogs.dart';
import 'scope.dart';
import 'widgets.dart';

/// The running poll with end and archive, or a form to start one.
class PollsSection extends ModTabWidget {
  const PollsSection({super.key, required super.mod});

  @override
  State<PollsSection> createState() => _PollsSectionState();
}

class _PollsSectionState extends State<PollsSection>
    with ModTabState<PollsSection> {
  late final ModLoader<List<Poll>> _polls;

  @override
  void initState() {
    super.initState();
    _polls = loader(
      (mod) => mod.actions.getPolls(mod.auth, mod.channel),
      failure: 'Could not load polls.',
    );
  }

  Future<void> _end(Poll poll, {required bool archive}) async {
    if (anyBusy) return;
    final confirmed = await confirmDialog(
      context,
      title: archive ? 'Cancel poll?' : 'End poll now?',
      message: archive
          ? 'This archives the poll without showing results.'
          : 'This ends the poll and shows the results (TERMINATED).',
      confirmLabel: archive ? 'Cancel poll' : 'End poll',
      cancelLabel: 'Back',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await busy('end', () async {
      final ok = await mod.report(
        mod.actions.endPoll(
          mod.auth,
          mod.channel,
          pollId: poll.id,
          archive: archive,
        ),
        done: archive ? 'Poll cancelled.' : 'Poll ended.',
      );
      if (ok) await _polls.load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ModLoadView(
      loader: _polls,
      inline: true,
      builder: (context, polls) {
        final active = polls.where((p) => p.isActive).firstOrNull;
        if (active == null) {
          return _PollForm(mod: mod, onCreated: _polls.load);
        }
        final endsAt = active.endsAt;
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          title: Text(active.title.isEmpty ? 'Poll' : active.title),
          subtitle: Text(
            [
              '${active.choices.length} choices',
              '${active.totalVotes} votes',
              if (endsAt != null) 'ends ${formatIn(endsAt)}',
            ].join(' · '),
          ),
          trailing: anyBusy
              ? const ModSpinner()
              : Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () => _end(active, archive: false),
                      child: const Text('End'),
                    ),
                    TextButton(
                      onPressed: () => _end(active, archive: true),
                      child: const Text('Archive'),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _PollForm extends StatefulWidget {
  const _PollForm({required this.mod, required this.onCreated});

  final ModContext mod;
  final VoidCallback onCreated;

  @override
  State<_PollForm> createState() => _PollFormState();
}

class _PollFormState extends State<_PollForm> {
  static const _durations = [
    ('15s', 15),
    ('1m', 60),
    ('2m', 120),
    ('5m', 300),
    ('10m', 600),
    ('30m', 1800),
  ];

  final _title = TextEditingController();
  final _choices = [TextEditingController(), TextEditingController()];
  int _duration = 60;
  bool _creating = false;

  @override
  void dispose() {
    _title.dispose();
    for (final c in _choices) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _create() async {
    final mod = widget.mod;
    final title = _title.text.trim();
    final choices = [
      for (final c in _choices)
        if (c.text.trim().isNotEmpty) c.text.trim(),
    ];
    if (title.isEmpty || choices.length < 2) {
      mod.notify('Enter a title and at least 2 choices.');
      return;
    }
    if (_creating) return;
    setState(() => _creating = true);
    try {
      final ok = await mod.report(
        mod.actions.createPoll(
          mod.auth,
          mod.channel,
          title: title,
          choices: choices,
          durationSeconds: _duration,
        ),
        done: 'Poll started.',
      );
      if (ok) widget.onCreated();
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('No active poll.'),
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Poll title'),
          ),
          for (final (i, choice) in _choices.indexed)
            TextField(
              controller: choice,
              decoration: InputDecoration(labelText: 'Choice ${i + 1}'),
            ),
          Row(
            children: [
              const Text('Duration:'),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _duration,
                items: [
                  for (final (label, seconds) in _durations)
                    DropdownMenuItem(value: seconds, child: Text(label)),
                ],
                onChanged: _creating
                    ? null
                    : (v) => setState(() => _duration = v ?? 60),
              ),
              const Spacer(),
              // Twitch allows 2-5 choices.
              if (_choices.length < 5)
                TextButton(
                  onPressed: _creating
                      ? null
                      : () => setState(
                          () => _choices.add(TextEditingController()),
                        ),
                  child: const Text('Add choice'),
                ),
            ],
          ),
          FilledButton(
            onPressed: _creating ? null : _create,
            child: _creating
                ? const ModSpinner(size: 18)
                : const Text('Start poll'),
          ),
        ],
      ),
    );
  }
}

/// The open prediction with lock, resolve, and cancel.
class PredictionsSection extends ModTabWidget {
  const PredictionsSection({super.key, required super.mod});

  @override
  State<PredictionsSection> createState() => _PredictionsSectionState();
}

class _PredictionsSectionState extends State<PredictionsSection>
    with ModTabState<PredictionsSection> {
  late final ModLoader<List<Prediction>> _predictions;

  @override
  void initState() {
    super.initState();
    _predictions = loader(
      (mod) => mod.actions.getPredictions(mod.auth, mod.channel),
      failure: 'Could not load predictions.',
    );
  }

  Future<void> _end(
    Prediction prediction,
    String status, {
    String? winningOutcomeId,
    required String done,
  }) => busy('end', () async {
    final ok = await mod.report(
      mod.actions.endPrediction(
        mod.auth,
        mod.channel,
        predictionId: prediction.id,
        status: status,
        winningOutcomeId: winningOutcomeId,
      ),
      done: done,
    );
    if (ok) await _predictions.load();
  });

  Future<void> _cancel(Prediction prediction) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Cancel prediction?',
      message: 'Points are refunded to predictors.',
      confirmLabel: 'Cancel prediction',
      cancelLabel: 'Back',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _end(prediction, 'CANCELED', done: 'Prediction cancelled.');
  }

  Future<void> _resolve(Prediction prediction) async {
    final winner = await showModChoiceDialog(
      context,
      title: 'Winning outcome',
      options: [
        for (final outcome in prediction.outcomes)
          (_outcomeLabel(outcome), outcome.id),
      ],
    );
    if (winner == null || winner.isEmpty || !mounted) return;
    await _end(
      prediction,
      'RESOLVED',
      winningOutcomeId: winner,
      done: 'Prediction resolved.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return ModLoadView(
      loader: _predictions,
      inline: true,
      builder: (context, predictions) {
        final open = predictions.where((p) => p.isOpen).firstOrNull;
        if (open == null) {
          return const ListTile(
            title: Text('No open prediction. Create one with /prediction.'),
          );
        }
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          title: Text(open.title.isEmpty ? 'Prediction' : open.title),
          subtitle: Text(
            '${open.outcomes.length} outcomes'
            '${open.isLocked ? ' · locked' : ''}',
          ),
          trailing: anyBusy
              ? const ModSpinner()
              : Wrap(
                  spacing: 8,
                  children: [
                    if (!open.isLocked)
                      OutlinedButton(
                        onPressed: () =>
                            _end(open, 'LOCKED', done: 'Prediction locked.'),
                        child: const Text('Lock'),
                      ),
                    FilledButton(
                      onPressed: () => _resolve(open),
                      child: const Text('Resolve'),
                    ),
                    TextButton(
                      onPressed: () => _cancel(open),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

String _outcomeLabel(PredictionOutcome outcome) {
  final detail = [
    if (outcome.channelPoints != null) '${outcome.channelPoints} pts',
    if (outcome.users != null) '${outcome.users} predictors',
  ].join(' · ');
  final title = outcome.title.isEmpty ? 'Outcome' : outcome.title;
  return detail.isEmpty ? title : '$title ($detail)';
}
