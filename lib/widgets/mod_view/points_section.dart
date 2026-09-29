import 'package:flutter/material.dart';

import '../../models/point_rewards.dart';
import '../../util/date_format.dart';
import '../dialogs.dart';
import 'dialogs.dart';
import 'scope.dart';
import 'widgets.dart';

/// Custom rewards with pause toggles, plus the selected reward's queue.
class PointsSection extends ModTabWidget {
  const PointsSection({super.key, required super.mod});

  @override
  State<PointsSection> createState() => _PointsSectionState();
}

class _PointsSectionState extends State<PointsSection>
    with ModTabState<PointsSection> {
  late final ModLoader<List<PointReward>> _rewards;
  late final ModLoader<List<PointRedemption>> _queue;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _rewards = loader(
      (mod) => mod.actions.getPointRewards(mod.auth, mod.channel),
      failure: 'Could not load rewards.',
    )..addListener(_dropMissingSelection);
    _queue = loader(
      (mod) async {
        final rewardId = _selected;
        if (rewardId == null) return const <PointRedemption>[];
        return mod.actions.getPointRedemptions(mod.auth, mod.channel, rewardId);
      },
      failure: 'Could not load redemptions.',
      statusFailure: (status) => status == 403
          ? 'Redemptions for this reward are only visible '
                'to the app that created it.'
          : null,
    );
    // Reward edits reload the list; any redemption event reloads the queue.
    watch((mod) => mod.points?.rewardsVersion, _rewards.load);
    watch((mod) => mod.points?.version, () {
      if (_selected != null) _queue.load();
    });
  }

  @override
  void didChangeChannel() => _selected = null;

  void _dropMissingSelection() {
    final rewards = _rewards.value;
    if (rewards == null || _selected == null) return;
    if (rewards.any((r) => r.id == _selected)) return;
    setState(() => _selected = null);
  }

  void _select(String rewardId) {
    if (_selected == rewardId) return;
    setState(() => _selected = rewardId);
    _queue.reset();
  }

  Future<void> _togglePause(PointReward reward) => busy(reward.id, () async {
    final result = await mod.actions.setRewardPaused(
      mod.auth,
      mod.channel,
      reward.id,
      !reward.isPaused,
    );
    if (result.ok) {
      mod.notify(reward.isPaused ? 'Reward resumed.' : 'Reward paused.');
      await _rewards.load();
    } else {
      mod.notify(
        result.status == 403
            ? 'Only rewards created by this app can be paused.'
            : modErrorText(result),
      );
    }
  });

  Future<void> _resolve(PointRedemption redemption, bool fulfilled) async {
    if (!fulfilled) {
      final confirmed = await confirmDialog(
        context,
        title: 'Refund redemption?',
        message: 'Refund ${redemption.cost} pts to ${redemption.userLogin}?',
        confirmLabel: 'Refund',
        cancelLabel: 'Back',
        destructive: true,
      );
      if (!confirmed || !mounted) return;
    }
    await busy(redemption.id, () async {
      final ok = await mod.report(
        mod.actions.resolveRedemption(
          mod.auth,
          mod.channel,
          redemption.rewardId,
          redemption.id,
          fulfilled,
        ),
        done: fulfilled ? 'Redemption fulfilled.' : 'Redemption refunded.',
      );
      // A tracked redemption reloads the queue through the points version.
      if (ok && mod.points?.resolveRedemption(redemption.id) != true) {
        await _queue.load();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ModLoadView(
      loader: _rewards,
      inline: true,
      isEmpty: (rewards) => rewards.isEmpty,
      empty: const ListTile(
        title: Text('No custom rewards. Create them in the dashboard.'),
      ),
      builder: (context, rewards) {
        final selected = rewards.where((r) => r.id == _selected).firstOrNull;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ModHint(
              'Only rewards created by this app are manageable here.',
              padding: EdgeInsets.symmetric(horizontal: 16),
            ),
            for (final reward in rewards)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                selected: reward.id == _selected,
                title: Text(reward.title),
                subtitle: Text('${reward.cost} pts · ${_rewardState(reward)}'),
                onTap: () => _select(reward.id),
                trailing: isBusy(reward.id)
                    ? const ModSpinner()
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
              ModLoadView(
                loader: _queue,
                inline: true,
                isEmpty: (queue) => queue.isEmpty,
                empty: const ListTile(title: Text('Queue is clear.')),
                builder: (context, queue) => Column(
                  children: [
                    for (final redemption in queue) _redemptionRow(redemption),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _redemptionRow(PointRedemption redemption) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Text(redemption.userLogin),
      subtitle: Text(
        [
          '${redemption.cost} pts',
          if (redemption.redeemedAt.isNotEmpty)
            'redeemed ${formatAgoIso(redemption.redeemedAt)}',
          if (redemption.userInput.isNotEmpty) '"${redemption.userInput}"',
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: isBusy(redemption.id)
          ? const ModSpinner()
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
    );
  }
}

String _rewardState(PointReward reward) => reward.isPaused
    ? 'Paused'
    : reward.isEnabled
    ? 'Enabled'
    : 'Disabled';
