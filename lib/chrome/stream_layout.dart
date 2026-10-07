import 'dart:async';

import 'package:flutter/material.dart';

import '../chat/chat.dart';
import '../l10n/l10n.dart';
import '../services/pip_service.dart';
import '../services/stream_player_controller.dart';
import '../util/insets.dart';
import '../util/layout_density.dart';
import '../widgets/chat_body.dart' show ComposerPaneSlot;
import '../widgets/glass_chrome.dart';
import '../widgets/stream_player_view.dart';
import 'channel_stack.dart';
import 'home_app_bar.dart';

// Pure rule for the stacked player: hide video when the keyboard leaves
// under 9 chat lines; audio keeps playing. Extracted so unit tests cover
// the threshold without a widget tree.
bool shouldShowStreamVideo({
  required double maxWidth,
  required double maxHeight,
  required double keyboardH,
  required double inputH,
  required double chatFontSize,
}) {
  if (keyboardH <= 0) return true;
  final streamH = maxWidth * 9 / 16;
  // Body constraints already exclude the keyboard (Scaffold resizes),
  // so maxHeight is the visible room; never subtract keyboardH again.
  return maxHeight - streamH - inputH >= chatFontSize * 9;
}

// Stacked player assembly. The video element stays at the same tree
// position in both branches (same wrapper types, only heights/flags
// change) so its State (WebView) survives keyboard toggles. When hidden
// the video keeps its full size inside a 1px clip (still composited, so
// audio keeps playing and the PlatformView never resizes). Never use
// Visibility/Offstage here: a PlatformView going offstage in the same
// frame the Scaffold resizes for the keyboard red-screens the body.
Widget buildStackedPlayer({
  required bool show,
  required Widget video,
  required Widget audioBar,
}) {
  return LayoutBuilder(
    builder: (context, constraints) {
      final maxW = constraints.maxWidth;
      final w = maxW.isFinite && maxW > 0
          ? maxW
          : MediaQuery.sizeOf(context).width;
      final h = w * 9 / 16;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: w,
            height: show ? h : StreamPanels.hiddenVideoHeight,
            child: ClipRect(
              child: OverflowBox(
                maxWidth: w,
                maxHeight: h,
                alignment: Alignment.topCenter,
                child: SizedBox(width: w, height: h, child: video),
              ),
            ),
          ),
          if (!show) audioBar,
        ],
      );
    },
  );
}

class StreamPanels {
  // Stream player layouts (stacked/theater/split), the body column router,
  // and the stream toggle/player-changed verbs.
  StreamPanels({
    required this.streamPlayer,
    required this.pipService,
    required this.chat,
    required this.channels,
    required this.homeAppBar,
    required this.selectedChannel,
    required this.isMounted,
    required this.markDirty,
    required this.setStreamState,
    required this.chatFontSize,
    required this.isFullscreen,
    required this.theaterChatVisible,
    required this.toggleTheaterChat,
    required this.onChannelChanged,
  });

  static const audioBarHeight = 56.0;

  // Clipped-alive video strip when the keyboard hides the picture.
  static const hiddenVideoHeight = 1.0;

  final StreamPlayerController streamPlayer;
  final PipService pipService;
  final Chat chat;
  final ChannelPanels channels;
  final HomeAppBar homeAppBar;
  final String? Function() selectedChannel;
  final bool Function() isMounted;
  final VoidCallback markDirty;
  final void Function(void Function() fn) setStreamState;
  final double Function() chatFontSize;
  final bool Function() isFullscreen;
  final bool Function() theaterChatVisible;
  final VoidCallback toggleTheaterChat;
  final void Function(int index) onChannelChanged;

  bool _wasTheaterMode = false;
  bool? _lastAutoEnter;
  bool? _lastPipPlaying;

  void toggleStreamForSelected() {
    if (streamPlayer.isActive) {
      setStreamState(() => streamPlayer.closeStream());
      return;
    }
    final channel = selectedChannel();
    if (channel == null) return;
    setStreamState(() => streamPlayer.toggleStream(channel));
  }

  void onStreamPlayerChanged() {
    if (!isMounted()) return;
    final enteringTheater = streamPlayer.isTheaterMode && !_wasTheaterMode;
    _wasTheaterMode = streamPlayer.isTheaterMode;
    markDirty();
    // OS auto-enter follows eligibility (active video + opted in), sent
    // only on flips to avoid channel spam. Mirrors DankChat's
    // shouldEnablePictureInPictureAutoMode flow.
    final autoEnter = streamPlayer.canPip;
    if (autoEnter != _lastAutoEnter) {
      _lastAutoEnter = autoEnter;
      unawaited(pipService.setAutoEnter(autoEnter));
    }
    // Keeps the PiP window's play/pause icon truthful. The audio action
    // icon is static, so audio-only flips need no native update.
    final playing = streamPlayer.pipPlaying;
    if (playing != null && playing != _lastPipPlaying) {
      _lastPipPlaying = playing;
      unawaited(pipService.updatePipActions(playing: playing));
    }
    if (!enteringTheater) return;
    final channel = streamPlayer.currentChannel;
    if (channel == null) return;
    if (selectedChannel() == channel) return;
    if (!chat.contains(channel)) return;
    onChannelChanged(chat.names.indexOf(channel));
  }

  // DankChat shouldShowStream: hide video when the keyboard leaves under
  // 9 chat lines; audio keeps playing. inputH is the settled composer
  // height measured post-layout by ChatBody, never read here: touching
  // inputBarKey.size during build throws every frame (log spam + crash).
  bool showStreamVideo({
    required double maxWidth,
    required double maxHeight,
    required double keyboardH,
    required double inputH,
  }) {
    if (keyboardH <= 0) return true;
    return shouldShowStreamVideo(
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      keyboardH: keyboardH,
      inputH: inputH,
      chatFontSize: chatFontSize(),
    );
  }

  Widget playerView(
    String channel, {
    bool fillPane = false,
    bool visible = true,
    bool showControls = true,
  }) {
    return StreamPlayerView(
      key: StreamPlayerView.keyFor(streamPlayer, channel),
      controller: streamPlayer,
      channel: channel,
      fillPane: fillPane,
      visible: visible,
      showControls: showControls,
    );
  }

  Widget stackedPlayer(String channel, bool showVideo) {
    final show = showVideo && !streamPlayer.isAudioOnly;
    // fillPane so the inner video is an exact w x h box in both branches;
    // the wrapper only changes the outer clip height, never the WebView.
    final video = playerView(channel, fillPane: true, visible: show);
    return buildStackedPlayer(
      show: show,
      video: video,
      audioBar: StreamAudioBar(
        key: ValueKey('audio:$channel'),
        controller: streamPlayer,
        channel: channel,
      ),
    );
  }

  // Landscape theater: full-bleed video with a translucent chat overlay.
  // The WebView keeps full size and is never resized (DankChat TheaterLayout).
  Widget theater(BuildContext context, String channel) {
    final scheme = Theme.of(context).colorScheme;
    final panelW = (MediaQuery.sizeOf(context).width - 120).clamp(200.0, 320.0);
    return Stack(
      children: [
        Positioned.fill(
          child: _dismissesKeyboard(playerView(channel, fillPane: true)),
        ),
        if (theaterChatVisible())
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: panelW,
            child: ColoredBox(
              color: scheme.surface.withValues(alpha: 0.92),
              child: SafeArea(
                left: false,
                bottom: false,
                child: Column(
                  children: [
                    Expanded(
                      child: channels.channelStack(
                        context,
                        hideChrome: true,
                        overlayTop: 8,
                      ),
                    ),
                    const ComposerPaneSlot(),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          bottom: 16,
          right: theaterChatVisible() ? panelW + 8 : 8,
          child: FloatingActionButton.small(
            heroTag: 'theater_chat_toggle',
            tooltip: theaterChatVisible()
                ? context.l10n.hideChat
                : context.l10n.showChat,
            onPressed: toggleTheaterChat,
            child: Icon(
              theaterChatVisible() ? Icons.visibility_off : Icons.visibility,
            ),
          ),
        ),
      ],
    );
  }

  /// [hideChrome] drops the chat pane's app bar and tabs while the keyboard
  /// leaves too little room, as portrait does.
  Widget split(
    BuildContext context,
    String channel,
    double maxWidth, {
    bool hideChrome = false,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Past 16:9 at full height the video only gains side bars, so the
        // player pane stops growing there.
        final maxFrac = (constraints.maxHeight * 16 / 9 / maxWidth).clamp(
          0.2,
          0.8,
        );
        return StatefulBuilder(
          builder: (context, setLocal) {
            final frac = streamPlayer.splitFraction.clamp(0.2, maxFrac);
            return Row(
              children: [
                SizedBox(
                  width: maxWidth * frac,
                  child: _dismissesKeyboard(
                    playerView(channel, fillPane: true),
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  // Reads the live fraction, not this build's: several drag
                  // updates can land before the next rebuild.
                  onHorizontalDragUpdate: (details) => setLocal(
                    () => streamPlayer.dragSplitFraction(
                      (streamPlayer.splitFraction.clamp(0.2, maxFrac) +
                              details.delta.dx / maxWidth)
                          .clamp(0.2, maxFrac),
                    ),
                  ),
                  onHorizontalDragEnd: (_) =>
                      streamPlayer.setSplitFraction(streamPlayer.splitFraction),
                  child: const SizedBox(
                    width: 16,
                    child: Center(
                      child: SizedBox(
                        width: 4,
                        height: 48,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.grey,
                            borderRadius: BorderRadius.all(Radius.circular(2)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    children: [
                      Expanded(
                        child: channels.channelStack(
                          context,
                          hideChrome: hideChrome,
                          overlayTop: 50,
                        ),
                      ),
                      const ComposerPaneSlot(),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // A tap on the stream also drops the keyboard, so a crowded landscape
  // layout always has a way out (iOS has no back key). Taps still reach
  // the player.
  Widget _dismissesKeyboard(Widget child) => Listener(
    onPointerDown: (_) => FocusManager.instance.primaryFocus?.unfocus(),
    child: child,
  );

  /// Whether chat sits in a pane beside the stream (landscape theater with
  /// chat shown, or split on a wide screen), matching [bodyColumn]. The
  /// composer then docks under that pane so the stream keeps full height.
  bool chatInPane(BuildContext context) {
    if (streamPlayer.currentChannel == null ||
        streamPlayer.isAudioOnly ||
        streamPlayer.isInPip) {
      return false;
    }
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    if (streamPlayer.isTheaterMode && landscape) return theaterChatVisible();
    return MediaQuery.sizeOf(context).width >= 600;
  }

  Widget bodyColumn(
    BuildContext context, {
    required bool hideChromeForKeyboard,
    required double maxWidth,
    required double maxHeight,
    required double keyboardH,
    required double composerH,
    bool liquidGlass = false,
  }) {
    final channel = streamPlayer.currentChannel;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final hideChrome = hideChromeForKeyboard;
    // System PiP window shows the whole activity, so collapse to video-only
    // (DankChat hides appbar/tabs/chat/input the same way). The app root draws
    // the player above routes; this stays black so one player holds the key.
    if (channel != null && streamPlayer.isInPip) {
      return const Column(
        children: [Expanded(child: ColoredBox(color: Colors.black))],
      );
    }
    if (channel != null &&
        !streamPlayer.isAudioOnly &&
        streamPlayer.isTheaterMode &&
        landscape) {
      return Column(children: [Expanded(child: theater(context, channel))]);
    }
    if (channel != null && !streamPlayer.isAudioOnly && maxWidth >= 600) {
      return Column(
        children: [
          Expanded(
            child: split(context, channel, maxWidth, hideChrome: hideChrome),
          ),
        ],
      );
    }
    // Compact folds the app bar into the tab strip. With no channels there
    // is no strip, so the welcome view keeps the app bar.
    final overrides = layoutOverridesOf(context);
    final compact = isCompactLayout(context);
    final merged =
        overrides.resolve(overrides.mergeAppBar, compact) &&
        chat.names.isNotEmpty;
    final showVideo =
        channel == null ||
        showStreamVideo(
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          keyboardH: keyboardH,
          inputH: composerH,
        );
    // Chat-only portrait floats one glass block above
    // full-height pages; fullscreen slides it away. Stream, theater, split,
    // and keyboard-collapse states keep the docked layout. With no channels
    // the card holds the app bar only (no tab strip) over the welcome view.
    final glass = liquidGlass && !MediaQuery.highContrastOf(context);
    if (glass && !hideChrome && channel == null) {
      final headerH = merged
          ? glassCompactHeaderHeight(context)
          : chat.names.isNotEmpty
          ? glassHeaderHeight(context)
          : glassWelcomeHeaderHeight(context);
      // The pill clearance reaches the lists through GlassChromeScope, not
      // this call, so pages stay cached while the safe area animates.
      return Column(
        children: [
          channels.channelTabs(
            context,
            hideChrome: false,
            merged: merged,
            overlayTop: isFullscreen() ? 8 : headerH + 8,
            belowTabBar: null,
            glassOverlay: true,
            glassHeader: merged
                ? null
                : homeAppBar.appBar(context, transparent: true),
            glassHeaderHeight: headerH,
            glassTopPadding: headerH,
          ),
        ],
      );
    }
    final showPlayerVideo =
        showVideo && channel != null && !streamPlayer.isAudioOnly;
    final aboveTabsH = channel == null
        ? 0.0
        : showPlayerVideo
        ? maxWidth * 9 / 16
        : audioBarHeight + hiddenVideoHeight;
    return Column(
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          child: !isFullscreen() && !hideChrome && !merged
              ? homeAppBar.appBar(context)
              : const SizedBox.shrink(),
        ),
        channels.channelTabs(
          context,
          hideChrome: hideChrome,
          merged: merged,
          glassChrome: glass,
          // Merged, the strip starts under the status bar, not the app bar.
          overlayTop: (merged ? statusBarHeight(context) : 0) + 50 + aboveTabsH,
          belowTabBar: channel == null
              ? null
              : stackedPlayer(channel, showVideo),
        ),
      ],
    );
  }
}
