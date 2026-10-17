import 'dart:async';

import 'package:flutter/foundation.dart';

import '../util/prefs.dart';
import 'pip_service.dart';

/// Per-channel Twitch stream player state. Ports DankChat's StreamViewModel:
/// one player instance, `toggleStream` flips per channel, closing on leave.
class StreamPlayerController extends ChangeNotifier {
  /// Platform bridge for system Picture-in-Picture. Set by HomeScreen;
  /// null in contexts without a host (unit tests until faked).
  PipService? pipService;

  String? _currentChannel;
  bool _isAudioOnly = false;
  bool _isTheaterMode = false;
  bool _pipEnabled = false;
  bool _isInPip = false;

  /// Last play state observed from the player page (null until known).
  /// Drives the PiP window's play/pause action icon.
  bool? _pipPlaying;
  bool? get pipPlaying => _pipPlaying;

  /// Action tapped in the PiP window (`play`/`pause`/`audio`), waiting for
  /// the view (which owns the WebView) to consume it. Single slot: the
  /// window only offers one tap at a time in practice.
  String? _pendingPipAction;

  /// Stream share of the side-by-side layout. Starts at 60/40 each launch;
  /// a drag lasts for the session.
  static const defaultSplitFraction = 0.6;
  double _splitFraction = defaultSplitFraction;

  /// Portrait player height as a multiple of its 16:9 height, half to full.
  /// Starts at 1 each launch; a drag lasts for the session.
  double _stackedScale = 1.0;
  int _generation = 0;

  String? get currentChannel => _currentChannel;
  bool get isActive => _currentChannel != null;
  bool get isAudioOnly => _isAudioOnly;
  bool get isTheaterMode => _isTheaterMode;
  bool get isInPip => _isInPip;
  double get splitFraction => _splitFraction;
  double get stackedScale => _stackedScale;
  int get generation => _generation;

  /// PiP eligibility, manual and auto alike: an active video player with PiP
  /// opted in. Audio-only never enters PiP (its audio already plays).
  bool get canPip =>
      isActive && !isAudioOnly && _pipEnabled && pipService != null;

  String? _vodId;
  DateTime? _vodStart;
  Duration _vodAt = Duration.zero;

  /// Whether the player shows a past broadcast instead of the live channel.
  bool get isVod => _vodId != null;

  /// The archive time of the VOD's playback position and its channel, for the
  /// chat to follow; null when no VOD plays.
  final vodPlayback = ValueNotifier<({String channel, DateTime time})?>(null);

  String playerUrl(String channel) {
    final vod = _vodId;
    if (vod != null) {
      final t = _vodAt;
      return 'https://player.twitch.tv/?video=v$vod'
          '&time=${t.inHours}h${t.inMinutes.remainder(60)}m'
          '${t.inSeconds.remainder(60)}s'
          '&enableExtensions=false&muted=false&parent=twitch.tv';
    }
    final encoded = Uri.encodeComponent(channel);
    return 'https://player.twitch.tv/?channel=$encoded'
        '&enableExtensions=false&muted=false&parent=twitch.tv';
  }

  Future<void> loadPrefs() async {
    final prefs = await Prefs.load();
    _pipEnabled = prefs.streamPipEnabled;
    notifyListeners();
  }

  /// Plays video [vodId] of [channel] from [at], whose broadcast began at
  /// [streamStart] on the archive's clock.
  void watchVod(
    String channel,
    String vodId,
    DateTime streamStart, {
    Duration at = Duration.zero,
  }) {
    _vodId = vodId;
    _vodStart = streamStart;
    _vodAt = at;
    _currentChannel = channel;
    _isAudioOnly = false;
    _isTheaterMode = false;
    _isInPip = false;
    onVodPosition(at);
    notifyListeners();
  }

  /// The VOD player reached [position].
  void onVodPosition(Duration position) {
    final start = _vodStart;
    final channel = _currentChannel;
    if (_vodId == null || start == null || channel == null) return;
    vodPlayback.value = (channel: channel, time: start.add(position));
  }

  void _clearVod() {
    _vodId = null;
    _vodStart = null;
    _vodAt = Duration.zero;
    vodPlayback.value = null;
  }

  @override
  void dispose() {
    vodPlayback.dispose();
    super.dispose();
  }

  void toggleStream(String channel) {
    if (_currentChannel == channel && !isVod) {
      closeStream();
      return;
    }
    _clearVod();
    _currentChannel = channel;
    _isAudioOnly = false;
    _isTheaterMode = false;
    _isInPip = false;
    notifyListeners();
  }

  void closeStream() {
    _clearVod();
    _currentChannel = null;
    _isAudioOnly = false;
    _isTheaterMode = false;
    _isInPip = false;
    notifyListeners();
  }

  void toggleAudioOnly() {
    _isAudioOnly = !_isAudioOnly;
    if (_isAudioOnly) _isTheaterMode = false;
    notifyListeners();
  }

  void toggleTheaterMode() {
    _isTheaterMode = !_isTheaterMode;
    notifyListeners();
  }

  void exitTheaterMode() {
    if (!_isTheaterMode) return;
    _isTheaterMode = false;
    notifyListeners();
  }

  void onRenderProcessGone() {
    _generation++;
    notifyListeners();
  }

  void setPipEnabled(bool value) {
    _pipEnabled = value;
    notifyListeners();
  }

  /// Manual PiP entry for the player overlay button. Guards on [canPip];
  /// the actual mode change arrives via [setPipActive] from the host.
  Future<void> enterPip() async {
    if (!canPip) return;
    await pipService?.enterPip();
  }

  /// Host callback when the OS PiP window opens or closes. Entering PiP
  /// exits theater mode (theater is a fullscreen-layout concept).
  void setPipActive(bool value) {
    if (_isInPip == value) return;
    _isInPip = value;
    if (value) _isTheaterMode = false;
    notifyListeners();
  }

  /// Records observed play state; notifies only on flips (icon sync).
  void setPipPlaying(bool value) {
    if (_pipPlaying == value) return;
    _pipPlaying = value;
    notifyListeners();
  }

  /// Queues a PiP window action tap for the view to consume.
  void notifyPipAction(String action) {
    _pendingPipAction = action;
    notifyListeners();
  }

  /// Takes the queued action, if any. No notify: the consumer acts at once.
  String? takePipAction() {
    final action = _pendingPipAction;
    _pendingPipAction = null;
    return action;
  }

  /// Moves the split live during a drag without notifying, so rebuilds
  /// mid-drag read the current position. [setSplitFraction] commits.
  void dragSplitFraction(double value) =>
      _splitFraction = value.clamp(0.2, 0.8);

  void setSplitFraction(double value) {
    _splitFraction = value.clamp(0.2, 0.8);
    notifyListeners();
  }

  /// Portrait counterpart of [dragSplitFraction]; [setStackedScale] commits.
  void dragStackedScale(double value) => _stackedScale = value.clamp(0.5, 1.0);

  void setStackedScale(double value) {
    _stackedScale = value.clamp(0.5, 1.0);
    notifyListeners();
  }
}
