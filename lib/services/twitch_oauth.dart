import 'dart:convert';
import 'dart:math';
import '../l10n/l10n.dart';
import '../twitch_config.dart';

/// A function that starts the OAuth flow and resolves with the access token
/// on success or null on failure/cancel. Defined here so both the settings
/// and account screens can inject a mocked flow without importing each other.
typedef OAuthStarter = Future<String?> Function();

/// Shows the Twitch authorize page at a URL and resolves with the redirect
/// URL once Twitch sends the user back, or null if they closed the login.
typedef LoginPresenter = Future<String?> Function(String authUrl);

class TwitchOAuth {
  static const _authorizeUrl = 'https://id.twitch.tv/oauth2/authorize';

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
    // The account's own emotes (subs, follower, unlocks, Hype Train).
    'user:read:emotes',
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

  /// Starts the OAuth flow, showing the authorize page through [present].
  /// Set [forceVerify] to make Twitch show its authorize page (with "not
  /// you?") even when the login session would otherwise redirect straight
  /// back: the add-account and re-auth paths need a choice of user.
  static Future<String?> startFlow({
    required LoginPresenter present,
    bool forceVerify = false,
    AppLocalizations? l,
  }) async {
    l ??= englishStrings();
    lastError = null;
    lastCancelled = false;
    if (_flowInProgress) {
      lastError = l.loginAlreadyOpen;
      return null;
    }

    final urlInfo = generateAuthUrl(forceVerify: forceVerify);
    if (urlInfo == null) return null;

    _flowInProgress = true;
    try {
      final result = await present(urlInfo.url);
      if (result == null) {
        lastCancelled = true;
        return null;
      }
      return _extractToken(result, urlInfo.state, l);
    } catch (_) {
      lastError = l.loginOpenFailed;
      return null;
    } finally {
      _flowInProgress = false;
    }
  }

  /// Whether a navigation is Twitch handing the token back. The login
  /// WebView catches it before it loads, so the token never reaches a
  /// custom URL scheme another app could claim.
  static bool isRedirect(String url) =>
      url.startsWith(TwitchConfig.redirectUri);

  static ({String url, String state})? generateAuthUrl({
    bool forceVerify = false,
  }) {
    if (!TwitchConfig.isConfigured) return null;

    final state = _randomState();
    final url =
        '$_authorizeUrl'
        '?client_id=${TwitchConfig.clientId}'
        '&redirect_uri=${Uri.encodeQueryComponent(TwitchConfig.redirectUri)}'
        '&response_type=token'
        '&scope=${requiredScopes.join('+')}'
        '&state=$state'
        '${forceVerify ? '&force_verify=true' : ''}';
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
      lastError = state == expectedState
          ? describeError(error, l)
          : stateMismatchError(l);
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
