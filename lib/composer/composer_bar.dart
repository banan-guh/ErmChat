import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../panels/mod_panel.dart';
import '../panels/search.dart';
import '../widgets/message_input.dart';
import '../widgets/tabbed_layout.dart' show swipeShown;
import 'composer_controller.dart';
import '../l10n/l10n.dart';

// Single key for measuring the composer (snackbar margin, video sizing).
// Shared by the pill and the in-flow wrapper: keeping it on both lets the
// composer subtree reparent (preserving its FocusNode) when the glass pill
// hands off to the opaque in-flow path. The two are mutually exclusive in
// ChatBody, so the key is never mounted twice.
final inputBarKey = GlobalKey();

// Fallback when the channel is gone; never bumps.
final _emptyVersion = ValueNotifier<int>(0);

// Message input plus connection status row. Bottom padding comes from
// ChatBody, which owns the layout's single inset subscription. The chrome
// shell (island or glass pill) draws the surface, so the bar stays
// transparent and the field drops its own outline.
class ComposerBar extends StatelessWidget {
  const ComposerBar({
    super.key,
    required this.controller,
    required this.selectedTabIndex,
    required this.search,
    required this.mod,
    required this.dragTick,
    this.buttonsInRow = false,
    this.modeRow = false,
  });

  final ComposerController controller;
  final ValueListenable<int> selectedTabIndex;
  final SearchPanels search;
  final ModPanels mod;

  /// The island's button row shows, so room modes may ride it
  /// ([ComposerModeRow]) instead of the status.
  final bool modeRow;

  /// Panel tab drag crossings. The morph tracks 50% through this alone,
  /// without a full HomeScreen rebuild per crossing (main chat's focus
  /// path skips setState the same way); settle still marks dirty.
  final Listenable dragTick;

  /// The chat field's emote and send buttons sit in the island's button row
  /// ([ComposerRowButton]) instead of the field.
  final bool buttonsInRow;

  @override
  Widget build(BuildContext context) {
    final content = ListenableBuilder(
      listenable: _enabledInputs(controller, mod, dragTick),
      builder: (context, _) {
        // Landscape moves the channel status into the hint; portrait keeps
        // it in the row under the input.
        final landscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        // Search borrows the input box: same field, own controllers.
        // Reads the live channel per event so tab flips never leak.
        final searchBorrowed = search.open && search.selectedChannel() != null;
        // Terms borrows the input box while its tab is open; every
        // other mod tab keeps the greyed-out chat box below.
        final termsBorrowed = !searchBorrowed && mod.termsInputActive;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (searchBorrowed)
              MessageInput(
                controller: search.field,
                focusNode: search.focusNode,
                onSend: () {},
                onChanged: (q) {
                  final channel = search.selectedChannel();
                  if (channel != null) search.setQuery(channel, q);
                },
                onSubmitted: (_) => search.focusNode.unfocus(),
                enabled: true,
                hintText: context.l10n.searchHint,
                searchMode: true,
                borderless: true,
                prefixOverride: search.closeButton(),
                // With the side column, the filter moves into it.
                suffixOverride: buttonsInRow ? null : search.filterButton(),
                buttonsInRow: buttonsInRow,
              )
            else if (termsBorrowed)
              MessageInput(
                controller: mod.termsField,
                focusNode: mod.composer.focusNode,
                onSend: mod.submitTerms,
                onSubmitted: (_) => mod.submitTerms(),
                enabled: true,
                hintText: context.l10n.blockTermHint,
                searchMode: true,
                borderless: true,
                // With the side column, add moves into it and the field
                // needs no icon standing in for the emote button.
                prefixOverride: buttonsInRow ? null : mod.termsPrefixSlot(),
                suffixOverride: buttonsInRow ? null : mod.termsSubmitSlot(),
                buttonsInRow: buttonsInRow,
              )
            else
              // The hint carries the channel status, so it follows the
              // selected channel and its status updates.
              _ChannelListener(
                controller: controller,
                selectedTabIndex: selectedTabIndex,
                builder: (context) => MessageInput(
                  controller: controller.messageController,
                  focusNode: controller.focusNode,
                  onSend: controller.send,
                  onSendLongPress: controller.recallLastSent,
                  onTap: controller.onTapClearSuggestions,
                  onEmoteToggle: controller.toggleEmoteMenu,
                  enabled: controller.enabled,
                  hintText: controller.hintText(
                    withStatus: landscape,
                    modesInRow:
                        modeRow &&
                        controller.selectedChannel != null &&
                        modesFitRow(
                          context,
                          controller,
                          controller.selectedChannel!,
                        ),
                  ),
                  inputFormatters: [controller.autocompleteRevert],
                  borderless: true,
                  buttonsInRow: buttonsInRow,
                ),
              ),
          ],
        );
      },
    );
    return content;
  }
}

/// What the field's enabled state and borrowed modes follow.
Listenable _enabledInputs(
  ComposerController controller,
  ModPanels mod,
  Listenable dragTick,
) => Listenable.merge([
  controller.cooldownLabel,
  controller.chatConn.connectionStateNotifier,
  // Auth switches must re-render immediately (anon to user and back), not
  // wait for the next connection-state bump.
  controller.twitchAuth,
  mod.termsAdding,
  dragTick,
]);

/// The chat field's emote button in the island's row, or its send button
/// down the island's side, for layouts where the row stays up while typing.
/// Greys out with the field. While search or block terms borrow the field,
/// the emote button steps aside and the side column holds their action.
class ComposerRowButton extends StatelessWidget {
  const ComposerRowButton.emote({
    super.key,
    required this.controller,
    required this.search,
    required this.mod,
    required this.dragTick,
  }) : send = false;

  const ComposerRowButton.send({
    super.key,
    required this.controller,
    required this.search,
    required this.mod,
    required this.dragTick,
  }) : send = true;

  final ComposerController controller;
  final SearchPanels search;
  final ModPanels mod;
  final Listenable dragTick;
  final bool send;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      _enabledInputs(controller, mod, dragTick),
      controller.focusNode,
    ]),
    builder: (context, _) {
      final searchBorrowed = search.open && search.selectedChannel() != null;
      final termsBorrowed = !searchBorrowed && mod.termsInputActive;
      if (searchBorrowed || termsBorrowed) {
        // The side column holds whatever owns the field: search's filter
        // or block terms' add, in place of send.
        if (!send) return const SizedBox.shrink();
        return Center(
          child: searchBorrowed ? search.filterButton() : mod.termsSubmitSlot(),
        );
      }
      final scheme = Theme.of(context).colorScheme;
      final accent = controller.focusNode.hasFocus
          ? scheme.primary
          : scheme.onSurfaceVariant;
      if (!send) {
        // One of the row's buttons, so it keeps their color through focus.
        return IconButton(
          icon: const Icon(Icons.emoji_emotions_outlined),
          tooltip: context.l10n.pickerEmotes,
          onPressed: controller.toggleEmoteMenu,
        );
      }
      // Send fills its column down the island's side: the whole strip is
      // the target, the icon centered in it.
      final enabled = controller.enabled;
      return Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: enabled ? controller.send : null,
          onLongPress: enabled ? controller.recallLastSent : null,
          // The strip is far larger than a button, so its ink runs at about
          // half the stock strength.
          splashColor: scheme.onSurface.withValues(alpha: 0.06),
          highlightColor: scheme.onSurface.withValues(alpha: 0.04),
          child: Center(
            child: Icon(
              Icons.send,
              color: enabled
                  ? accent
                  : scheme.onSurface.withValues(alpha: 0.38),
            ),
          ),
        ),
      );
    },
  );
}

/// Room modes in the button row's free middle, when the row has room for
/// all of them; otherwise they stay on the status line. Measures the gap
/// for [modesFitRow] either way.
class ComposerModeRow extends StatelessWidget {
  const ComposerModeRow({
    super.key,
    required this.controller,
    required this.selectedTabIndex,
    required this.search,
    required this.mod,
    required this.dragTick,
    required this.swipePage,
  });

  final ComposerController controller;
  final ValueListenable<int> selectedTabIndex;
  final SearchPanels search;
  final ModPanels mod;
  final Listenable dragTick;

  /// See [ComposerStatusRow.swipePage].
  final ValueListenable<double?> swipePage;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final gap = constraints.maxWidth;
      if (gap != controller.modeGap.value) {
        // Layout can't notify listeners mid-frame.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) controller.modeGap.value = gap;
        });
      }
      return ListenableBuilder(
        listenable: _enabledInputs(controller, mod, dragTick),
        builder: (context, _) {
          final searchBorrowed =
              search.open && search.selectedChannel() != null;
          if (searchBorrowed || mod.termsChromeHidden) {
            return const SizedBox.shrink();
          }
          return ListenableBuilder(
            listenable: swipePage,
            builder: (context, _) => _ChannelListener(
              controller: controller,
              selectedTabIndex: selectedTabIndex,
              builder: (context) => _swipeSlide(
                swipeShown(
                  controller.chat.names,
                  swipePage.value,
                  controller.selectedChannel,
                ),
                (channel) => !modesFitRow(context, controller, channel)
                    ? const SizedBox.shrink()
                    : Center(
                        child: Text(
                          controller.chat
                              .channelFor(channel)!
                              .info
                              .modes
                              .join(' · '),
                          style: _statusStyle(context),
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
              ),
            ),
          );
        },
      );
    },
  );
}

/// Padding the mode text keeps from the row's buttons on each side.
const double _modeRowPad = 8;

/// Whether [channel]'s room modes fit the button row's measured gap, so
/// they ride there instead of the status line.
bool modesFitRow(
  BuildContext context,
  ComposerController controller,
  String channel,
) {
  final modes = controller.chat.channelFor(channel)?.info.modes ?? const [];
  if (modes.isEmpty) return false;
  final line = TextPainter(
    text: TextSpan(text: modes.join(' · '), style: _statusStyle(context)),
    textScaler: MediaQuery.textScalerOf(context),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final width = line.width;
  line.dispose();
  return width + 2 * _modeRowPad <= controller.modeGap.value;
}

/// Rebuilds [builder] when the selected channel or its info changes. The
/// channel can change without a parent rebuild (the swipe path skips
/// setState), so the notifiers bind to whatever channel is current.
class _ChannelListener extends StatelessWidget {
  const _ChannelListener({
    required this.controller,
    required this.selectedTabIndex,
    required this.builder,
  });

  final ComposerController controller;
  final ValueListenable<int> selectedTabIndex;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: selectedTabIndex,
    builder: (context, _) {
      final info = controller.chat
          .channelFor(controller.selectedChannel ?? '')
          ?.info;
      return ListenableBuilder(
        listenable: Listenable.merge([
          info?.version ?? _emptyVersion,
          info?.statusVersion ?? _emptyVersion,
          controller.chat.loadFailedChannels,
          controller.modeGap,
        ]),
        builder: (context, _) => builder(context),
      );
    },
  );
}

/// The channel status line at the island's foot, under the button row, so
/// it never splits the field from its buttons. Steps aside while search or
/// block terms borrow the field.
class ComposerStatusRow extends StatelessWidget {
  const ComposerStatusRow({
    super.key,
    required this.controller,
    required this.selectedTabIndex,
    required this.search,
    required this.mod,
    required this.dragTick,
    required this.swipePage,
    this.modeRow = false,
  });

  final ComposerController controller;
  final ValueListenable<int> selectedTabIndex;
  final SearchPanels search;
  final ModPanels mod;
  final Listenable dragTick;

  /// The channel pager's fractional page while it moves; each channel's
  /// status slides with its page.
  final ValueListenable<double?> swipePage;

  /// See [ComposerBar.modeRow].
  final bool modeRow;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _enabledInputs(controller, mod, dragTick),
    builder: (context, _) {
      final searchBorrowed = search.open && search.selectedChannel() != null;
      if (searchBorrowed || mod.termsChromeHidden) {
        return const SizedBox.shrink();
      }
      // Landscape moves the status into the field's hint instead.
      final landscape =
          MediaQuery.orientationOf(context) == Orientation.landscape;
      return _StatusRow(
        controller: controller,
        selectedTabIndex: selectedTabIndex,
        swipePage: swipePage,
        showStatus: !landscape,
        modeRow: modeRow,
      );
    },
  );
}

/// The status line's text style. Explicit (not inherited), so its height can
/// be measured away from the island.
TextStyle _statusStyle(BuildContext context, {Color? color}) {
  final theme = Theme.of(context);
  return (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
    fontSize: 12,
    color: color ?? theme.colorScheme.onSurfaceVariant,
  );
}

/// Height the status row takes for [channel]: its status line (portrait
/// only) and the retry link when its emotes failed. Each chat page adds
/// its own channel's, so a page is already placed for the island it is
/// about to show, and only the island moves on a switch.
double composerStatusHeight(
  BuildContext context,
  ComposerController controller,
  String channel, {
  bool modeRow = false,
}) {
  final portrait = MediaQuery.orientationOf(context) != Orientation.landscape;
  final status = portrait
      ? _footerStatus(context, controller, channel, modeRow: modeRow)
      : '';
  final failed = controller.chat.loadFailedChannels.value.contains(channel);
  if (status.isEmpty && !failed) return 0;
  final line = TextPainter(
    text: TextSpan(text: 'M', style: _statusStyle(context)),
    textScaler: MediaQuery.textScalerOf(context),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final h = line.height + 4;
  line.dispose();
  return (status.isEmpty ? 0 : h) + (failed ? h : 0) + _statusFoot;
}

/// The status line's text: the stream part alone when the room modes ride
/// the button row, so a live channel in subs-only shows each on its own row.
String _footerStatus(
  BuildContext context,
  ComposerController controller,
  String channel, {
  required bool modeRow,
}) {
  final info = controller.chat.channelFor(channel)?.info;
  if (info == null) return '';
  return modeRow && modesFitRow(context, controller, channel)
      ? info.stream
      : info.status;
}

/// Extra room under the status lines, so the last one clears the island's
/// rounded edge.
const double _statusFoot = 4;

/// The channel status (portrait only, see [showStatus]) and a retry link
/// when a channel's emotes failed to load.
class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.controller,
    required this.selectedTabIndex,
    required this.swipePage,
    required this.showStatus,
    required this.modeRow,
  });

  final ComposerController controller;
  final ValueListenable<int> selectedTabIndex;
  final ValueListenable<double?> swipePage;
  final bool showStatus;
  final bool modeRow;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: swipePage,
    builder: (context, _) => _ChannelListener(
      controller: controller,
      selectedTabIndex: selectedTabIndex,
      builder: (context) {
        final shown = swipeShown(
          controller.chat.names,
          swipePage.value,
          controller.selectedChannel,
        );
        final lines = _swipeSlide(
          shown,
          (channel) => _lines(context, channel),
          alignment: Alignment.topCenter,
        );
        if (shown.length < 2) {
          return AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: lines,
          );
        }
        // Mid-swipe the island's height follows the page between the two
        // channels' footers.
        double heightOf(String channel) => composerStatusHeight(
          context,
          controller,
          channel,
          modeRow: modeRow,
        );
        return SizedBox(
          height: lerpDouble(
            heightOf(shown[0].$1),
            heightOf(shown[1].$1),
            -shown[0].$2,
          ),
          child: lines,
        );
      },
    ),
  );

  Widget _lines(BuildContext context, String channel) {
    final status = showStatus
        ? _footerStatus(context, controller, channel, modeRow: modeRow)
        : '';
    final hasLoadFailure = controller.chat.loadFailedChannels.value.contains(
      channel,
    );
    return Padding(
      padding: EdgeInsets.only(
        bottom: status.isEmpty && !hasLoadFailure ? 0 : _statusFoot,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 12, bottom: 4),
              child: Text(
                status,
                style: _statusStyle(context),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (hasLoadFailure)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: InkWell(
                onTap: () => controller.chatConn.retryChannelData(channel),
                child: Text(
                  context.l10n.retryFailedEmotes,
                  style: _statusStyle(
                    context,
                    color: Theme.of(context).colorScheme.primary,
                  ).copyWith(decoration: TextDecoration.underline),
                  maxLines: 1,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Each channel's [build] at its page offset ([swipeShown]), clipped, so
/// chrome tied to a channel slides with its page mid-swipe. Keyed by
/// channel, so a line keeps its state when a swipe starts.
Widget _swipeSlide(
  List<(String, double)> shown,
  Widget Function(String channel) build, {
  AlignmentGeometry alignment = Alignment.center,
}) => LayoutBuilder(
  builder: (context, constraints) => ClipRect(
    child: Stack(
      alignment: alignment,
      children: [
        for (final (channel, dx) in shown)
          Transform.translate(
            key: ValueKey(channel),
            offset: Offset(dx * constraints.maxWidth, 0),
            child: build(channel),
          ),
      ],
    ),
  ),
);
