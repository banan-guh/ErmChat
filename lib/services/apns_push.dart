import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/ping_rule.dart';
import '../util/constants.dart' show httpTimeout;
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
    this.ready,
    this.tokenProvider,
    http.Client? client,
    Duration? tokenTimeout,
    Duration? requestTimeout,
    this.retryDelays = const [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
    ],
  }) : _client = client ?? http.Client(),
       _tokenTimeout = tokenTimeout ?? const Duration(seconds: 10),
       _requestTimeout = requestTimeout ?? httpTimeout {
    if (active) _channel.setMethodCallHandler(_onCall);
  }

  /// iOS with a push server; everything here no-ops otherwise.
  final bool active;
  final String endpoint;
  final Future<PushRegistration?> Function() registration;
  final Future<void> Function()? ready;
  final Future<String?> Function(bool prompt)? tokenProvider;
  final http.Client _client;
  final Duration _tokenTimeout;
  final Duration _requestTimeout;
  final List<Duration> retryDelays;

  static const _channel = MethodChannel('ermchat/apns');
  static const _settle = Duration(seconds: 2);
  final _taps = StreamController<String>.broadcast();
  String? _token;
  String? _rotatedFrom;
  bool _prompted = false;
  bool _push = false;
  bool _disposed = false;
  int _generation = 0;
  Future<void> _queue = Future<void>.value();
  Timer? _refresh;

  // Identity belongs in the cache key: two accounts can have identical rules.
  ({String device, String token, String body})? _sent;
  bool _clearBeforeRegister = false;

  /// Channels whose pushed mention the user tapped.
  Stream<String> get onTap => _taps.stream;

  /// Whether iOS Settings denies alerts while push is on. iOS asks only
  /// once, so only the Settings app can undo it.
  final blocked = ValueNotifier(false);

  /// Whether the latest desired registration could not be applied.
  final failed = ValueNotifier(false);

  Future<void> _onCall(MethodCall call) async {
    final args = call.arguments;
    if (call.method == 'tap' && args is String && args.isNotEmpty) {
      _taps.add(args);
    } else if (call.method == 'token' && args is Map) {
      final token = args['token'];
      final previous = args['previous'];
      if (token is String && token.isNotEmpty) {
        _tokenRotated(
          token,
          previous is String && previous.isNotEmpty ? previous : null,
        );
      }
    } else if (call.method == 'tokenError') {
      _token = null;
      if (_push) failed.value = true;
    }
  }

  void _tokenRotated(String token, String? previous) {
    if (previous != null && previous != token) _rotatedFrom = previous;
    if (_token == token) return;
    _token = token;
    if (_push) {
      unawaited(sync(push: true));
    } else if (failed.value) {
      unawaited(sync(push: false));
    }
  }

  /// The channel whose pushed mention launched the app. Remains available
  /// until [clearLaunchChannel] after the channel list has restored.
  Future<String?> launchChannel() async {
    if (!active) return null;
    try {
      return await _channel.invokeMethod<String>('launchChannel');
    } on PlatformException catch (e) {
      logDebug('APNs launch channel: $e');
      return null;
    }
  }

  Future<void> clearLaunchChannel() async {
    if (!active) return;
    try {
      await _channel.invokeMethod<void>('clearLaunchChannel');
    } on PlatformException catch (e) {
      logDebug('APNs clear launch channel: $e');
    }
  }

  /// Turns push on (asking for permission) or off on the server. Off still
  /// fetches the token, so a device registered last session is removed.
  /// Calls are serialized and only the latest desired state may commit.
  Future<void> sync({required bool push}) async {
    _push = push;
    if (!active) return;
    final generation = ++_generation;
    final result = _queue.then((_) => _sync(push, generation));
    _queue = result.then((_) {}, onError: (Object _) {});
    await result;
  }

  Future<void> _sync(bool push, int generation) async {
    bool current() => !_disposed && generation == _generation;
    try {
      final device = await _deviceToken(prompt: push);
      if (!current()) return;
      blocked.value = push && await _denied();
      if (!current()) return;
      if (device == null) {
        failed.value = true;
        return;
      }
      final rotated = _rotatedFrom;
      if (!push) {
        _sent = null;
        final devices = {device, ?rotated};
        var ok = true;
        for (final item in devices) {
          if (!current()) return;
          final success = await _post('unregister', {
            'device': item,
          }, current: current);
          if (success && item == rotated) _rotatedFrom = null;
          if (!success) ok = false;
        }
        failed.value = !ok;
        if (ok) _clearBeforeRegister = false;
        return;
      }

      await ready?.call();
      if (!current()) return;
      final reg = await registration();
      if (!current()) return;
      if (reg == null) {
        _sent = null;
        final ok = await _post('unregister', {
          'device': device,
        }, current: current);
        if (ok) _clearBeforeRegister = false;
        failed.value = current() && !ok;
        return;
      }

      final body = jsonEncode({'device': device, ...reg.rules});
      final sent = _sent;
      if (rotated == null &&
          sent != null &&
          sent.device == device &&
          sent.token == reg.token &&
          sent.body == body) {
        failed.value = false;
        return;
      }

      // Fail closed on an account change: remove the old binding before
      // attempting the new one, so a failed register cannot keep pushing A.
      if (sent != null && sent.token != reg.token) {
        _sent = null;
        _clearBeforeRegister = true;
      }
      if (_clearBeforeRegister) {
        final ok = await _post('unregister', {
          'device': device,
        }, current: current);
        if (ok) _clearBeforeRegister = false;
      }
      if (rotated != null && rotated != device) {
        final ok = await _post('unregister', {
          'device': rotated,
        }, current: current);
        if (ok) _rotatedFrom = null;
      }
      if (!current()) return;
      if (await _post('register', body, token: reg.token, current: current)) {
        _sent = (device: device, token: reg.token, body: body);
        _clearBeforeRegister = false;
        failed.value = false;
      } else {
        failed.value = current();
      }
    } catch (e) {
      logDebug('push sync: $e');
      if (current()) failed.value = true;
    }
  }

  /// Sends the registration again once its inputs settle, when push is on.
  void refresh() {
    if (!active || !_push) return;
    _refresh?.cancel();
    _refresh = Timer(_settle, () => unawaited(sync(push: true)));
  }

  /// Registers again even if unchanged: iOS resumes the app instead of
  /// relaunching it, and the server forgets devices on restart and after a
  /// week of silence. Also rereads [blocked].
  void resumed() {
    if (!active || (!_push && !failed.value)) return;
    _sent = null;
    unawaited(sync(push: _push));
  }

  /// Retries the latest desired state after connectivity returns.
  void retry() {
    if (!active || (!_push && !failed.value)) return;
    unawaited(sync(push: _push));
  }

  /// Opens this app's page in iOS Settings, where [blocked] is undone.
  Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<void>('openSettings');
    } on PlatformException catch (e) {
      logDebug('APNs settings: $e');
    }
  }

  /// Removes delivered mentions when the active account changes.
  Future<void> clearNotifications() async {
    if (!active) return;
    try {
      await _channel.invokeMethod<void>('clearNotifications');
    } on PlatformException catch (e) {
      logDebug('APNs clear notifications: $e');
    }
  }

  Future<bool> _denied() async {
    try {
      return await _channel.invokeMethod<bool>('blocked') ?? false;
    } on PlatformException catch (e) {
      logDebug('APNs blocked: $e');
      return false;
    }
  }

  Future<bool> _post(
    String path,
    Object body, {
    String? token,
    required bool Function() current,
  }) async {
    for (var attempt = 0; ; attempt++) {
      if (!current()) return false;
      try {
        final response = await _client
            .post(
              Uri.parse('$endpoint/$path'),
              headers: {
                'content-type': 'application/json',
                if (token != null) 'authorization': 'Bearer $token',
              },
              body: body is String ? body : jsonEncode(body),
            )
            .timeout(_requestTimeout);
        if (response.statusCode == 204) return true;
        final transient =
            response.statusCode == 408 ||
            response.statusCode == 429 ||
            response.statusCode >= 500;
        if (!transient || attempt >= retryDelays.length) {
          logDebug('push $path: ${response.statusCode} ${response.body}');
          return false;
        }
      } catch (e) {
        if (attempt >= retryDelays.length) {
          logDebug('push $path: $e');
          return false;
        }
      }
      await Future<void>.delayed(retryDelays[attempt]);
    }
  }

  Future<String?> _deviceToken({required bool prompt}) async {
    // A token fetched without asking leaves the permission prompt owed, so
    // the first asking call must reach iOS even with the token cached.
    if (_token != null && (!prompt || _prompted)) return _token;
    try {
      final Future<String?> pending = tokenProvider != null
          ? tokenProvider!(prompt)
          : _channel.invokeMethod<String>('token', {'prompt': prompt});
      final token = await pending.timeout(_tokenTimeout);
      if (prompt) _prompted = true;
      // A failed native registration must not upload a cached stale token.
      _token = token == null || token.isEmpty ? null : token;
    } on PlatformException catch (e) {
      _token = null;
      logDebug('APNs token: $e');
    } on TimeoutException {
      _token = null;
      logDebug('APNs token: timed out');
    } on MissingPluginException {
      _token = null;
      logDebug('APNs token: unavailable');
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
    _disposed = true;
    _generation++;
    _refresh?.cancel();
    blocked.dispose();
    failed.dispose();
    if (active) _channel.setMethodCallHandler(null);
    _taps.close();
    _client.close();
  }
}
