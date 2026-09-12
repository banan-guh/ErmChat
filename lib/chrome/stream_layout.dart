import 'dart:async';

import 'package:flutter/material.dart';

import '../chat/chat.dart';
import '../services/pip_service.dart';
import '../services/stream_player_controller.dart';
import '../widgets/stream_player_view.dart';
import 'channel_stack.dart';
import 'home_app_bar.dart';

// Shell-owned state the stream layouts read but do not own.
abstract class StreamPanelsHost {
  String? get selectedChannel;
  bool isMounted();
  void markDirty();
  void setStreamState(void Function() fn);
  bool get showInput;
  double get chatFontSize;
  bool get isFullscreen;
  bool get theaterChatVisible;
  void toggleTheaterChat();
  void onChannelChanged(int index);
}

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
    required this.host,
  });

  static const audioBarHeight = 56.0;

  // Clipped-alive video strip when the keyboard hides the picture.
  static const hiddenVideoHeight = 1.0;

  final StreamPlayerController streamPlayer;
  final PipService pipService;
  final Chat chat;
  final ChannelPanels channels;
  final HomeAppBar homeAppBar;
  final StreamPanelsHost host;

  bool _wasTheaterMode = false;
  bool? _lastAutoEnter;
  bool? _lastPipPlaying;

  void toggleStreamForSelected() {
    if (streamPlayer.isActive) {
      host.setStreamState(() => streamPlayer.closeStream());
      return;
    }
    final channel = host.selectedChannel;
    if (channel == null) return;
    host.setStreamState(() => streamPlayer.toggleStream(channel));
  }

  void onStreamPlayerChanged() {
    if (!host.isMounted()) return;
    final enteringTheater = streamPlayer.isTheaterMode && !_wasTheaterMode;
    _wasTheaterMode = streamPlayer.isTheaterMode;
    host.markDirty();
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
    if (host.selectedChannel == channel) return;
    if (!chat.contains(channel)) return;
    host.onChannelChanged(chat.names.indexOf(channel));
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
      chatFontSize: host.chatFontSize,
    );
  }

  Widget playerView(
    String channel, {
    bool fillPane = false,
    bool visible = true,
    bool showControls = true,
  }) {
    final key = streamPlayer.retainWebview ? 'stream' : 'stream:$channel';
    return StreamPlayerView(
      key: ValueKey(key),
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
        Positioned.fill(child: playerView(channel, fillPane: true)),
        if (host.theaterChatVisible)
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: panelW,
            child: ColoredBox(
              color: scheme.surface.withValues(alpha: 0.92),
              child: SafeArea(
                left: false,
                child: channels.channelStack(
                  context,
                  hideChrome: true,
                  overlayTop: 8,
                ),
              ),
            ),
          ),
        Positioned(
          bottom: 16,
          right: host.theaterChatVisible ? panelW + 8 : 8,
          child: FloatingActionButton.small(
            heroTag: 'theater_chat_toggle',
            tooltip: host.theaterChatVisible ? 'Hide chat' : 'Show chat',
            onPressed: host.toggleTheaterChat,
            child: Icon(
              host.theaterChatVisible ? Icons.visibility_off : Icons.visibility,
            ),
          ),
        ),
      ],
    );
  }

  Widget split(BuildContext context, String channel, double maxWidth) {
    var dragFrac = streamPlayer.splitFraction;
    return StatefulBuilder(
      builder: (context, setLocal) {
        return Row(
          children: [
            SizedBox(
              width: maxWidth * dragFrac,
              child: playerView(channel, fillPane: true),
            ),
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (details) => setLocal(() {
                dragFrac = (dragFrac + details.delta.dx / maxWidth).clamp(
                  0.2,
                  0.8,
                );
              }),
              onHorizontalDragEnd: (_) =>
                  streamPlayer.setSplitFraction(dragFrac),
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
              child: channels.channelStack(
                context,
                hideChrome: false,
                overlayTop: 50,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget bodyColumn(
    BuildContext context, {
    required bool hideChromeForKeyboard,
    required double maxWidth,
    required double maxHeight,
    required double keyboardH,
    required double composerH,
  }) {
    final channel = streamPlayer.currentChannel;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    // System PiP window shows the whole activity, so collapse to video-only
    // (DankChat hides appbar/tabs/chat/input the same way).
    if (channel != null && streamPlayer.isInPip) {
      return Column(
        children: [
          Expanded(
            child: playerView(channel, fillPane: true, showControls: false),
          ),
        ],
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
        children: [Expanded(child: split(context, channel, maxWidth))],
      );
    }
    final showVideo =
        channel == null ||
        showStreamVideo(
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          keyboardH: keyboardH,
          inputH: composerH,
        );
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
          duration: hideChromeForKeyboard
              ? Duration.zero
              : const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          child: !host.isFullscreen && !hideChromeForKeyboard
              ? homeAppBar.appBar(context)
              : const SizedBox.shrink(),
        ),
        channels.channelTabs(
          context,
          hideChrome: hideChromeForKeyboard,
          overlayTop: 50 + aboveTabsH,
          belowTabBar: channel == null
              ? null
              : stackedPlayer(channel, showVideo),
        ),
      ],
    );
  }
}
