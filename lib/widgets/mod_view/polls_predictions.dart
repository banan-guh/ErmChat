import 'dart:async';

import 'package:flutter/material.dart';
import '../../services/mod_actions.dart';
import '../../services/twitch_auth.dart';
import '../dialogs.dart';
import 'common.dart';

class PollsSection extends StatefulWidget {
  const PollsSection({
    super.key,
    required this.channel,
    required this.modActions,
    required this.auth,
    required this.onNotice,
  });

  final String channel;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;

  @override
  State<PollsSection> createState() => _PollsSectionState();
}

class _PollsSectionState extends State<PollsSection>
    with ModTabLoad<PollsSection> {
  @override
  ModActions get modActions => widget.modActions;
  @override
  ValueChanged<String> get onNotice => widget.onNotice;

  List<Map<String, dynamic>>? _polls;
  String? _error;
  int _loadGen = 0;
  String? _busyKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PollsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      setState(() {
        _polls = null;
        _error = null;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    final outcome = await guardedLoad<List<Map<String, dynamic>>>(
      gen: gen,
      currentGen: () => _loadGen,
      background: _polls != null,
      request: () => widget.modActions.getPolls(widget.auth, widget.channel),
      fallbackError: 'Could not load polls.',
    );
    if (outcome == null) return;
    setState(() {
      _error = outcome.error;
      if (outcome.error == null) _polls = outcome.value;
    });
  }

  Future<void> _end(String pollId, bool archive) async {
    final key = archive ? 'cancel' : 'end';
    if (_busyKey != null) return;
    final confirm = await confirmDialog(
      context,
      title: archive ? 'Cancel poll?' : 'End poll now?',
      message: archive
          ? 'This archives the poll without showing results.'
          : 'This ends the poll and shows the results (TERMINATED).',
      confirmLabel: archive ? 'Cancel poll' : 'End poll',
      cancelLabel: 'Back',
      destructive: true,
    );
    if (!confirm || !mounted) return;
    if (pollId.isEmpty) {
      widget.onNotice('Poll id is missing; reload and try again.');
      return;
    }
    setState(() => _busyKey = key);
    try {
      final result = await widget.modActions.endPoll(
        widget.auth,
        widget.channel,
        pollId: pollId,
        archive: archive,
      );
      if (!mounted) return;
      if (result.ok) {
        widget.onNotice(archive ? 'Poll cancelled.' : 'Poll ended.');
        _load();
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final polls = _polls;
    if (_error != null && polls == null) {
      return ModError(message: _error!, onRetry: _load);
    }
    if (polls == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [CircularProgressIndicator()],
        ),
      );
    }
    Map<String, dynamic>? active;
    for (final poll in polls) {
      if (poll['status'] == 'ACTIVE') {
        active = poll;
        break;
      }
    }
    if (active == null) {
      return _PollCreateForm(
        channel: widget.channel,
        modActions: widget.modActions,
        auth: widget.auth,
        onNotice: widget.onNotice,
        onCreated: _load,
      );
    }
    final pollId = active['id'] as String? ?? '';
    final busy = _busyKey != null;
    final choices = (active['choices'] as List? ?? const []).cast<Map>();
    var totalVotes = 0;
    for (final c in choices) {
      totalVotes += (c['votes'] as num?)?.toInt() ?? 0;
    }
    final endsAt = active['ends_at'] as String?;
    final ends = endsAt == null || endsAt.isEmpty
        ? null
        : modRelativeShortDate(endsAt);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Text(active['title'] as String? ?? 'Poll'),
      subtitle: Text(
        [
          '${choices.length} choices',
          '$totalVotes votes',
          if (ends != null) 'ends $ends',
        ].join(' · '),
      ),
      trailing: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busyKey != null
                      ? null
                      : () => _end(pollId, false),
                  child: const Text('End'),
                ),
                TextButton(
                  onPressed: _busyKey != null ? null : () => _end(pollId, true),
                  child: const Text('Archive'),
                ),
              ],
            ),
    );
  }
}

class _PollCreateForm extends StatefulWidget {
  const _PollCreateForm({
    required this.channel,
    required this.modActions,
    required this.auth,
    required this.onNotice,
    required this.onCreated,
  });

  final String channel;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;
  final VoidCallback onCreated;

  @override
  State<_PollCreateForm> createState() => _PollCreateFormState();
}

class _PollCreateFormState extends State<_PollCreateForm> {
  final _titleCtrl = TextEditingController();
  final _choiceCtrls = [TextEditingController(), TextEditingController()];
  int _duration = 60;
  bool _creating = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    for (final c in _choiceCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _create() async {
    final title = _titleCtrl.text.trim();
    final choices = [
      for (final c in _choiceCtrls) c.text.trim(),
    ].where((c) => c.isNotEmpty).toList();
    if (title.isEmpty || choices.length < 2) {
      widget.onNotice('Enter a title and at least 2 choices.');
      return;
    }
    if (_creating) return;
    setState(() => _creating = true);
    try {
      final result = await widget.modActions.createPoll(
        widget.auth,
        widget.channel,
        title: title,
        choices: choices,
        durationSeconds: _duration,
      );
      if (!mounted) return;
      if (result.ok) {
        widget.onNotice('Poll started.');
        widget.onCreated();
      } else {
        widget.onNotice(modErrorText(result));
      }
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
            controller: _titleCtrl,
            decoration: const InputDecoration(labelText: 'Poll title'),
          ),
          for (var i = 0; i < _choiceCtrls.length; i++)
            TextField(
              controller: _choiceCtrls[i],
              decoration: InputDecoration(labelText: 'Choice ${i + 1}'),
            ),
          Row(
            children: [
              const Text('Duration:'),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _duration,
                items: const [
                  DropdownMenuItem(value: 15, child: Text('15s')),
                  DropdownMenuItem(value: 60, child: Text('1m')),
                  DropdownMenuItem(value: 120, child: Text('2m')),
                  DropdownMenuItem(value: 300, child: Text('5m')),
                  DropdownMenuItem(value: 600, child: Text('10m')),
                  DropdownMenuItem(value: 1800, child: Text('30m')),
                ],
                onChanged: _creating
                    ? null
                    : (v) => setState(() => _duration = v ?? 60),
              ),
              const Spacer(),
              if (_choiceCtrls.length < 5)
                TextButton(
                  onPressed: _creating
                      ? null
                      : () => setState(
                          () => _choiceCtrls.add(TextEditingController()),
                        ),
                  child: const Text('Add choice'),
                ),
            ],
          ),
          FilledButton(
            onPressed: _creating ? null : _create,
            child: _creating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Start poll'),
          ),
        ],
      ),
    );
  }
}

class PredictionsSection extends StatefulWidget {
  const PredictionsSection({
    super.key,
    required this.channel,
    required this.modActions,
    required this.auth,
    required this.onNotice,
  });

  final String channel;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;

  @override
  State<PredictionsSection> createState() => _PredictionsSectionState();
}

class _PredictionsSectionState extends State<PredictionsSection>
    with ModTabLoad<PredictionsSection> {
  @override
  ModActions get modActions => widget.modActions;
  @override
  ValueChanged<String> get onNotice => widget.onNotice;

  List<Map<String, dynamic>>? _predictions;
  String? _error;
  int _loadGen = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PredictionsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      setState(() {
        _predictions = null;
        _error = null;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    final outcome = await guardedLoad<List<Map<String, dynamic>>>(
      gen: gen,
      currentGen: () => _loadGen,
      background: _predictions != null,
      request: () =>
          widget.modActions.getPredictions(widget.auth, widget.channel),
      fallbackError: 'Could not load predictions.',
    );
    if (outcome == null) return;
    setState(() {
      _error = outcome.error;
      if (outcome.error == null) _predictions = outcome.value;
    });
  }

  Future<void> _end(
    String predictionId,
    String status, [
    String? winningOutcomeId,
  ]) async {
    if (_busy) return;
    if (status == 'CANCELED') {
      final confirm = await confirmDialog(
        context,
        title: 'Cancel prediction?',
        message: 'Points are refunded to predictors.',
        confirmLabel: 'Cancel prediction',
        cancelLabel: 'Back',
        destructive: true,
      );
      if (!confirm || !mounted) return;
    }
    if (predictionId.isEmpty) {
      widget.onNotice('Prediction id is missing; reload and try again.');
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await widget.modActions.endPrediction(
        widget.auth,
        widget.channel,
        predictionId: predictionId,
        status: status,
        winningOutcomeId: winningOutcomeId,
      );
      if (!mounted) return;
      if (result.ok) {
        widget.onNotice(
          status == 'LOCKED'
              ? 'Prediction locked.'
              : status == 'CANCELED'
              ? 'Prediction cancelled.'
              : 'Prediction resolved.',
        );
        _load();
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _outcomeLabel(Map outcome) {
    final title = '${outcome['title'] ?? 'Outcome'}';
    final points = outcome['channel_points'];
    final users = outcome['users'];
    final detail = [
      if (points != null) '$points pts',
      if (users != null) '$users predictors',
    ].join(' · ');
    return detail.isEmpty ? title : '$title ($detail)';
  }

  Future<void> _resolve(Map<String, dynamic> prediction) async {
    final outcomes = (prediction['outcomes'] as List? ?? const []).cast<Map>();
    final winningId = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Winning outcome'),
        children: [
          for (final outcome in outcomes)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, outcome['id'] as String?),
              child: Text(_outcomeLabel(outcome)),
            ),
        ],
      ),
    );
    if (winningId == null || winningId.isEmpty || !mounted) return;
    await _end(prediction['id'] as String? ?? '', 'RESOLVED', winningId);
  }

  @override
  Widget build(BuildContext context) {
    final predictions = _predictions;
    if (_error != null && predictions == null) {
      return ModError(message: _error!, onRetry: _load);
    }
    if (predictions == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [CircularProgressIndicator()],
        ),
      );
    }
    Map<String, dynamic>? open;
    for (final prediction in predictions) {
      if (prediction['status'] == 'ACTIVE' ||
          prediction['status'] == 'LOCKED') {
        open = prediction;
        break;
      }
    }
    if (open == null) {
      return const ListTile(
        title: Text('No open prediction. Create one with /prediction.'),
      );
    }
    final predictionId = open['id'] as String? ?? '';
    final locked = open['status'] == 'LOCKED';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Text(open['title'] as String? ?? 'Prediction'),
      subtitle: Text(
        '${(open['outcomes'] as List? ?? const []).length} outcomes'
        '${locked ? ' · locked' : ''}',
      ),
      trailing: _busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Wrap(
              spacing: 8,
              children: [
                if (!locked)
                  OutlinedButton(
                    onPressed: () => _end(predictionId, 'LOCKED'),
                    child: const Text('Lock'),
                  ),
                FilledButton(
                  onPressed: () => _resolve(open!),
                  child: const Text('Resolve'),
                ),
                TextButton(
                  onPressed: () => _end(predictionId, 'CANCELED'),
                  child: const Text('Cancel'),
                ),
              ],
            ),
    );
  }
}
