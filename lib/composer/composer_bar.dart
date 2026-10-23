import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;

import '../panels/mod_panel.dart';
import '../panels/search.dart';
import '../util/chrome_theme.dart';
import '../widgets/media_upload_controller.dart';
import '../widgets/message_input.dart';
import '../widgets/send_hold.dart';
import '../widgets/tabbed_layout.dart' show swipeShown;
import 'composer_controller.dart';
import '../l10n/l10n.dart';
import '../widgets/design_tokens.dart';

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
    this.emoteInRow = false,
    this.sendOutside = false,
    this.startItems = const [FieldItem.emote],
    this.endItems = const [FieldItem.send],
    this.actionBuilder,
    this.startSlot,
    this.endSlot,
    this.readOnly = false,
    this.classic = false,
    this.modeRow = false,
    this.uploads,
  });

  final ComposerController controller;
  final ValueListenable<int> selectedTabIndex;
  final SearchPanels search;
  final ModPanels mod;

  /// Uploads images the keyboard inserts into the chat field.
  final MediaUploadController? uploads;

  /// The island's button row shows, so room modes may ride it
  /// ([ComposerModeRow]) instead of the status.
  final bool modeRow;

  /// Panel tab drag crossings. The morph tracks 50% through this alone,
  /// without a full HomeScreen rebuild per crossing (main chat's focus
  /// path skips setState the same way); settle still marks dirty.
  final Listenable dragTick;

  /// The emote button sits in the island's button row ([ComposerRowButton])
  /// instead of the field.
  final bool emoteInRow;

  /// Send sits in the island's row or side column instead of the field.
  final bool sendOutside;

  /// The field row's buttons before and after the text field, and how to
  /// build a chrome action among them.
  final List<FieldItem> startItems;
  final List<FieldItem> endItems;
  final Widget Function(ChromeAction action)? actionBuilder;

  /// Stand-ins for the field row's sides, for the layout editor's chips and
  /// drop targets.
  final Widget? startSlot;
  final Widget? endSlot;

  /// Keeps the field from taking focus, for the layout editor.
  final bool readOnly;

  /// The plain outlined field of [ComposerStyle.classic], with no island
  /// around it.
  final bool classic;

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
                  if (channel != null) search.typeQuery(channel, q);
                },
                onSubmitted: (_) => search.focusNode.unfocus(),
                enabled: true,
                hintText: context.l10n.searchHint,
                searchMode: true,
                borderless: !classic,
                prefixOverride: search.closeButton(),
                // With send outside the field, the filter moves out with it.
                suffixOverride: sendOutside ? null : search.filterButton(),
                startItems: const [],
                endItems: const [],
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
                borderless: !classic,
                // Add moves out with send, and the field needs no icon
                // standing in for an emote button that left.
                prefixOverride: emoteInRow ? null : mod.termsPrefixSlot(),
                suffixOverride: sendOutside ? null : mod.termsSubmitSlot(),
                startItems: const [],
                endItems: const [],
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
                  onRecallUndo: controller.undoRecall,
                  onSpamStart: controller.sendSwipeMenu()
                      ? controller.startSpam
                      : null,
                  onSpamStop: controller.stopSpam,
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
                  onContentInserted: uploads == null
                      ? null
                      : (content) => uploads!.uploadInserted(context, content),
                  borderless: !classic,
                  // The classic field has no island to trace, so an upload
                  // shades the field itself.
                  fillProgress: classic ? uploads?.progress : null,
                  prefixOverride: startSlot,
                  suffixOverride: endSlot,
                  startItems: startItems,
                  endItems: endItems,
                  actionBuilder: actionBuilder,
                  readOnly: readOnly,
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
      controller.modesUnderSend,
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
        child: SendHold(
          enabled: enabled,
          onRecall: controller.recallLastSent,
          onRecallUndo: controller.undoRecall,
          onSpamStart: controller.sendSwipeMenu() ? controller.startSpam : null,
          onSpamStop: controller.stopSpam,
          child: InkWell(
            onTap: enabled ? controller.send : null,
            // The strip is far larger than a button, so its ink runs at about
            // half the stock strength.
            splashColor: scheme.onSurface.withValues(alpha: 0.06),
            highlightColor: scheme.onSurface.withValues(alpha: 0.04),
            // Room modes reaching under the column push the icon up beside
            // the field's first line.
            child: Align(
              alignment: controller.modesUnderSend.value
                  ? Alignment.topCenter
                  : Alignment.center,
              child: Padding(
                padding: EdgeInsets.only(
                  top: controller.modesUnderSend.value ? 16 : 0,
                ),
                child: Icon(
                  Icons.send,
                  color: enabled
                      ? accent
                      : scheme.onSurface.withValues(alpha: 0.38),
                ),
              ),
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
    this.alignStart = false,
    this.sendRoom = 0,
  });

  /// Width past the gap's end the modes may take when they need it: the
  /// send column's part beside the row, whose icon then moves up.
  final double sendRoom;

  final ComposerController controller;
  final ValueListenable<int> selectedTabIndex;
  final SearchPanels search;
  final ModPanels mod;
  final Listenable dragTick;

  /// The channel pager's fractional page while it moves; each channel's
  /// modes slide with its page.
  final ValueListenable<double?> swipePage;

  /// The modes sit at the gap's start, beside the emote button, instead of
  /// centered: for rows whose actions sit right, where the gap is wide.
  final bool alignStart;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final gap = constraints.maxWidth;
      controller.modeSendRoom = sendRoom;
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
                (channel) {
                  final width = _modesWidth(context, controller, channel);
                  final wide = width != null && width > gap;
                  if (channel == controller.selectedChannel) {
                    _noteUnderSend(wide && width <= gap + sendRoom);
                  }
                  if (!modesFitRow(context, controller, channel)) {
                    return const SizedBox.shrink();
                  }
                  final line = Align(
                    alignment: alignStart
                        ? AlignmentDirectional.centerStart
                        : Alignment.center,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _modeRowPad,
                      ),
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
                  );
                  if (!wide) return line;
                  // Paints on under the send column, which stays on top and
                  // keeps every tap. The row's height is unbounded, so the
                  // box takes the line's height instead of the biggest.
                  return OverflowBox(
                    fit: OverflowBoxFit.deferToChild,
                    alignment: AlignmentDirectional.centerStart,
                    minWidth: gap + sendRoom,
                    maxWidth: gap + sendRoom,
                    child: line,
                  );
                },
              ),
            ),
          );
        },
      );
    },
  );

  void _noteUnderSend(bool under) {
    if (controller.modesUnderSend.value == under) return;
    // Build can't notify listeners mid-frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.modesUnderSend.value = under;
    });
  }
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
  final width = _modesWidth(context, controller, channel);
  return width != null &&
      width <= controller.modeGap.value + controller.modeSendRoom;
}

/// [channel]'s modes line width with its padding, or null without modes.
double? _modesWidth(
  BuildContext context,
  ComposerController controller,
  String channel,
) {
  final modes = controller.chat.channelFor(channel)?.info.modes ?? const [];
  if (modes.isEmpty) return null;
  final line = TextPainter(
    text: TextSpan(text: modes.join(' · '), style: _statusStyle(context)),
    textScaler: MediaQuery.textScalerOf(context),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final width = line.width;
  line.dispose();
  return width + 2 * _modeRowPad;
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
    this.modeRow = false,
    this.classic = false,
  });

  final ComposerController controller;
  final ValueListenable<int> selectedTabIndex;
  final SearchPanels search;
  final ModPanels mod;
  final Listenable dragTick;

  /// See [ComposerBar.modeRow].
  final bool modeRow;

  /// See [ComposerBar.classic]: the line sits left under the outlined field
  /// and eases in over a longer beat.
  final bool classic;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _enabledInputs(controller, mod, dragTick),
    builder: (context, _) {
      if (composerStatusHidden(search, mod)) return const SizedBox.shrink();
      return _StatusRow(
        controller: controller,
        selectedTabIndex: selectedTabIndex,
        modeRow: modeRow,
        classic: classic,
      );
    },
  );
}

/// Whether the status row steps aside: search or block terms borrow the
/// field.
bool composerStatusHidden(SearchPanels search, ModPanels mod) =>
    (search.open && search.selectedChannel() != null) || mod.termsChromeHidden;

/// The status line's text style. Explicit (not inherited), so its height can
/// be measured away from the island.
TextStyle _statusStyle(BuildContext context, {Color? color}) {
  final theme = Theme.of(context);
  return (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
    fontSize: 12,
    color: color ?? theme.colorScheme.onSurfaceVariant,
  );
}

/// Height the status row takes for [channel], or zero when [hidden] (see
/// [composerStatusHidden]). Each chat page adds its own channel's, so a page
/// is already placed for the island it is about to show, and only the
/// island moves on a switch. The row renders at this same height.
double composerStatusHeight(
  BuildContext context,
  ComposerController controller,
  String channel, {
  bool modeRow = false,
  bool hidden = false,
}) {
  if (hidden) return 0;
  final lines = _statusLines(context, controller, channel, modeRow: modeRow);
  return _statusRowHeight(lines, _statusLineHeight(context));
}

/// What the status row shows for [channel]: its status line (portrait only;
/// landscape moves it into the field's hint) and whether the retry link for
/// failed emotes shows.
({String status, bool failed}) _statusLines(
  BuildContext context,
  ComposerController controller,
  String channel, {
  required bool modeRow,
}) {
  final portrait = MediaQuery.orientationOf(context) != Orientation.landscape;
  return (
    status: portrait
        ? _footerStatus(context, controller, channel, modeRow: modeRow)
        : '',
    failed: controller.chat.loadFailedChannels.value.contains(channel),
  );
}

/// One status line's height: its text and the gap under it.
double _statusLineHeight(BuildContext context) {
  final line = TextPainter(
    text: TextSpan(text: 'M', style: _statusStyle(context)),
    textScaler: MediaQuery.textScalerOf(context),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final h = line.height + 4;
  line.dispose();
  return h;
}

double _statusRowHeight(({String status, bool failed}) lines, double lineH) {
  if (lines.status.isEmpty && !lines.failed) return 0;
  return (lines.status.isEmpty ? 0 : lineH) +
      (lines.failed ? lineH : 0) +
      _statusFoot;
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

/// The channel status (see [_statusLines]) and a retry link when a channel's
/// emotes failed to load.
class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.controller,
    required this.selectedTabIndex,
    required this.modeRow,
    required this.classic,
  });

  final ComposerController controller;
  final ValueListenable<int> selectedTabIndex;
  final bool modeRow;
  final bool classic;

  @override
  Widget build(BuildContext context) => _ChannelListener(
    controller: controller,
    selectedTabIndex: selectedTabIndex,
    builder: (context) {
      final channel = controller.selectedChannel;
      return AnimatedSize(
        duration: Motion.fast,
        curve: Motion.move,
        alignment: Alignment.topCenter,
        child: channel == null
            ? const SizedBox.shrink()
            : _lines(context, channel),
      );
    },
  );

  Widget _lines(BuildContext context, String channel) {
    final lines = _statusLines(context, controller, channel, modeRow: modeRow);
    final lineH = _statusLineHeight(context);
    // Sized by the same numbers [composerStatusHeight] predicts, so a page
    // placed for this island matches it exactly.
    return SizedBox(
      height: _statusRowHeight(lines, lineH),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: classic
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          if (lines.status.isNotEmpty)
            SizedBox(
              height: lineH,
              child: Padding(
                padding: EdgeInsets.only(
                  left: classic ? 20 : 12,
                  right: 12,
                  bottom: 4,
                ),
                child: Text(
                  lines.status,
                  style: _statusStyle(context),
                  textAlign: classic ? TextAlign.start : TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          if (lines.failed)
            SizedBox(
              height: lineH,
              child: Padding(
                padding: EdgeInsets.only(left: classic ? 20 : 0, bottom: 4),
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
  Widget Function(String channel) build,
) => LayoutBuilder(
  builder: (context, constraints) => ClipRect(
    child: Stack(
      alignment: Alignment.center,
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
