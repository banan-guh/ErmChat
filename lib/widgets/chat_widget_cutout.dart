import 'dart:async';
import 'package:flutter/material.dart';
import '../eventsub/decode/events.dart';
import '../l10n/l10n.dart';

/// Fixed cutout for broadcaster widget cards (poll/prediction/hype train).
class ChatWidgetCutout extends StatelessWidget {
  const ChatWidgetCutout({
    super.key,
    required this.pages,
    required this.controller,
    required this.onMinimize,
  });

  static const double height = 150;

  final List<Widget> pages;
  final PageController controller;
  final VoidCallback onMinimize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: SizedBox(
        height: height,
        child: Material(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.hardEdge,
          child: Stack(
            children: [
              PageView.builder(
                controller: controller,
                itemCount: pages.length,
                itemBuilder: (context, index) => pages[index],
              ),
              Positioned(
                top: 2,
                right: 2,
                child: IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                  tooltip: context.l10n.minimize,
                  visualDensity: VisualDensity.compact,
                  onPressed: onMinimize,
                ),
              ),
              if (pages.length > 1)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 4,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < pages.length; i++)
                        AnimatedBuilder(
                          animation: controller,
                          builder: (context, _) {
                            final active = (controller.page ?? 0).round() == i;
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: active ? 14 : 6,
                              height: 6,
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              decoration: BoxDecoration(
                                color: active
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.outlineVariant,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Collapsed cutout: slim row with active widget labels and restore button.
class ChatWidgetMinimizedBar extends StatelessWidget {
  const ChatWidgetMinimizedBar({
    super.key,
    required this.labels,
    required this.onRestore,
  });

  static const double height = 36;

  final String Function(AppLocalizations) labels;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: SizedBox(
        height: height,
        child: Material(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.hardEdge,
          child: Row(
            children: [
              const SizedBox(width: 12),
              Icon(
                Icons.insights_outlined,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  labels(context.l10n),
                  style: theme.textTheme.labelMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                tooltip: context.l10n.restore,
                visualDensity: VisualDensity.compact,
                onPressed: onRestore,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hype train progress card with a live countdown.
class HypeTrainCard extends StatefulWidget {
  const HypeTrainCard({super.key, required this.event});

  final HypeTrainEvent event;

  @override
  State<HypeTrainCard> createState() => _HypeTrainCardState();
}

class _HypeTrainCardState extends State<HypeTrainCard> {
  Timer? _timer;
  final _remainingNotifier = ValueNotifier<String>('');

  @override
  void initState() {
    super.initState();
    _updateRemaining();
    if (widget.event.expiresAt != null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        _updateRemaining();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _remainingNotifier.dispose();
    super.dispose();
  }

  void _updateRemaining() {
    final expiresAt = widget.event.expiresAt;
    if (expiresAt == null) {
      _remainingNotifier.value = '';
      return;
    }
    final d = expiresAt.difference(DateTime.now());
    if (d.isNegative) {
      _timer?.cancel();
      _remainingNotifier.value = '0:00';
      return;
    }
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    _remainingNotifier.value = '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final e = widget.event;
    final ratio = e.goal > 0 ? (e.progress / e.goal).clamp(0.0, 1.0) : 0.0;
    final top = e.topContributions
        .take(2)
        .map(
          (c) => c.type == 'BITS'
              ? l10n.hypeContributionBits(c.userName)
              : l10n.hypeContributionSubs(c.userName),
        )
        .join(', ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 44, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(l10n.hypeTrain, style: theme.textTheme.titleSmall),
              const SizedBox(width: 8),
              Text(
                l10n.hypeTrainLevel(e.level),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              ValueListenableBuilder<String>(
                valueListenable: _remainingNotifier,
                builder: (_, value, _) =>
                    Text(value, style: theme.textTheme.labelSmall),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: ratio, minHeight: 8),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.hypeTrainProgress(e.progress, e.goal),
            style: theme.textTheme.labelSmall,
          ),
          if (top.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              l10n.hypeTrainTop(top),
              style: theme.textTheme.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// The channel's pinned chat message.
class PinnedMessageCard extends StatelessWidget {
  const PinnedMessageCard({super.key, required this.event});

  final PinnedMessageEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 44, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.push_pin, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text(context.l10n.pinned, style: theme.textTheme.titleSmall),
              if (event.pinnedBy.isNotEmpty) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    context.l10n.pinnedBy(event.pinnedBy),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              children: [
                if (event.senderName.isNotEmpty)
                  TextSpan(
                    text: '${event.senderName}: ',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                TextSpan(text: event.text),
              ],
            ),
            style: theme.textTheme.bodySmall,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// Read-only poll results card.
class PollCard extends StatelessWidget {
  const PollCard({super.key, required this.event});

  final PollEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = event.choices.fold<int>(0, (sum, c) => sum + c.votes);
    final shown = event.choices.take(2).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 44, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(context.l10n.poll, style: theme.textTheme.titleSmall),
              const SizedBox(width: 8),
              Text(
                context.l10n.readOnly,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            event.title,
            style: theme.textTheme.labelMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          for (final choice in shown) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    choice.title,
                    style: theme.textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 90,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: total > 0 ? choice.votes / total : 0,
                      minHeight: 6,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 34,
                  child: Text(
                    '${total > 0 ? (choice.votes / total * 100).round() : 0}%',
                    style: theme.textTheme.labelSmall,
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
          ],
          if (event.choices.length > 2)
            Text(
              context.l10n.moreOptions(event.choices.length - 2),
              style: theme.textTheme.labelSmall,
            ),
        ],
      ),
    );
  }
}

/// Read-only prediction results card.
class PredictionCard extends StatelessWidget {
  const PredictionCard({super.key, required this.event});

  final PredictionEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = event.outcomes.take(2).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 44, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(context.l10n.prediction, style: theme.textTheme.titleSmall),
              const SizedBox(width: 8),
              Text(
                context.l10n.readOnly,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            event.title,
            style: theme.textTheme.labelMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          for (final outcome in shown) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    outcome.title,
                    style: theme.textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  context.l10n.predictionUsersPoints(
                    outcome.users,
                    outcome.channelPoints,
                  ),
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 3),
          ],
          if (event.outcomes.length > 2)
            Text(
              context.l10n.moreOutcomes(event.outcomes.length - 2),
              style: theme.textTheme.labelSmall,
            ),
        ],
      ),
    );
  }
}
