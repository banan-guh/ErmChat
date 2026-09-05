import 'package:flutter/material.dart';

import '../composer/composer_bar.dart';
import '../services/chat_store.dart';
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

// Stream player layouts (stacked/theater/split), the body column router,
// and the stream toggle/player-changed verbs.
class StreamPanels {
  StreamPanels({
    required this.streamPlayer,
    required this.chatStore,
    required this.channels,
    required this.homeAppBar,
    required this.host,
  });

  static const audioBarHeight = 56.0;

  final StreamPlayerController streamPlayer;
  final ChatStore chatStore;
  final ChannelPanels channels;
  final HomeAppBar homeAppBar;
  final StreamPanelsHost host;

  bool _wasTheaterMode = false;

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
    if (!enteringTheater) return;
    final channel = streamPlayer.currentChannel;
    if (channel == null) return;
    if (host.selectedChannel == channel) return;
    if (!chatStore.channels.contains(channel)) return;
    host.onChannelChanged(chatStore.channels.indexOf(channel));
  }

  // DankChat shouldShowStream: hide video when the keyboard leaves under
  // 9 chat lines; audio keeps playing.
  bool showStreamVideo({
    required double maxWidth,
    required double maxHeight,
    required double keyboardH,
  }) {
    if (keyboardH <= 0) return true;
    final inputH = host.showInput
        ? (inputBarKey.currentContext?.size?.height ?? 56)
        : 0;
    final streamH = maxWidth * 9 / 16;
    return maxHeight - keyboardH - streamH - inputH >= host.chatFontSize * 9;
  }

  Widget playerView(
    String channel, {
    bool fillPane = false,
    bool visible = true,
  }) {
    final key = streamPlayer.retainWebview ? 'stream' : 'stream:$channel';
    return StreamPlayerView(
      key: ValueKey(key),
      controller: streamPlayer,
      channel: channel,
      fillPane: fillPane,
      visible: visible,
    );
  }

  Widget stackedPlayer(String channel, bool showVideo) {
    final show = showVideo && !streamPlayer.isAudioOnly;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Visibility(
          visible: show,
          maintainState: true,
          maintainAnimation: true,
          child: playerView(channel, visible: show),
        ),
        if (!show)
          StreamAudioBar(
            key: ValueKey('audio:$channel'),
            controller: streamPlayer,
            channel: channel,
          ),
      ],
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
  }) {
    final channel = streamPlayer.currentChannel;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
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
        );
    final showPlayerVideo =
        showVideo && channel != null && !streamPlayer.isAudioOnly;
    final aboveTabsH = channel == null
        ? 0.0
        : showPlayerVideo
        ? maxWidth * 9 / 16
        : audioBarHeight;
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
