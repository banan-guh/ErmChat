import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../eventsub/decode/events.dart';
import '../l10n/l10n.dart';
import '../services/emote_manager.dart';
import '../services/mod_actions.dart' show ModResult;
import 'emote_text.dart';
import 'glass_chrome.dart';
import 'mod_view/dialogs.dart' show showModError;

/// Fixed cutout for broadcaster widget cards (poll/prediction/hype train).
class ChatWidgetCutout extends StatelessWidget {
  const ChatWidgetCutout({
    super.key,
    required this.pages,
    required this.controller,
    required this.onMinimize,
    this.glass = false,
  });

  static const double height = 150;

  final List<Widget> pages;
  final PageController controller;
  final VoidCallback onMinimize;

  /// Glass layout: the cards float as glass instead of opaque surfaces.
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A tap anywhere collapses the cards to the minimized bar.
    Widget surface(Widget child) => _cardSurface(
      context,
      glass: glass,
      child: InkWell(onTap: onMinimize, child: child),
    );
    final minimize = IconButton(
      icon: const Icon(Icons.keyboard_arrow_down, size: 20),
      tooltip: context.l10n.minimize,
      visualDensity: VisualDensity.compact,
      onPressed: onMinimize,
    );
    // A lone card sizes to its content; only several share the pager.
    if (pages.length == 1) {
      final pin = pages.single is PinnedMessageCard;
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
        child: surface(
          Stack(
            children: [
              pages.single,
              if (pin)
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 2,
                  child: Center(child: minimize),
                )
              else
                Positioned(top: 2, right: 2, child: minimize),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: SizedBox(
        height: height,
        child: surface(
          Stack(
            children: [
              PageView.builder(
                controller: controller,
                itemCount: pages.length,
                itemBuilder: (context, index) => pages[index],
              ),
              Positioned(top: 2, right: 2, child: minimize),
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

/// The cards' backing: glass in the glass layout, else an opaque rounded
/// surface with Twitch's thin outline.
Widget _cardSurface(
  BuildContext context, {
  required bool glass,
  required Widget child,
}) {
  final theme = Theme.of(context);
  if (glass) {
    return glassCard(
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
  return Material(
    // The top bar's color, so the cards read as part of the chrome.
    color: theme.colorScheme.surfaceContainer,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: theme.colorScheme.outlineVariant),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

/// Collapsed cutout: one row with the pin's message, or the active widget
/// labels, and a restore button. A tap anywhere restores.
class ChatWidgetMinimizedBar extends StatelessWidget {
  const ChatWidgetMinimizedBar({
    super.key,
    required this.labels,
    required this.onRestore,
    this.pin,
    this.emotes,
    this.glass = false,
  });

  final bool glass;

  static const double height = 40;

  final String Function(AppLocalizations) labels;
  final VoidCallback onRestore;
  final PinnedMessageEvent? pin;
  final EmoteLookupSource? emotes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: SizedBox(
        height: height,
        child: _cardSurface(
          context,
          glass: glass,
          child: InkWell(
            onTap: onRestore,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(
                  pin == null
                      ? Icons.insights_outlined
                      : Icons.push_pin_outlined,
                  size: 16,
                  color: pin == null
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: switch (pin) {
                    final pin? => Text.rich(
                      TextSpan(children: pinnedMessageSpans(pin, emotes)),
                      style: theme.textTheme.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    null => Text(
                      labels(context.l10n),
                      style: theme.textTheme.labelMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  },
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
      ),
    );
  }
}

/// Hype train progress card with a live countdown.
/// Progress toward the next level, 0 to 1.
double hypeTrainRatio(HypeTrainEvent e) =>
    e.goal > 0 ? (e.progress / e.goal).clamp(0.0, 1.0) : 0.0;

/// Rounded down, so 100 only shows once the level is full.
int hypeTrainPercent(HypeTrainEvent e) => (hypeTrainRatio(e) * 100).floor();

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
    final ratio = hypeTrainRatio(e);
    final top = e.topContributions
        .take(2)
        .map(
          (c) => c.type == 'BITS'
              ? l10n.hypeContributionBits(c.userName)
              : l10n.hypeContributionSubs(c.userName),
        )
        .join(', ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 44, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.hypeTrainProgress(e.progress, e.goal),
                  style: theme.textTheme.labelSmall,
                ),
              ),
              Text(
                '${hypeTrainPercent(e)}%',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
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

/// The expanded pin's overflow menu: Unpin for mods, and hide it for this
/// user only.
class _PinMenu extends StatelessWidget {
  const _PinMenu({required this.onHide, this.onUnpin});

  final VoidCallback onHide;
  final Future<ModResult> Function()? onUnpin;

  @override
  Widget build(BuildContext context) => PopupMenuButton<void>(
    icon: const Icon(Icons.more_vert, size: 18),
    padding: EdgeInsets.zero,
    style: IconButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    itemBuilder: (menuContext) => [
      if (onUnpin case final unpin?)
        PopupMenuItem(
          onTap: () async {
            final result = await unpin();
            if (context.mounted) showModError(context, result);
          },
          child: Text(context.l10n.unpinMessage),
        ),
      PopupMenuItem(
        onTap: onHide,
        child: Text(context.l10n.pinHideForYourself),
      ),
    ],
  );
}

/// "sender: message" with emotes, shared by the pin card and the bar.
List<InlineSpan> pinnedMessageSpans(
  PinnedMessageEvent event,
  EmoteLookupSource? emotes,
) => [
  if (event.senderName.isNotEmpty)
    TextSpan(
      text: '${event.senderName}: ',
      style: const TextStyle(fontWeight: FontWeight.w600),
    ),
  if (emotes == null)
    TextSpan(text: event.text)
  else
    ...EmoteText.build(
      text: event.text,
      twitchPositions: event.emotes,
      channelEmotes: emotes.lookup(event.channel, event.senderId),
      emoteImages: emotes.images,
    ),
];

/// The channel's pinned chat message, in full: Twitch's muted "Pinned by"
/// line over "sender: message".
class PinnedMessageCard extends StatelessWidget {
  const PinnedMessageCard({
    super.key,
    required this.event,
    this.emotes,
    this.onDismiss,
    this.onUnpin,
  });

  final PinnedMessageEvent event;
  final EmoteLookupSource? emotes;

  /// Hides this pin on this device.
  final VoidCallback? onDismiss;

  /// Unpins for everyone; null unless the user moderates the channel.
  final Future<ModResult> Function()? onUnpin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    // Sized to the text on its own; scrolls inside the fixed-height pager.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 8, 44, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.push_pin_outlined, size: 14, color: muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  event.pinnedBy.isEmpty
                      ? context.l10n.pinned
                      : context.l10n.pinnedBy(event.pinnedBy),
                  style: theme.textTheme.labelMedium?.copyWith(color: muted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onDismiss != null)
                _PinMenu(onHide: onDismiss!, onUnpin: onUnpin),
            ],
          ),
          const SizedBox(height: 2),
          Text.rich(
            TextSpan(children: pinnedMessageSpans(event, emotes)),
            style: theme.textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

/// Title row shared by the poll and prediction cards.
Widget _resultsHeader(BuildContext context, String label, String title) {
  final theme = Theme.of(context);
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text(label, style: theme.textTheme.titleSmall),
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
        title,
        style: theme.textTheme.labelMedium,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      const SizedBox(height: 6),
    ],
  );
}

/// One result: the option's share fills the row behind its title, with
/// [trailing] stats and the percent on the right.
class _ResultBar extends StatelessWidget {
  const _ResultBar({
    required this.title,
    required this.share,
    required this.color,
    this.bold = false,
    this.trailing,
  });

  final String title;

  /// 0 to 1.
  final double share;
  final Color color;
  final bool bold;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(
      fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          height: 24,
          child: Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                ),
              ),
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: share.clamp(0.0, 1.0),
                  child: ColoredBox(color: color.withValues(alpha: 0.35)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: style,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (trailing != null) ...[
                      trailing!,
                      const SizedBox(width: 8),
                    ],
                    Text('${(share * 100).round()}%', style: style),
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

/// Read-only poll results card.
class PollCard extends StatelessWidget {
  const PollCard({super.key, required this.event});

  final PollEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = event.choices.fold<int>(0, (sum, c) => sum + c.votes);
    final lead = event.choices.fold<int>(
      0,
      (m, c) => c.votes > m ? c.votes : m,
    );
    final votes = NumberFormat.compact();
    final shown = event.choices.take(2).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 44, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _resultsHeader(context, context.l10n.poll, event.title),
          for (final choice in shown)
            _ResultBar(
              title: choice.title,
              share: total > 0 ? choice.votes / total : 0,
              // The leader stands out; ties all lead.
              color: lead > 0 && choice.votes == lead
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
              bold: lead > 0 && choice.votes == lead,
              trailing: Text(
                votes.format(choice.votes),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
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

/// Twitch's prediction colors: blue, pink, then the rest of its palette.
const _outcomeColors = [
  Color(0xFF387AFF),
  Color(0xFFF5009B),
  Color(0xFF00C7AC),
  Color(0xFFE0A800),
  Color(0xFF9147FF),
];

/// Read-only prediction results card.
class PredictionCard extends StatelessWidget {
  const PredictionCard({super.key, required this.event});

  final PredictionEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = event.outcomes.fold<int>(0, (s, o) => s + o.channelPoints);
    final compact = NumberFormat.compact();
    final stat = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final shown = event.outcomes.take(2).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 44, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _resultsHeader(context, context.l10n.prediction, event.title),
          for (final (i, outcome) in shown.indexed)
            _ResultBar(
              title: outcome.title,
              share: total > 0 ? outcome.channelPoints / total : 0,
              color: _outcomeColors[i % _outcomeColors.length],
              bold: true,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.people_outline, size: 12, color: stat?.color),
                  const SizedBox(width: 2),
                  Text(compact.format(outcome.users), style: stat),
                  const SizedBox(width: 6),
                  Icon(Icons.toll_outlined, size: 12, color: stat?.color),
                  const SizedBox(width: 2),
                  Text(compact.format(outcome.channelPoints), style: stat),
                ],
              ),
            ),
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
