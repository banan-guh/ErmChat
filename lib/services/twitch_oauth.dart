import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import '../twitch_config.dart';
import '../widgets/login_webview.dart';

class TwitchOAuth {
  static const _authorizeUrl = 'https://id.twitch.tv/oauth2/authorize';

  static String? lastError;
  static bool _flowInProgress = false;

  /// Starts the OAuth implicit grant flow via in-app WebView.
  ///
  /// Opens a full-screen WebView with the Twitch authorize page and intercepts
  /// the redirect to extract the access token from the URL fragment.
  /// Returns the access token, or null on failure/timeout.
  static Future<String?> startFlow(BuildContext context) async {
    if (_flowInProgress) {
      lastError = 'An authorization flow is already in progress.';
      return null;
    }

    final urlInfo = generateAuthUrl();
    if (urlInfo == null) return null;

    _flowInProgress = true;
    try {
      return await _openWebView(
        context,
        urlInfo.url,
        urlInfo.state,
        TwitchConfig.redirectUri,
      ).timeout(const Duration(minutes: 5));
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

  /// Generates the Twitch authorization URL with a fresh CSRF state.
  ///
  /// Returns the URL and the expected state, or null if [TwitchConfig.isConfigured] is false.
  static ({String url, String state})? generateAuthUrl() {
    if (!TwitchConfig.isConfigured) return null;

    final state = _randomState();
    final url =
        '$_authorizeUrl'
        '?client_id=${TwitchConfig.clientId}'
        '&redirect_uri=${Uri.encodeQueryComponent(TwitchConfig.redirectUri)}'
        '&response_type=token'
        '&scope=chat:read%20chat:edit%20user:read:chat%20user:write:chat%20user:manage:chat_color%20channel:moderate%20moderator:manage:banned_users%20moderator:manage:chat_messages%20moderator:manage:announcements%20moderator:manage:shoutouts%20user:read:emotes'
        '&state=$state'
        '&force_verify=true';
    return (url: url, state: state);
  }

  static Future<String?> _openWebView(
    BuildContext context,
    String authUrl,
    String expectedState,
    String redirectUri,
  ) {
    final completer = Completer<String?>();

    Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => LoginWebView(
          authUrl: authUrl,
          expectedState: expectedState,
          redirectUri: redirectUri,
          onTokenResult: (token, {error}) {
            if (error != null) lastError = error;
            if (!completer.isCompleted) completer.complete(token);
          },
        ),
      ),
    ).then((_) {
      // Failsafe: if the route is popped without passing a token
      // (e.g. system back button), complete so the caller doesn't hang.
      if (!completer.isCompleted) completer.complete(null);
    });

    return completer.future;
  }

  static String _randomState() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Parses the fragment portion of a URL into key-value pairs.
  ///
  /// Used to extract OAuth params from the redirect URL fragment, e.g.:
  /// `https://example.com/callback#access_token=xxx&state=yyy`
  static Map<String, String?> parseFragment(String url) {
    final uri = Uri.parse(url);
    final fragment = uri.fragment;
    if (fragment.isEmpty) return {};
    return Uri.splitQueryString(fragment);
  }
}
