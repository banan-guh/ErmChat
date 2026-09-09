import 'dart:async';

import 'package:flutter/services.dart';

/// Thin bridge over the `ermchat/pip` MethodChannel (Android system
/// Picture-in-Picture, DankChat pattern: manifest flag + activity params, no
/// plugin). Injectable for tests via [HomeScreen]'s service params: pass a
/// fake that overrides [enterPip] / [setAutoEnter] / [updatePipActions].
class PipService {
  final MethodChannel _channel;

  /// Fired by the host activity when the OS PiP window opens or closes.
  /// Assigning installs the channel handler; clearing both callbacks
  /// removes it. Lazy so the service constructs without a binary
  /// messenger (unit tests).
  ValueChanged<bool>? get onPipChanged => _onPipChanged;
  ValueChanged<bool>? _onPipChanged;
  set onPipChanged(ValueChanged<bool>? value) {
    _onPipChanged = value;
    _syncHandler();
  }

  /// Fired by the host activity when a PiP window action is tapped:
  /// `play`, `pause`, or `audio`. The view consumes these against the player.
  ValueChanged<String>? get onPipAction => _onPipAction;
  ValueChanged<String>? _onPipAction;
  set onPipAction(ValueChanged<String>? value) {
    _onPipAction = value;
    _syncHandler();
  }

  void _syncHandler() {
    if (_onPipChanged == null && _onPipAction == null) {
      _channel.setMethodCallHandler(null);
    } else {
      _channel.setMethodCallHandler(_onMethodCall);
    }
  }

  PipService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('ermchat/pip');

  Future<void> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onPipChanged':
        onPipChanged?.call(call.arguments as bool? ?? false);
      case 'onPipAction':
        final action = call.arguments as String?;
        if (action != null) onPipAction?.call(action);
    }
  }

  /// True on Android 12+ devices with the PiP system feature. False
  /// everywhere else (iOS, older Android, tests without a host).
  Future<bool> isPipSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Arms OS auto-enter on background (Android 12+). No-op elsewhere.
  Future<void> setAutoEnter(bool enabled) async {
    try {
      await _channel.invokeMethod('setAutoEnter', {'enabled': enabled});
    } catch (_) {}
  }

  /// Manual entry for the player overlay button. Returns whether the host
  /// accepted the request; the actual mode change arrives via [onPipChanged].
  Future<bool> enterPip() async {
    try {
      return await _channel.invokeMethod<bool>('enterPip') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Refreshes the PiP window's play/pause action icon to match playback.
  /// No-op elsewhere.
  Future<void> updatePipActions({required bool playing}) async {
    try {
      await _channel.invokeMethod('updateActions', {'playing': playing});
    } catch (_) {}
  }

  void dispose() {
    onPipChanged = null;
    onPipAction = null;
  }
}
