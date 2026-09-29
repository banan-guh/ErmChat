import 'dart:async';

import 'package:flutter/material.dart';
import '../../chat/chat.dart';
import '../../chat/channel/points.dart';
import '../../models/point_rewards.dart';
import '../../services/mod_actions.dart';
import '../../services/twitch_auth.dart';
import '../dialogs.dart';
import 'common.dart';

class PointsSection extends StatefulWidget {
  const PointsSection({
    super.key,
    required this.channel,
    required this.chat,
    required this.modActions,
    required this.auth,
    required this.onNotice,
  });

  final String channel;
  final Chat chat;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;

  @override
  State<PointsSection> createState() => _PointsSectionState();
}

class _PointsSectionState extends State<PointsSection>
    with ModTabLoad<PointsSection> {
  @override
  ModActions get modActions => widget.modActions;
  @override
  ValueChanged<String> get onNotice => widget.onNotice;

  List<PointReward>? _rewards;
  String? _error;
  int _loadGen = 0;
  String? _selectedRewardId;
  List<PointRedemption>? _queue;
  String? _queueError;
  int _queueGen = 0;
  final _busyRedemptions = <String>{};
  final _toggling = <String>{};
  Points? _points;

  @override
  void initState() {
    super.initState();
    _subscribePoints();
    _loadRewards();
  }

  void _subscribePoints() {
    _points = widget.chat.channelFor(widget.channel)?.points;
    _points?.rewardsVersion.addListener(_loadRewards);
    _points?.version.addListener(_loadQueue);
  }

  void _unsubscribePoints() {
    _points?.rewardsVersion.removeListener(_loadRewards);
    _points?.version.removeListener(_loadQueue);
    _points = null;
  }

  @override
  void didUpdateWidget(covariant PointsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      _unsubscribePoints();
      _subscribePoints();
      setState(() {
        _rewards = null;
        _error = null;
        _selectedRewardId = null;
        _queue = null;
        _queueError = null;
      });
      _loadRewards();
    }
  }

  @override
  void dispose() {
    _unsubscribePoints();
    super.dispose();
  }

  Future<void> _loadRewards() async {
    final gen = ++_loadGen;
    final outcome = await guardedLoad<List<PointReward>>(
      gen: gen,
      currentGen: () => _loadGen,
      background: _rewards != null,
      request: () =>
          widget.modActions.getPointRewards(widget.auth, widget.channel),
      fallbackError: 'Could not load rewards.',
    );
    if (outcome == null) return;
    setState(() {
      _error = outcome.error;
      if (outcome.error == null) {
        final rewards = outcome.value ?? const <PointReward>[];
        _rewards = rewards;
        if (_selectedRewardId != null &&
            rewards.every((r) => r.id != _selectedRewardId)) {
          _selectedRewardId = null;
          _queue = null;
          _queueError = null;
        }
      }
    });
  }

  Future<void> _loadQueue() async {
    final rewardId = _selectedRewardId;
    if (rewardId == null) return;
    final gen = ++_queueGen;
    final outcome = await guardedLoad<List<PointRedemption>>(
      gen: gen,
      currentGen: () => _queueGen,
      background: _queue != null,
      request: () => widget.modActions.getPointRedemptions(
        widget.auth,
        widget.channel,
        rewardId,
      ),
      fallbackError: 'Could not load redemptions.',
      statusError: (status) => status == 403
          ? 'Redemptions for this reward are only visible '
                'to the app that created it.'
          : null,
    );
    if (outcome == null) return;
    setState(() {
      _queueError = outcome.error;
      if (outcome.error == null) _queue = outcome.value;
    });
  }

  void _select(String rewardId) {
    if (_selectedRewardId == rewardId) return;
    setState(() {
      _selectedRewardId = rewardId;
      _queue = null;
      _queueError = null;
    });
    _loadQueue();
  }

  Future<void> _resolve(PointRedemption redemption, bool fulfilled) async {
    if (!fulfilled) {
      final confirm = await confirmDialog(
        context,
        title: 'Refund redemption?',
        message: 'Refund ${redemption.cost} pts to ${redemption.userLogin}?',
        confirmLabel: 'Refund',
        cancelLabel: 'Back',
        destructive: true,
      );
      if (!confirm || !mounted) return;
    }
    if (!_busyRedemptions.add(redemption.id)) return;
    setState(() {});
    try {
      final result = await widget.modActions.resolveRedemption(
        widget.auth,
        widget.channel,
        redemption.rewardId,
        redemption.id,
        fulfilled,
      );
      if (!mounted) return;
      if (result.ok) {
        widget.onNotice(
          fulfilled ? 'Redemption fulfilled.' : 'Redemption refunded.',
        );
        // A tracked redemption reloads the queue through the points version.
        if (_points?.resolveRedemption(redemption.id) != true) _loadQueue();
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      _busyRedemptions.remove(redemption.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _togglePause(PointReward reward) async {
    if (!_toggling.add(reward.id)) return;
    setState(() {});
    try {
      final result = await widget.modActions.setRewardPaused(
        widget.auth,
        widget.channel,
        reward.id,
        !reward.isPaused,
      );
      if (!mounted) return;
      if (result.ok) {
        widget.onNotice(reward.isPaused ? 'Reward resumed.' : 'Reward paused.');
        _loadRewards();
      } else if (result.status == 403) {
        widget.onNotice('Only rewards created by this app can be paused.');
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      _toggling.remove(reward.id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final rewards = _rewards;
    if (_error != null && rewards == null) {
      return ModError(message: _error!, onRetry: _loadRewards);
    }
    if (rewards == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [CircularProgressIndicator()],
        ),
      );
    }
    if (rewards.isEmpty) {
      return const ListTile(
        title: Text('No custom rewards. Create them in the dashboard.'),
      );
    }
    final selected = _selectedRewardId == null
        ? null
        : rewards.where((r) => r.id == _selectedRewardId).firstOrNull;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Text(
            'Only rewards created by this app are manageable here.',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final reward in rewards)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            selected: reward.id == _selectedRewardId,
            title: Text(reward.title),
            subtitle: Text(
              '${reward.cost} pts · ${reward.isPaused
                  ? 'Paused'
                  : reward.isEnabled
                  ? 'Enabled'
                  : 'Disabled'}',
            ),
            onTap: () => _select(reward.id),
            trailing: _toggling.contains(reward.id)
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    icon: Icon(
                      reward.isPaused ? Icons.play_arrow : Icons.pause,
                    ),
                    tooltip: reward.isPaused ? 'Resume' : 'Pause',
                    onPressed: () => _togglePause(reward),
                  ),
          ),
        if (selected != null) ...[
          ModSectionHeader('Queue: ${selected.title}'),
          _queueBody(selected),
        ],
      ],
    );
  }

  Widget _queueBody(PointReward selected) {
    if (_queueError != null && _queue == null) {
      return ModError(message: _queueError!, onRetry: _loadQueue);
    }
    final queue = _queue;
    if (queue == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [CircularProgressIndicator()],
        ),
      );
    }
    if (queue.isEmpty) {
      return const ListTile(title: Text('Queue is clear.'));
    }
    return Column(
      children: [
        for (final redemption in queue)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            title: Text(redemption.userLogin),
            subtitle: Text(
              [
                '${redemption.cost} pts',
                if (redemption.redeemedAt.isNotEmpty)
                  'redeemed ${modRelativeShortDate(redemption.redeemedAt)}',
                if (redemption.userInput.isNotEmpty)
                  '"${redemption.userInput}"',
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _busyRedemptions.contains(redemption.id)
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _resolve(redemption, true),
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('Fulfill'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _resolve(redemption, false),
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('Refund'),
                      ),
                    ],
                  ),
          ),
      ],
    );
  }
}
