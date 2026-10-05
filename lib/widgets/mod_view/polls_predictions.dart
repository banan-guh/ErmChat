import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
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
      failure: mod.l10n.loadPollsFailed,
    );
  }

  Future<void> _end(Poll poll, {required bool archive}) async {
    if (anyBusy) return;
    final confirmed = await confirmDialog(
      context,
      title: archive ? mod.l10n.cancelPollTitle : mod.l10n.endPollTitle,
      message: archive ? mod.l10n.cancelPollMessage : mod.l10n.endPollMessage,
      confirmLabel: archive ? mod.l10n.cancelPoll : mod.l10n.endPoll,
      cancelLabel: mod.l10n.back,
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
        done: archive ? mod.l10n.pollCancelled : mod.l10n.pollEnded,
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
          title: Text(active.title.isEmpty ? mod.l10n.poll : active.title),
          subtitle: Text(
            [
              mod.l10n.choiceCount(active.choices.length),
              mod.l10n.voteCount(active.totalVotes),
              if (endsAt != null) mod.l10n.endsIn(formatIn(endsAt)),
            ].join(' · '),
          ),
          trailing: anyBusy
              ? const ModSpinner()
              : Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () => _end(active, archive: false),
                      child: Text(mod.l10n.end),
                    ),
                    TextButton(
                      onPressed: () => _end(active, archive: true),
                      child: Text(mod.l10n.archive),
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
      mod.notify(mod.l10n.pollNeedsChoices);
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
        done: mod.l10n.pollStarted,
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
          Text(widget.mod.l10n.noActivePoll),
          TextField(
            controller: _title,
            decoration: InputDecoration(labelText: widget.mod.l10n.pollTitle),
          ),
          for (final (i, choice) in _choices.indexed)
            TextField(
              controller: choice,
              decoration: InputDecoration(
                labelText: widget.mod.l10n.choiceNumber(i + 1),
              ),
            ),
          Row(
            children: [
              Text(widget.mod.l10n.durationLabel),
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
                  child: Text(widget.mod.l10n.addChoice),
                ),
            ],
          ),
          FilledButton(
            onPressed: _creating ? null : _create,
            child: _creating
                ? const ModSpinner(size: 18)
                : Text(widget.mod.l10n.startPoll),
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
      failure: mod.l10n.loadPredictionsFailed,
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
      title: mod.l10n.cancelPredictionTitle,
      message: mod.l10n.cancelPredictionMessage,
      confirmLabel: mod.l10n.cancelPrediction,
      cancelLabel: mod.l10n.back,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _end(prediction, 'CANCELED', done: mod.l10n.predictionCancelled);
  }

  Future<void> _resolve(Prediction prediction) async {
    final winner = await showModChoiceDialog(
      context,
      title: mod.l10n.winningOutcome,
      options: [
        for (final outcome in prediction.outcomes)
          (_outcomeLabel(mod.l10n, outcome), outcome.id),
      ],
    );
    if (winner == null || winner.isEmpty || !mounted) return;
    await _end(
      prediction,
      'RESOLVED',
      winningOutcomeId: winner,
      done: mod.l10n.predictionResolved,
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
          return ListTile(title: Text(mod.l10n.noOpenPrediction));
        }
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          title: Text(open.title.isEmpty ? mod.l10n.prediction : open.title),
          subtitle: Text(
            [
              mod.l10n.outcomeCount(open.outcomes.length),
              if (open.isLocked) mod.l10n.locked,
            ].join(' · '),
          ),
          trailing: anyBusy
              ? const ModSpinner()
              : Wrap(
                  spacing: 8,
                  children: [
                    if (!open.isLocked)
                      OutlinedButton(
                        onPressed: () => _end(
                          open,
                          'LOCKED',
                          done: mod.l10n.predictionLocked,
                        ),
                        child: Text(mod.l10n.lock),
                      ),
                    FilledButton(
                      onPressed: () => _resolve(open),
                      child: Text(mod.l10n.resolve),
                    ),
                    TextButton(
                      onPressed: () => _cancel(open),
                      child: Text(mod.l10n.cancel),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

String _outcomeLabel(AppLocalizations l, PredictionOutcome outcome) {
  final detail = [
    if (outcome.channelPoints case final pts?) l.pointsValue(pts),
    if (outcome.users case final users?) l.predictorCount(users),
  ].join(' · ');
  final title = outcome.title.isEmpty ? l.outcome : outcome.title;
  return detail.isEmpty ? title : '$title ($detail)';
}
