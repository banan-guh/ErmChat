import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-channel Twitch stream player state. Ports DankChat's StreamViewModel:
/// one player instance, `toggleStream` flips per channel, closing on leave.
class StreamPlayerController extends ChangeNotifier {
  static const showExtensionsKey = 'stream_show_extensions';
  static const retainWebviewKey = 'stream_retain_webview';
  static const splitFractionKey = 'stream_split_fraction';

  String? _currentChannel;
  bool _isAudioOnly = false;
  bool _isTheaterMode = false;
  bool _showExtensions = false;
  bool _retainWebview = true;
  double _splitFraction = 0.5;
  int _generation = 0;
  bool hasEverAttached = false;

  String? get currentChannel => _currentChannel;
  bool get isActive => _currentChannel != null;
  bool get isAudioOnly => _isAudioOnly;
  bool get isTheaterMode => _isTheaterMode;
  bool get showExtensions => _showExtensions;
  bool get retainWebview => _retainWebview;
  double get splitFraction => _splitFraction;
  int get generation => _generation;

  String playerUrl(String channel) {
    final encoded = Uri.encodeComponent(channel);
    return 'https://player.twitch.tv/?channel=$encoded'
        '&enableExtensions=$_showExtensions&muted=false&parent=twitch.tv';
  }

  Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _showExtensions = prefs.getBool(showExtensionsKey) ?? false;
    _retainWebview = prefs.getBool(retainWebviewKey) ?? true;
    _splitFraction = (prefs.getDouble(splitFractionKey) ?? 0.5).clamp(0.2, 0.8);
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
    notifyListeners();
  }

  void closeStream() {
    _currentChannel = null;
    _isAudioOnly = false;
    _isTheaterMode = false;
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

  void setSplitFraction(double value) {
    _splitFraction = value.clamp(0.2, 0.8);
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setDouble(splitFractionKey, _splitFraction),
      ),
    );
    notifyListeners();
  }
}
