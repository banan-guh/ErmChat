import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import '../l10n/l10n.dart';
import '../twitch_config.dart';

/// A function that starts the OAuth flow and resolves with the access token
/// on success or null on failure/cancel. Defined here so both the settings
/// and account screens can inject a mocked flow without importing each other.
typedef OAuthStarter = Future<String?> Function();

class TwitchOAuth {
  static const _authorizeUrl = 'https://id.twitch.tv/oauth2/authorize';
  static const _channel = MethodChannel('ermchat/oauth');

  /// Every scope a fresh login grants. Single source of truth for the auth
  /// URL; [missingScopes] diffs it against validate output for the re-auth
  /// prompt. Add future scopes here so old grants are detected, not silent.
  static const List<String> requiredScopes = [
    'chat:read',
    'chat:edit',
    'user:write:chat',
    'user:manage:chat_color',
    'moderator:manage:banned_users',
    'moderator:manage:chat_messages',
    'moderator:manage:announcements',
    'moderator:manage:shoutouts',
    'moderator:manage:warnings',
    'moderator:read:moderators',
    'moderator:read:vips',
    'user:manage:blocked_users',
    'user:read:blocked_users',
    'moderator:manage:chat_settings',
    'channel:manage:moderators',
    'channel:manage:vips',
    'channel:edit:commercial',
    'channel:manage:raids',
    'moderator:manage:shield_mode',
    'channel:manage:broadcast',
    'user:manage:whispers',
    'channel:read:hype_train',
    'channel:read:polls',
    'channel:read:predictions',
    'channel:manage:polls',
    'channel:manage:predictions',
    // EventSub channel.moderate v2 requires these:
    'moderator:read:blocked_terms',
    'moderator:read:unban_requests',
    // AutoMod queue (hold/update subs + allow/deny) needs manage.
    'moderator:manage:automod',
    // Tier 3 mod view: inbox, terms, warnings log, automod editor,
    // suspicious users, chatters/followers, moderated-channels picker.
    'moderator:read:automod_settings',
    'moderator:manage:automod_settings',
    'moderator:manage:blocked_terms',
    'moderator:manage:unban_requests',
    'moderator:read:warnings',
    'moderator:read:chat_settings',
    'moderator:read:suspicious_users',
    'moderator:manage:suspicious_users',
    'moderator:read:chatters',
    'moderator:read:followers',
    'user:read:moderated_channels',
    // Broadcaster-only channel points tab.
    'channel:read:redemptions',
    'channel:manage:redemptions',
  ];

  /// Required scopes absent from a validate [granted] list.
  static List<String> missingScopes(Iterable<String> granted) {
    final have = granted.toSet();
    return [
      for (final s in requiredScopes)
        if (!have.contains(s)) s,
    ];
  }

  static String? lastError;

  /// True when the last flow ended because the user closed the login, which
  /// is not an error: the caller just returns to its idle state.
  static bool lastCancelled = false;
  static bool _flowInProgress = false;

  /// Starts the OAuth flow. Set [ephemeral] to launch the login in an
  /// incognito-style session with no shared cookies. That skips Twitch's
  /// "hi again, [user] - not you? log out" interstitial (which can hand the
  /// flow off to the installed Twitch app via Android App Links) and shows the
  /// plain login form instead - used for the switch-account / re-auth path.
  /// On Android this is a no-op: the session-bound Custom Tab already keeps
  /// every navigation inside the tab regardless of cookies.
  static Future<String?> startFlow({
    bool ephemeral = false,
    AppLocalizations? l,
  }) async {
    l ??= englishStrings();
    lastError = null;
    lastCancelled = false;
    if (_flowInProgress) {
      lastError = l.loginAlreadyOpen;
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

      return _extractToken(result, urlInfo.state, l);
    } on _LoginCancelled {
      lastCancelled = true;
      return null;
    } on PlatformException catch (e) {
      // flutter_web_auth_2 reports a closed login sheet as CANCELED.
      if (e.code == 'CANCELED') {
        lastCancelled = true;
      } else {
        lastError = l.loginOpenFailed;
      }
      return null;
    } on TimeoutException {
      lastError = l.loginTimedOut;
      return null;
    } catch (_) {
      lastError = l.loginOpenFailed;
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
      if (completer.isCompleted) return;
      if (call.method == 'onRedirect') {
        timeoutTimer?.cancel();
        completer.complete(call.arguments as String);
      } else if (call.method == 'onCancel') {
        // The user came back without finishing; free the flow for a retry.
        timeoutTimer?.cancel();
        completer.completeError(const _LoginCancelled());
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
        '&scope=${requiredScopes.join('+')}'
        '&state=$state'
        '&force_verify=true';
    return (url: url, state: state);
  }

  static String? _extractToken(
    String resultUrl,
    String expectedState,
    AppLocalizations l,
  ) {
    final params = parseFragment(resultUrl);
    final error = params['error'];
    final token = params['access_token'];
    final state = params['state'];

    if (error != null) {
      lastError = describeError(error, l);
      return null;
    }

    if (token != null) {
      if (state != expectedState) {
        lastError = stateMismatchError(l);
        return null;
      }
      return token;
    }

    lastError = l.loginNoToken;
    return null;
  }

  // The state nonce guards against a forged redirect; to the user it just
  // means this attempt is stale.
  static String stateMismatchError([AppLocalizations? l]) =>
      (l ?? englishStrings()).loginMismatch;

  /// Plain sentence for an OAuth `error` code from the redirect.
  static String describeError(String code, [AppLocalizations? l]) {
    l ??= englishStrings();
    return switch (code) {
      'access_denied' => l.loginDeclined,
      _ => l.loginGenericFailed,
    };
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

/// The login tab was closed before Twitch redirected back.
class _LoginCancelled implements Exception {
  const _LoginCancelled();
}
