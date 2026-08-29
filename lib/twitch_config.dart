class TwitchConfig {
  static const String clientId = 'hn6tq8xvgzx91n4mx72573o1c2x9nk';

  static const String redirectUri =
      'https://banan-guh.github.io/twitch-app-oauth'; // Must match the Twitch dev console exactly; trailing slash breaks it.

  static const String callbackUrlScheme = 'ermchat';

  static bool get isConfigured =>
      clientId.isNotEmpty && clientId != 'YOUR_CLIENT_ID_HERE';
}
