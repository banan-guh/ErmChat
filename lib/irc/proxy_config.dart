import '../util/prefs.dart';

/// Chat proxy (ermchat-server) opt-in config. Disabled by default; the read
/// socket keeps dialing Twitch directly until the toggle is on and a URL
/// is set. Applies on app restart.
class ProxyConfig {
  const ProxyConfig({this.enabled = false, this.url = ''});

  final bool enabled;

  /// Proxy websocket URL, e.g. ws://192.168.1.10:8080/ws.
  final String url;

  /// Read-socket URL override, or null to keep the direct Twitch connection.
  String? get readWsUrl => enabled && url.isNotEmpty ? url : null;

  static ProxyConfig fromPrefs(Prefs prefs) {
    return ProxyConfig(enabled: prefs.proxyEnabled, url: prefs.proxyUrl);
  }

  Future<void> toPrefs(Prefs prefs) async {
    await prefs.setProxyEnabled(enabled);
    await prefs.setProxyUrl(url);
  }
}
