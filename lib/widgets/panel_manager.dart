import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/twitch_message.dart';
import '../services/emote_manager.dart';
import '../util/haptics.dart';
import '../util/insets.dart';
import '../util/sheet_drag.dart';
import '../util/thread_utils.dart';

enum OverlayPanel { closed, thread, mentions, modView }

// Panel and emote-sheet state machine for the home screen.
class PanelManager {
  PanelManager({
    required this.vsync,
    required this.markDirty,
    required this.isMounted,
  });

  final TickerProvider vsync;
  final VoidCallback markDirty;
  final bool Function() isMounted;

  OverlayPanel activePanel = OverlayPanel.closed;
  bool emoteSheetOpen = false;

  /// True from the start of the emote sheet's close animation until it
  /// lands, so a toggle in between reopens instead of closing again.
  bool emoteSheetClosing = false;
  int _emoteCloseGen = 0;
  TwitchMessage? _openThreadRoot;
  TwitchMessage? get openThreadRoot => _openThreadRoot;
  set openThreadRoot(TwitchMessage? root) {
    _openThreadRoot = root;
    onOpenThreadChanged?.call();
  }

  VoidCallback? onOpenThreadChanged;
  void Function(OverlayPanel)? onPanelClosed;
  List<TwitchMessage> threadMessages = [];
  String? threadChannel;

  final threadSheetRatio = ValueNotifier(0.0);
  final mentionsSheetRatio = ValueNotifier(0.0);
  final modSheetRatio = ValueNotifier(0.0);
  late final AnimationController panelScaleCtrl = AnimationController(
    vsync: vsync,
    duration: const Duration(milliseconds: 200),
    value: 1.0,
  );
  late final DraggableScrollableController emoteSheetCtrl =
      DraggableScrollableController();

  double panelDragStartRatio = 0.0;
  double panelDragStartY = 0.0;

  static const sheetAnimDuration = Duration(milliseconds: 250);
  static const sheetCloseDuration = Duration(milliseconds: 180);
  static const emoteMaxFraction = 0.6;
  static const fullHeightFraction = 1.0;

  void dispose() {
    for (final c in _animations) {
      c.dispose();
    }
    _animations.clear();
    panelScaleCtrl.dispose();
    emoteSheetCtrl.dispose();
    threadSheetRatio.dispose();
    mentionsSheetRatio.dispose();
    modSheetRatio.dispose();
  }

  void onSheetSizeChanged() {
    if (emoteSheetOpen &&
        emoteSheetCtrl.isAttached &&
        emoteSheetCtrl.size <= 0.001) {
      emoteSheetOpen = false;
      panelScaleCtrl.value = 1.0;
      markDirty();
    }
  }

  Future<void> closePanel() async {
    final panelToClose = activePanel;
    final rootToClose = openThreadRoot;
    if (panelToClose == OverlayPanel.closed && !emoteSheetOpen) return;
    await closeEmoteSheet();
    if (panelToClose == OverlayPanel.closed) {
      if (isMounted()) markDirty();
      return;
    }
    if (panelToClose == OverlayPanel.thread) {
      await animateRatio(
        threadSheetRatio,
        threadSheetRatio.value,
        0.0,
        sheetCloseDuration,
      );
    } else if (panelToClose == OverlayPanel.mentions) {
      await animateRatio(
        mentionsSheetRatio,
        mentionsSheetRatio.value,
        0.0,
        sheetCloseDuration,
      );
    } else if (panelToClose == OverlayPanel.modView) {
      await animateRatio(
        modSheetRatio,
        modSheetRatio.value,
        0.0,
        sheetCloseDuration,
      );
    }
    if (isMounted()) {
      // A reopen racing the close animation wins: only clear when the panel
      // and its thread root are still the ones that started closing.
      if (activePanel == panelToClose &&
          identical(openThreadRoot, rootToClose)) {
        activePanel = OverlayPanel.closed;
        openThreadRoot = null;
        onPanelClosed?.call(panelToClose);
      }
      panelScaleCtrl.value = 1.0;
      markDirty();
    }
  }

  // In-flight panel animations, so dispose can stop them.
  final _animations = <AnimationController>{};

  Future<void> animateRatio(
    ValueNotifier<double> ratio,
    double from,
    double to,
    Duration duration,
  ) async {
    if (from == to) return;
    final controller = AnimationController(vsync: vsync, duration: duration);
    _animations.add(controller);
    final animation = Tween(
      begin: from,
      end: to,
    ).animate(CurvedAnimation(parent: controller, curve: Curves.easeOutCubic));
    void listener() {
      ratio.value = animation.value;
    }

    animation.addListener(listener);
    await controller.forward();
    animation.removeListener(listener);
    // Already disposed when the manager went first.
    if (_animations.remove(controller)) controller.dispose();
  }

  Widget buildPanelDragHandle({
    required ValueNotifier<double> ratio,
    required double maxSize,
    required VoidCallback onClose,
    required VoidCallback onSnap,
    required double sheetH,
    Widget? header,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (details) {
        panelDragStartRatio = ratio.value;
        panelDragStartY = details.globalPosition.dy;
      },
      onVerticalDragUpdate: (details) {
        final cumulativeDelta = details.globalPosition.dy - panelDragStartY;
        // Drag basis is the rendered sheet height, not screen math: the
        // Scaffold strips viewInsets below it, so inset reads here lie.
        final height = maxSize * sheetH;
        ratio.value = (panelDragStartRatio - cumulativeDelta / height).clamp(
          0.0,
          maxSize,
        );
      },
      onVerticalDragEnd: (details) {
        if (shouldCloseSheet(
          fraction: ratio.value / maxSize,
          velocity: details.primaryVelocity ?? 0,
        )) {
          onClose();
        } else {
          onSnap();
        }
      },
      // A cancelled drag would otherwise leave the sheet mid-way.
      onVerticalDragCancel: onSnap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            color: Colors.transparent,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          ?header,
        ],
      ),
    );
  }

  Widget buildOverlaySheet({
    required bool offstage,
    required ValueNotifier<double> ratio,
    required Widget header,
    required Widget body,
    required BuildContext context,
  }) {
    final screen = MediaQuery.sizeOf(context);
    // Full bleed: the handle strip fills in behind the status bar, so the
    // header underneath (glass or opaque) never peeks out above the panel.
    final statusBarH = statusBarHeight(context);
    return Positioned(
      top: 0,
      bottom: 0,
      left: 0,
      right: 0,
      // Offstage still lays out its child. A hidden panel gets a fixed size
      // instead, so keyboard ticks that shrink the stack skip its layout
      // rather than rebuilding it every frame.
      child: Offstage(
        offstage: offstage,
        child: OverflowBox(
          minWidth: offstage ? screen.width : null,
          maxWidth: offstage ? screen.width : null,
          minHeight: offstage ? screen.height : null,
          maxHeight: offstage ? screen.height : null,
          child: LayoutBuilder(
            builder: (context, constraints) => ScaleTransition(
              scale: panelScaleCtrl,
              alignment: Alignment.bottomCenter,
              child: buildSheetPanel(
                ratio: ratio,
                child: RepaintBoundary(
                  child: Material(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    clipBehavior: Clip.hardEdge,
                    child: Column(
                      children: [
                        Container(
                          color: Theme.of(context).colorScheme.surfaceContainer,
                          padding: EdgeInsets.only(top: statusBarH),
                          child: buildPanelDragHandle(
                            ratio: ratio,
                            maxSize: fullHeightFraction,
                            onClose: closePanel,
                            onSnap: () => animateRatio(
                              ratio,
                              ratio.value,
                              fullHeightFraction,
                              sheetAnimDuration,
                            ),
                            sheetH: constraints.maxHeight,
                            header: header,
                          ),
                        ),
                        // The sheet slides down rather than shrinking; the
                        // body pads off the hidden part, so lists rest and
                        // end where the sheet is visible.
                        Expanded(
                          child: AnimatedBuilder(
                            animation: ratio,
                            builder: (context, child) => Padding(
                              padding: EdgeInsets.only(
                                bottom:
                                    constraints.maxHeight *
                                    (1 - ratio.value).clamp(0.0, 1.0),
                              ),
                              child: child,
                            ),
                            child: body,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget buildSheetPanel({
    required ValueNotifier<double> ratio,
    required Widget child,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.bottomCenter,
            minHeight: height,
            maxHeight: height,
            child: AnimatedBuilder(
              animation: ratio,
              builder: (context, child) {
                final closedFraction = (1.0 - ratio.value).clamp(0.0, 1.0);
                return FractionalTranslation(
                  translation: Offset(0, closedFraction),
                  child: child!,
                );
              },
              child: child,
            ),
          ),
        );
      },
    );
  }

  Widget buildSlideUpContent({
    required DraggableScrollableController controller,
    required double totalAvailH,
    required double maxSize,
    required Widget child,
  }) {
    final contentH = maxSize * totalAvailH;
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.bottomCenter,
        minHeight: contentH,
        maxHeight: contentH,
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, child) {
            final size = controller.isAttached ? controller.size : 0.0;
            final closedFraction = maxSize <= 0
                ? 0.0
                : (1 - (size / maxSize)).clamp(0.0, 1.0);
            return FractionalTranslation(
              translation: Offset(0, closedFraction),
              child: child!,
            );
          },
          child: child,
        ),
      ),
    );
  }

  void showEmoteMenu({
    required String? selectedChannel,
    required EmoteManager emoteManager,
    required Map<String, String> channelUserIds,
  }) {
    iosHaptic(HapticFeedback.lightImpact);
    if (selectedChannel != null &&
        !emoteManager.hasChannelCache(selectedChannel)) {
      unawaited(
        emoteManager.resolveEmotes(
          selectedChannel,
          channelUserIds[selectedChannel],
        ),
      );
    }
    if (!emoteManager.hasGlobalCache) {
      unawaited(emoteManager.preloadGlobalEmotes());
    }
    emoteSheetOpen = true;
    emoteSheetClosing = false;
    _emoteCloseGen++;
    markDirty();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isMounted() || !emoteSheetCtrl.isAttached) return;
      unawaited(
        emoteSheetCtrl.animateTo(
          emoteMaxFraction,
          duration: sheetAnimDuration,
          curve: Curves.easeInOutCubicEmphasized,
        ),
      );
    });
  }

  Future<void> closeEmoteSheet() async {
    if (!emoteSheetOpen) return;
    if (emoteSheetCtrl.isAttached) {
      if (emoteSheetCtrl.size <= 0.001) {
        if (isMounted()) {
          emoteSheetOpen = false;
          panelScaleCtrl.value = 1.0;
          markDirty();
        }
        return;
      }
      final fraction = (emoteSheetCtrl.size / emoteMaxFraction).clamp(0.0, 1.0);
      final duration = Duration(milliseconds: (80 + 180 * fraction).round());
      emoteSheetClosing = true;
      final gen = ++_emoteCloseGen;
      unawaited(
        emoteSheetCtrl
            .animateTo(
              0,
              duration: duration,
              curve: Curves.easeInOutCubicEmphasized,
            )
            .then((_) {
              // A reopen mid-close owns the sheet now.
              if (!isMounted() || gen != _emoteCloseGen) return;
              emoteSheetClosing = false;
              emoteSheetOpen = false;
              panelScaleCtrl.value = 1.0;
              markDirty();
            }),
      );
    } else {
      if (isMounted()) {
        emoteSheetOpen = false;
        panelScaleCtrl.value = 1.0;
        markDirty();
      }
    }
  }

  void handlePanelBack() {
    if (emoteSheetOpen) {
      unawaited(closeEmoteSheet());
    } else {
      unawaited(closePanel());
    }
  }

  List<TwitchMessage> computeThreadMessages({
    required TwitchMessage? openThreadRoot,
    required List<TwitchMessage>? Function(String channel) messagesFor,
    required List<TwitchMessage>? Function(String channel, String rootId)
    threadFor,
  }) {
    final entry = openThreadRoot;
    if (entry == null) return const [];
    final channel = entry.channel;
    if (channel == null) return const [];
    final allMsgs = messagesFor(channel) ?? [];

    final entryKey = entry.replyThreadRootId ?? entry.messageId;
    if (entryKey == null) return const [];

    final parentOf = <String, String>{};
    for (final m in allMsgs) {
      if (m.replyToParentId != null && m.messageId != null) {
        parentOf[m.messageId!] = m.replyToParentId!;
      }
    }

    final resolvedKey = threadKeyFor(entry, parentOf);
    if (resolvedKey == null) return const [];

    // Prefer the incremental thread store: it survives scrollback trimming
    // (pinned root, decayed replies) where a pure buffer scan comes up empty.
    // Old-style parent-chain threads that were never tagged fall back to the
    // scan below.
    final threadMsgs =
        threadFor(channel, resolvedKey) ??
        allMsgs.where((m) => threadKeyFor(m, parentOf) == resolvedKey).toList();

    threadMsgs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return threadMsgs;
  }

  TwitchMessage? findThreadRoot(
    TwitchMessage msg, {
    required List<TwitchMessage>? Function(String channel) messagesFor,
  }) {
    if (msg.replyThreadRootId != null) return msg;

    final channel = msg.channel;
    if (channel == null) return null;
    final msgs = messagesFor(channel);
    if (msgs == null) return null;

    if (msg.messageId != null &&
        msgs.any((m) => m.replyToParentId == msg.messageId)) {
      return msg;
    }

    if (msg.replyToParentId == null) return null;

    final visited = <String>{};
    TwitchMessage current = msg;
    while (current.replyToParentId != null &&
        visited.add(current.replyToParentId!)) {
      final parent = msgs
          .where((m) => m.messageId == current.replyToParentId)
          .firstOrNull;
      if (parent == null) break;
      current = parent;
    }
    return current;
  }
}

/// Overlay panel header: a leading close/back button inline with the
/// panel's [tabs], which already name the panel, so there is no title row.
Widget panelHeader({required Widget leading, required Widget tabs}) => Padding(
  padding: const EdgeInsets.only(left: 4),
  child: Row(
    children: [
      leading,
      Expanded(child: tabs),
    ],
  ),
);
