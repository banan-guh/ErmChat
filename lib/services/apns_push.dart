import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/ping_rule.dart';
import '../util/log.dart';

/// What a push registration carries: the Twitch token that proves whose
/// mentions these are, and the rules ([ApnsPush.rules]). Null when logged
/// out, which has no mentions to push.
typedef PushRegistration = ({String token, Map<String, Object?> rules});

/// iOS mention push through ermchat-notify. iOS ends the app's sockets
/// soon after it leaves the screen, so the server holds the APNs device
/// token, watches the user's channels and pushes mentions itself. The
/// native half is AppDelegate.swift.
class ApnsPush {
  ApnsPush({
    required this.active,
    required this.endpoint,
    required this.registration,
    http.Client? client,
  }) : _client = client ?? http.Client() {
    if (active) _channel.setMethodCallHandler(_onCall);
  }

  /// iOS with a push server; everything here no-ops otherwise.
  final bool active;
  final String endpoint;
  final Future<PushRegistration?> Function() registration;
  final http.Client _client;

  static const _channel = MethodChannel('ermchat/apns');
  static const _settle = Duration(seconds: 2);
  final _taps = StreamController<String>.broadcast();
  String? _token;
  bool _prompted = false;
  bool _push = false;
  Timer? _refresh;

  // The last registration the server took, so an unchanged one is skipped.
  String? _sent;

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

  /// Turns push on (asking for permission) or off on the server. Off still
  /// fetches the token, so a device registered last session is removed.
  Future<void> sync({required bool push}) async {
    _push = push;
    if (!active) return;
    final device = await _deviceToken(prompt: push);
    if (device == null) return;
    if (!push) {
      _sent = null;
      await _post('unregister', {'device': device});
      return;
    }
    final reg = await registration();
    if (reg == null || !_push) return;
    final body = jsonEncode({'device': device, ...reg.rules});
    if (body == _sent) return;
    if (await _post('register', body, token: reg.token)) _sent = body;
  }

  /// Sends the registration again once its inputs settle, when push is on.
  void refresh() {
    if (!active || !_push) return;
    _refresh?.cancel();
    _refresh = Timer(_settle, () => unawaited(sync(push: true)));
  }

  Future<bool> _post(String path, Object body, {String? token}) async {
    try {
      final response = await _client.post(
        Uri.parse('$endpoint/$path'),
        headers: {
          'content-type': 'application/json',
          if (token != null) 'authorization': 'Bearer $token',
        },
        body: body is String ? body : jsonEncode(body),
      );
      if (response.statusCode == 204) return true;
      logDebug('push $path: ${response.statusCode} ${response.body}');
    } catch (e) {
      logDebug('push $path: $e');
    }
    return false;
  }

  Future<String?> _deviceToken({required bool prompt}) async {
    // A token fetched without asking leaves the permission prompt owed, so
    // the first asking call must reach iOS even with the token cached.
    if (_token != null && (!prompt || _prompted)) return _token;
    try {
      final token = await _channel.invokeMethod<String>('token', {
        'prompt': prompt,
      });
      if (prompt) _prompted = true;
      _token = token ?? _token;
    } on PlatformException catch (e) {
      logDebug('APNs token: $e');
    }
    return _token;
  }

  /// The server's copy of the highlight rules that notify: the name,
  /// reply and thread builtins, keyword and user rules, and every sender
  /// the app hides (blacklist rules, blocked and plainly ignored users;
  /// regex ignores stay on the phone).
  static Map<String, Object?> rules({
    required List<PingRule> pingRules,
    required Iterable<String> channels,
    required String? displayName,
    required Iterable<String> blocked,
    DateTime? pausedUntil,
  }) {
    bool notifies(PingRule r) => r.enabled && r.notify && r.mention;
    bool builtin(String type) => pingRules.any(
      (r) => r.kind == PingRuleKind.message && r.type == type && notifies(r),
    );
    return {
      'display': displayName ?? '',
      'channels': [...channels],
      'name': builtin('username'),
      'replies': builtin('reply'),
      'threads': builtin('thread'),
      'words': [
        for (final r in pingRules)
          if (r.kind == PingRuleKind.message &&
              r.type == 'custom' &&
              notifies(r) &&
              r.pattern.isNotEmpty)
            {'pattern': r.pattern, 'wholeWord': r.wordBoundary},
      ],
      'users': [
        for (final r in pingRules)
          if (r.kind == PingRuleKind.user &&
              notifies(r) &&
              r.pattern.isNotEmpty)
            r.pattern.toLowerCase(),
      ],
      'blocked': {
        for (final r in pingRules)
          if (r.kind == PingRuleKind.blacklist &&
              r.enabled &&
              r.pattern.isNotEmpty)
            r.pattern.toLowerCase(),
        for (final login in blocked) login.toLowerCase(),
      }.toList(),
      'pausedUntil': (pausedUntil?.millisecondsSinceEpoch ?? 0) ~/ 1000,
    };
  }

  void dispose() {
    _refresh?.cancel();
    if (active) _channel.setMethodCallHandler(null);
    _taps.close();
    _client.close();
  }
}
