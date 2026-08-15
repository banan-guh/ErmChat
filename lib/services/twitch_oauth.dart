import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import '../twitch_config.dart';

/// A function that starts the OAuth flow and resolves with the access token
/// on success or null on failure/cancel. Defined here so both the settings
/// and account screens can inject a mocked flow without importing each other.
typedef OAuthStarter = Future<String?> Function();

class TwitchOAuth {
  static const _authorizeUrl = 'https://id.twitch.tv/oauth2/authorize';
  static const _channel = MethodChannel('ermchat/oauth');

  static String? lastError;
  static bool _flowInProgress = false;

  /// Starts the OAuth flow. Set [ephemeral] to launch the login in an
  /// incognito-style session with no shared cookies. That skips Twitch's
  /// "hi again, [user] - not you? log out" interstitial (which can hand the
  /// flow off to the installed Twitch app via Android App Links) and shows the
  /// plain login form instead - used for the switch-account / re-auth path.
  /// On Android this is a no-op: the session-bound Custom Tab already keeps
  /// every navigation inside the tab regardless of cookies.
  static Future<String?> startFlow({bool ephemeral = false}) async {
    lastError = null;
    if (_flowInProgress) {
      lastError = 'An authorization flow is already in progress.';
      return null;
    }

    final urlInfo = generateAuthUrl();
    if (urlInfo == null) return null;

    _flowInProgress = true;
    try {
      final result = Platform.isAndroid
          ? await _authenticateAndroid(urlInfo.url)
          : await FlutterWebAuth2.authenticate(
              url: urlInfo.url,
              callbackUrlScheme: TwitchConfig.callbackUrlScheme,
              options: FlutterWebAuth2Options(preferEphemeral: ephemeral),
            ).timeout(const Duration(minutes: 5));

      return _extractToken(result, urlInfo.state);
    } on TimeoutException {
      lastError = 'Authorization timed out.';
      return null;
    } catch (e) {
      lastError = 'Authorization failed: $e';
      return null;
    } finally {
      _flowInProgress = false;
    }
  }

  // Android: the native side (MainActivity) launches the auth URL in a
  // session-bound Custom Tab so nothing inside it can hand off to a verified
  // native app, and delivers the redirect back via MainActivity.onNewIntent.
  static Future<String> _authenticateAndroid(String url) {
    final completer = Completer<String>();
    Timer? timeoutTimer;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onRedirect' && !completer.isCompleted) {
        timeoutTimer?.cancel();
        completer.complete(call.arguments as String);
      }
    });

    timeoutTimer = Timer(const Duration(minutes: 5), () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('Authorization timed out.'));
      }
    });

    unawaited(_channel.invokeMethod('launchCustomTab', {'url': url}));
    return completer.future;
  }

  static ({String url, String state})? generateAuthUrl() {
    if (!TwitchConfig.isConfigured) return null;

    final state = _randomState();
    final url =
        '$_authorizeUrl'
        '?client_id=${TwitchConfig.clientId}'
        '&redirect_uri=${Uri.encodeQueryComponent(TwitchConfig.redirectUri)}'
        '&response_type=token'
        '&scope=chat:read%20chat:edit%20user:write:chat%20user:manage:chat_color%20moderator:manage:banned_users%20moderator:manage:chat_messages%20moderator:manage:announcements%20moderator:manage:shoutouts%20moderator:read:blocked_terms%20moderator:read:chat_settings%20moderator:read:unban_requests%20moderator:read:warnings%20moderator:read:moderators%20moderator:read:vips%20user:manage:blocked_users%20user:read:blocked_users%20moderator:manage:chat_settings%20channel:manage:moderators%20channel:manage:vips%20channel:edit:commercial%20channel:manage:raids%20moderator:manage:shield_mode%20channel:manage:broadcast%20user:manage:whispers%20channel:read:hype_train%20channel:read:polls%20channel:read:predictions'
        '&state=$state'
        '&force_verify=true';
    return (url: url, state: state);
  }

  static String? _extractToken(String resultUrl, String expectedState) {
    final params = parseFragment(resultUrl);
    final error = params['error'];
    final token = params['access_token'];
    final state = params['state'];

    if (error != null) {
      lastError = 'Twitch returned: $error';
      return null;
    }

    if (token != null) {
      if (state != expectedState) {
        lastError = 'CSRF: state mismatch';
        return null;
      }
      return token;
    }

    lastError = 'No token in response.';
    return null;
  }

  static String _randomState() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static Map<String, String?> parseFragment(String url) {
    final uri = Uri.parse(url);
    final fragment = uri.fragment;
    if (fragment.isEmpty) return {};
    return Uri.splitQueryString(fragment);
  }
}
