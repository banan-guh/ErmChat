import 'dart:async';

import 'package:flutter/services.dart';

import '../irc/transport/read.dart';
import '../util/log.dart';

/// iOS mention push through the chat proxy. iOS ends the socket soon after
/// the app leaves the screen, so the proxy holds the APNs device token and
/// pushes mentions itself. The native half is AppDelegate.swift.
class ApnsPush {
  ApnsPush({required this.ircRead, required this.active}) {
    if (active) _channel.setMethodCallHandler(_onCall);
  }

  final IrcReadService ircRead;

  /// iOS with the proxy on; everything here no-ops otherwise.
  final bool active;
  static const _channel = MethodChannel('ermchat/apns');
  final _taps = StreamController<String>.broadcast();
  String? _token;

  /// Channels whose pushed mention the user tapped.
  Stream<String> get onTap => _taps.stream;

  Future<void> _onCall(MethodCall call) async {
    final channel = call.arguments;
    if (call.method == 'tap' && channel is String && channel.isNotEmpty) {
      _taps.add(channel);
    }
  }

  /// The channel whose pushed mention launched the app, once.
  Future<String?> takeLaunchChannel() async {
    if (!active) return null;
    try {
      return await _channel.invokeMethod<String>('takeLaunchChannel');
    } on PlatformException catch (e) {
      logDebug('APNs launch channel: $e');
      return null;
    }
  }

  /// Turns push on (asking for permission) or off on the proxy. Off still
  /// fetches the token, so a device registered last session is removed.
  Future<void> sync({required bool push}) async {
    if (!active) return;
    final token = await _deviceToken(prompt: push);
    if (token == null) return;
    if (push) {
      ircRead.proxyHello = () => ['REGISTER apns $token'];
      ircRead.sendToProxy('REGISTER apns $token');
    } else {
      ircRead.proxyHello = null;
      ircRead.sendToProxy('UNREGISTER apns $token');
    }
  }

  Future<String?> _deviceToken({required bool prompt}) async {
    if (_token != null) return _token;
    try {
      _token = await _channel.invokeMethod<String>('token', {'prompt': prompt});
    } on PlatformException catch (e) {
      logDebug('APNs token: $e');
    }
    return _token;
  }

  void dispose() {
    if (active) _channel.setMethodCallHandler(null);
    _taps.close();
  }
}
