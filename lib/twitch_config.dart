/// Twitch application credentials.
///
/// 1. Go to https://dev.twitch.tv/console/apps
/// 2. Create a new application (Client Type: Public)
/// 3. Set "OAuth Redirect URL" to the [redirectUri] value below (must match exactly)
/// 4. Copy the Client ID below
///
/// If your app requires a client secret (Confidential), also set [clientSecret].
class TwitchConfig {
  static const String clientId = 'hn6tq8xvgzx91n4mx72573o1c2x9nk';

  /// HTTPS redirect URI for the OAuth implicit grant flow.
  ///
  /// Register this exact URL in your Twitch dev console under
  /// "OAuth Redirect URLs". The WebView intercepts the redirect before the
  /// browser navigates, so this URL doesn't need to serve real content, but
  /// it must be a valid HTTPS URL that matches what Twitch has on file.
  static const String redirectUri =
      'https://banan-guh.github.io/twitch-app-oauth';

  static bool get isConfigured =>
      clientId.isNotEmpty && clientId != 'YOUR_CLIENT_ID_HERE';
}
