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
  bool _showExtensions = false;
  bool _retainWebview = true;
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
  double _splitFraction = 0.5;
  int _generation = 0;
  bool hasEverAttached = false;

  String? get currentChannel => _currentChannel;
  bool get isActive => _currentChannel != null;
  bool get isAudioOnly => _isAudioOnly;
  bool get isTheaterMode => _isTheaterMode;
  bool get showExtensions => _showExtensions;
  bool get retainWebview => _retainWebview;
  bool get pipEnabled => _pipEnabled;
  bool get isInPip => _isInPip;
  double get splitFraction => _splitFraction;
  int get generation => _generation;

  /// PiP eligibility, manual and auto alike: an active video player with PiP
  /// opted in. Audio-only never enters PiP (its audio already plays), and a
  /// non-retained WebView would blank the window on channel switches.
  bool get canPip =>
      isActive &&
      !isAudioOnly &&
      _pipEnabled &&
      _retainWebview &&
      pipService != null;

  String playerUrl(String channel) {
    final encoded = Uri.encodeComponent(channel);
    return 'https://player.twitch.tv/?channel=$encoded'
        '&enableExtensions=$_showExtensions&muted=false&parent=twitch.tv';
  }

  Future<void> loadPrefs() async {
    final prefs = await Prefs.load();
    _showExtensions = prefs.streamShowExtensions;
    _retainWebview = prefs.streamRetainWebview;
    _pipEnabled = prefs.streamPipEnabled;
    _splitFraction = prefs.streamSplitFraction.clamp(0.2, 0.8);
    notifyListeners();
  }

  void toggleStream(String channel) {
    if (_currentChannel == channel) {
      closeStream();
      return;
    }
    _currentChannel = channel;
    _isAudioOnly = false;
    _isTheaterMode = false;
    _isInPip = false;
    notifyListeners();
  }

  void closeStream() {
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
    hasEverAttached = false;
    notifyListeners();
  }

  void setShowExtensions(bool value) {
    _showExtensions = value;
    notifyListeners();
  }

  void setRetainWebview(bool value) {
    _retainWebview = value;
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

  void setSplitFraction(double value) {
    _splitFraction = value.clamp(0.2, 0.8);
    unawaited(
      Prefs.load().then(
        (prefs) => prefs.setStreamSplitFraction(_splitFraction),
      ),
    );
    notifyListeners();
  }
}
