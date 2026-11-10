import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../color_utils.dart';
import '../eventsub/decode/events.dart';
import '../l10n/l10n.dart';
import '../services/emote_manager.dart';
import '../services/mod_actions.dart' show ModResult;
import 'chrome_menu_button.dart';
import 'design_tokens.dart';
import 'emote_text.dart';
import 'mod_view/dialogs.dart' show showModError;
import 'painted_username_text.dart';
import 'seven_tv_paint_service.dart';
import 'tabbed_layout.dart';

// Chat widget cards (hype train, pin, poll, prediction), drawn inside the
// cutout in chat_widget_cutout.dart.

// The cards' controls sit in their top-right corner, inset
// [TabbedLayout.cardInset], in one row of small buttons: the header row.
const double _inset = TabbedLayout.cardInset;
const double _controlSize = kChromeMenuSize;

/// Card edge to the collapse control.
const double _controlRight = _inset;

/// Card edge to the left end of the controls, which header text stops at.
const double _controlsWidth = _controlRight + _controlSize;

final _controlStyle = IconButton.styleFrom(
  fixedSize: const Size.square(_controlSize),
  minimumSize: Size.zero,
  padding: EdgeInsets.zero,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// A card's top row, level with the trigger. [actions] sit just left of the
/// collapse control, which the cutout draws; [right] is the card's own
/// right padding, already clear.
Widget _cardHeader({
  required Widget child,
  List<Widget> actions = const [],
  required double right,
}) => SizedBox(
  height: _controlSize,
  child: Row(
    children: [
      Expanded(child: child),
      ...actions,
      SizedBox(width: _controlsWidth - right),
    ],
  ),
);

/// Progress toward the next level, 0 to 1.
double hypeTrainRatio(HypeTrainEvent e) =>
    e.goal > 0 ? (e.progress / e.goal).clamp(0.0, 1.0) : 0.0;

/// Rounded down, so 100 only shows once the level is full.
int hypeTrainPercent(HypeTrainEvent e) => (hypeTrainRatio(e) * 100).floor();

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
    _arm();
  }

  @override
  void didUpdateWidget(HypeTrainCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.expiresAt != widget.event.expiresAt) _arm();
  }

  /// Restarts the countdown for the current expiry.
  void _arm() {
    _timer?.cancel();
    _timer = null;
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
      padding: const EdgeInsets.fromLTRB(14, _inset, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardHeader(
            right: 12,
            child: Row(
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
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.small),
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
    style: _controlStyle,
    popUpAnimationStyle: const AnimationStyle(duration: Motion.fast),
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

/// "sender: message" with emotes and the sender's 7TV paint, shared by the
/// pin card and the bar. Rebuilds when the sender's paint lands.
class PinnedMessageText extends StatelessWidget {
  const PinnedMessageText({
    super.key,
    required this.event,
    this.emotes,
    this.paints,
    this.style,
    this.maxLines,
  });

  final PinnedMessageEvent event;
  final EmoteLookupSource? emotes;
  final SevenTvPaintService? paints;
  final TextStyle? style;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final service = paints;
    if (service == null || event.senderId.isEmpty) return _text(context, null);
    return ValueListenableBuilder<SevenTvPaint?>(
      valueListenable: service.lookupNotifier(event.senderId),
      builder: (context, paint, _) =>
          _text(context, paint ?? service.lookup(event.senderId)),
    );
  }

  Widget _text(BuildContext context, SevenTvPaint? paint) => Text.rich(
    TextSpan(children: _spans(context, paint)),
    style: style,
    maxLines: maxLines,
    overflow: maxLines == null ? null : TextOverflow.ellipsis,
  );

  List<InlineSpan> _spans(BuildContext context, SevenTvPaint? paint) {
    final color = parseColor(
      event.senderColor,
      background: Theme.of(context).colorScheme.surface,
    );
    final nameStyle = TextStyle(fontWeight: FontWeight.w600, color: color);
    final layered = paint != null && paint.layers.isNotEmpty;
    return [
      if (event.senderName.isNotEmpty) ...[
        if (layered && paint.solidColor == null)
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: PaintedUsernameText(
              service: paints!,
              paint: paint,
              text: event.senderName,
              baseStyle: (style ?? const TextStyle()).merge(nameStyle),
              fallbackColor:
                  paint.fallbackColor ?? color ?? const Color(0xFF808080),
            ),
          )
        else
          TextSpan(
            text: event.senderName,
            style: nameStyle.copyWith(
              color: layered ? paint.solidColor : color,
            ),
          ),
        TextSpan(text: ': ', style: nameStyle),
      ],
      ..._body(),
    ];
  }

  List<InlineSpan> _body() {
    final source = emotes;
    if (source == null) return [TextSpan(text: event.text)];
    return EmoteText.build(
      text: event.text,
      twitchPositions: event.emotes,
      channelEmotes: source.lookup(event.channel, event.senderId),
      emoteImages: source.images,
    );
  }
}

/// The channel's pinned chat message, in full: Twitch's muted "Pinned by"
/// line over "sender: message".
class PinnedMessageCard extends StatelessWidget {
  const PinnedMessageCard({
    super.key,
    required this.event,
    this.emotes,
    this.paints,
    this.onDismiss,
    this.onUnpin,
  });

  final PinnedMessageEvent event;
  final EmoteLookupSource? emotes;

  /// Paints the sender's name; null leaves it plain.
  final SevenTvPaintService? paints;

  /// Hides this pin on this device.
  final VoidCallback? onDismiss;

  /// Unpins for everyone; null unless the user moderates the channel.
  final Future<ModResult> Function()? onUnpin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, _inset, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardHeader(
            right: 12,
            actions: [
              if (onDismiss != null)
                _PinMenu(onHide: onDismiss!, onUnpin: onUnpin),
            ],
            child: Row(
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
              ],
            ),
          ),
          PinnedMessageText(
            event: event,
            emotes: emotes,
            paints: paints,
            style: theme.textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

/// Label row and title shared by the poll and prediction cards.
Widget _resultsHeader(BuildContext context, String label, String title) {
  final theme = Theme.of(context);
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _cardHeader(
        right: 12,
        child: Text(label, style: theme.textTheme.titleSmall),
      ),
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
        borderRadius: BorderRadius.circular(Radii.small),
        child: SizedBox(
          height: 24,
          child: Stack(
            alignment: AlignmentDirectional.centerStart,
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, _inset, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _resultsHeader(context, context.l10n.poll, event.title),
          for (final choice in event.choices)
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, _inset, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _resultsHeader(context, context.l10n.prediction, event.title),
          for (final (i, outcome) in event.outcomes.indexed)
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
        ],
      ),
    );
  }
}
