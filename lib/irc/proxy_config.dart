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
  /// An [insecure] URL is never used: the token would cross it in the clear.
  String? get readWsUrl => enabled && url.isNotEmpty && !insecure ? url : null;

  /// Plain ws:// to a host off the local network or tailnet.
  bool get insecure {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'ws') return false;
    return !_isLocalHost(uri.host);
  }

  static bool _isLocalHost(String host) {
    if (host == 'localhost' || host.endsWith('.local')) return true;
    // A bare name (ws://mynas) only resolves on the local network, and
    // MagicDNS names ride the tailnet.
    if (!host.contains('.') && !host.contains(':')) return true;
    if (host.endsWith('.ts.net')) return true;
    if (host.contains(':')) {
      // IPv6: loopback, unique local (fc00::/7) and link local (fe80::/10).
      final h = host.toLowerCase();
      return h == '::1' ||
          h.startsWith('fc') ||
          h.startsWith('fd') ||
          RegExp(r'^fe[89ab]').hasMatch(h);
    }
    final o = host.split('.').map(int.tryParse).toList();
    if (o.length != 4 || o.any((n) => n == null)) return false;
    final a = o[0]!, b = o[1]!;
    return a == 127 ||
        a == 10 ||
        (a == 192 && b == 168) ||
        (a == 172 && b >= 16 && b < 32) ||
        // Tailscale addresses: WireGuard encrypts the hop.
        (a == 100 && b >= 64 && b < 128);
  }

  static ProxyConfig fromPrefs(Prefs prefs) {
    return ProxyConfig(enabled: prefs.proxyEnabled, url: prefs.proxyUrl);
  }

  Future<void> toPrefs(Prefs prefs) async {
    await prefs.setProxyEnabled(enabled);
    await prefs.setProxyUrl(url);
  }

  @override
  bool operator ==(Object other) =>
      other is ProxyConfig && other.enabled == enabled && other.url == url;

  @override
  int get hashCode => Object.hash(enabled, url);
}
