import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../services/stream_player_controller.dart';

const _blankUrl = 'about:blank';

const _allowedPrefixes = [
  _blankUrl,
  'https://id.twitch.tv/',
  'https://www.twitch.tv/passport-callback',
  'https://player.twitch.tv/',
];

class StreamPlayerView extends StatefulWidget {
  final StreamPlayerController controller;
  final String channel;
  final bool fillPane;
  final bool visible;

  const StreamPlayerView({
    super.key,
    required this.controller,
    required this.channel,
    this.fillPane = false,
    this.visible = true,
  });

  @override
  State<StreamPlayerView> createState() => _StreamPlayerViewState();
}

class _StreamPlayerViewState extends State<StreamPlayerView> {
  late final WebViewController _webController;
  bool _pageLoaded = false;
  String? _error;
  String? _lastUrl;
  int _lastGeneration = -1;
  Timer? _resumeTimer;
  Timer? _overlayTimer;
  bool _overlayVisible = false;

  @override
  void initState() {
    super.initState();
    _webController =
        WebViewController.fromPlatformCreationParams(_creationParams())
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(Colors.transparent)
          ..setNavigationDelegate(
            NavigationDelegate(
              onNavigationRequest: _onNavigationRequest,
              onPageFinished: (_) {
                widget.controller.hasEverAttached = true;
                if (mounted) {
                  setState(() => _pageLoaded = true);
                  _revealOverlay();
                }
              },
              onWebResourceError: (error) {
                if (error.isForMainFrame != true) return;
                if (mounted) setState(() => _error = error.description);
              },
            ),
          );
    unawaited(_applyPlatformFlags());
    _reload();
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _overlayTimer?.cancel();
    super.dispose();
  }

  PlatformWebViewControllerCreationParams _creationParams() {
    final platform = WebViewPlatform.instance;
    if (platform is WebKitWebViewPlatform) {
      return WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const {},
      );
    }
    return const PlatformWebViewControllerCreationParams();
  }

  Future<void> _applyPlatformFlags() async {
    final platform = _webController.platform;
    if (platform is AndroidWebViewController) {
      await platform.setMediaPlaybackRequiresUserGesture(false);
    }
  }

  void _revealOverlay() {
    _overlayTimer?.cancel();
    setState(() => _overlayVisible = true);
    _overlayTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _overlayVisible = false);
    });
  }

  void _reload() {
    _lastUrl = widget.controller.playerUrl(widget.channel);
    _lastGeneration = widget.controller.generation;
    setState(() {
      _pageLoaded = false;
      _error = null;
    });
    unawaited(_webController.loadRequest(Uri.parse(_lastUrl!)));
  }

  @override
  void didUpdateWidget(StreamPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final url = widget.controller.playerUrl(widget.channel);
    if (widget.channel != oldWidget.channel ||
        url != _lastUrl ||
        widget.controller.generation != _lastGeneration) {
      _reload();
    }
    // Resuming a hidden player: the web player pauses on detach.
    if (widget.visible && !oldWidget.visible && _pageLoaded) {
      _resumeTimer?.cancel();
      _resumeTimer = Timer(const Duration(milliseconds: 100), () {
        if (!mounted) return;
        unawaited(
          _webController.runJavaScript(
            "document.querySelector('video')?.play()",
          ),
        );
      });
    }
  }

  Future<NavigationDecision> _onNavigationRequest(
    NavigationRequest request,
  ) async {
    if (_allowedPrefixes.any(request.url.startsWith)) {
      return NavigationDecision.navigate;
    }
    try {
      unawaited(
        launchUrl(Uri.parse(request.url), mode: LaunchMode.externalApplication),
      );
    } catch (_) {}
    return NavigationDecision.prevent;
  }

  @override
  Widget build(BuildContext context) {
    final framed = widget.fillPane
        ? SizedBox.expand(child: WebViewWidget(controller: _webController))
        : AspectRatio(
            aspectRatio: 16 / 9,
            child: WebViewWidget(controller: _webController),
          );
    return Stack(
      children: [
        framed,
        if (_error != null) _buildErrorOverlay(),
        if (_pageLoaded && _error == null && _overlayVisible) _buildOverlay(),
        if (_pageLoaded && _error == null && !_overlayVisible)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _revealOverlay,
              child: const SizedBox.expand(),
            ),
          ),
      ],
    );
  }

  Widget _buildErrorOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: Center(
          child: TextButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text('Reload stream'),
            onPressed: () {
              widget.controller.onRenderProcessGone();
              _reload();
            },
          ),
        ),
      ),
    );
  }

  Widget _buildOverlay() {
    final controller = widget.controller;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return Positioned(
      top: 0,
      right: 0,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _overlayButton(
              icon: controller.isAudioOnly ? Icons.videocam : Icons.headphones,
              tooltip: controller.isAudioOnly ? 'Show video' : 'Audio only',
              onPressed: controller.toggleAudioOnly,
            ),
            const SizedBox(width: 6),
            if (landscape)
              _overlayButton(
                icon: controller.isTheaterMode
                    ? Icons.fullscreen_exit
                    : Icons.fullscreen,
                tooltip: controller.isTheaterMode
                    ? 'Exit theater'
                    : 'Theater mode',
                onPressed: controller.toggleTheaterMode,
              ),
            if (landscape) const SizedBox(width: 6),
            _overlayButton(
              icon: Icons.close,
              tooltip: 'Close stream',
              onPressed: controller.closeStream,
            ),
          ],
        ),
      ),
    );
  }

  Widget _overlayButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.75),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, size: 20),
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          minimumSize: const Size(34, 34),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}

class StreamAudioBar extends StatelessWidget {
  final StreamPlayerController controller;
  final String channel;

  const StreamAudioBar({
    super.key,
    required this.controller,
    required this.channel,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            const Icon(Icons.headphones, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Audio: $channel',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.videocam, size: 20),
              tooltip: 'Show video',
              onPressed: controller.toggleAudioOnly,
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              tooltip: 'Close stream',
              onPressed: controller.closeStream,
            ),
          ],
        ),
      ),
    );
  }
}
