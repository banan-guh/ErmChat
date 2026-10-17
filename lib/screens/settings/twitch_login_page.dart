import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/l10n.dart';
import '../../services/twitch_oauth.dart';

/// Twitch's authorize page in an in-app WebView. Pops with the redirect URL
/// once Twitch hands the token back, or null when closed. The WebView keeps
/// its cookies (shared with the stream player), so a remembered Twitch
/// session makes a repeat login one tap.
class TwitchLoginPage extends StatefulWidget {
  final String authUrl;

  /// Receives the twitch.tv cookies the login left behind.
  final ValueChanged<String>? onCookies;

  const TwitchLoginPage({super.key, required this.authUrl, this.onCookies});

  /// A [LoginPresenter] that pushes this page from [context].
  static LoginPresenter presenter(
    BuildContext context, {
    ValueChanged<String>? onCookies,
  }) =>
      (url) => Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => TwitchLoginPage(authUrl: url, onCookies: onCookies),
        ),
      );

  /// Puts an account's saved twitch.tv [cookies] in the shared WebView jar,
  /// so the login page and stream player act as that account. Null leaves
  /// the jar alone: an account saved before cookies were kept has nothing
  /// to put back.
  static Future<void> useSession(String? cookies) async {
    if (cookies == null) return;
    final manager = WebViewCookieManager();
    await manager.clearCookies();
    for (final pair in cookies.split(';')) {
      final at = pair.indexOf('=');
      if (at <= 0) continue;
      await manager.setCookie(
        WebViewCookie(
          name: pair.substring(0, at).trim(),
          value: pair.substring(at + 1).trim(),
          domain: '.twitch.tv',
        ),
      );
    }
  }

  /// Empties the WebView jar so the next login signs in fresh.
  static Future<void> clearSession() => WebViewCookieManager().clearCookies();

  @override
  State<TwitchLoginPage> createState() => _TwitchLoginPageState();
}

class _TwitchLoginPageState extends State<TwitchLoginPage> {
  late final WebViewController _controller;
  int _progress = 0;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.authUrl));
  }

  // Catch the redirect before it loads, and keep app links (twitch://,
  // intent://) from leaving the WebView.
  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final url = request.url;
    if (TwitchOAuth.isRedirect(url)) {
      if (!_done) {
        _done = true;
        unawaited(_finish(url));
      }
      return NavigationDecision.prevent;
    }
    final scheme = Uri.tryParse(url)?.scheme;
    if (request.isMainFrame && scheme != 'https' && scheme != 'about') {
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  // The page is still on id.twitch.tv, so it reads the .twitch.tv session
  // cookies before handing the token back.
  Future<void> _finish(String url) async {
    try {
      final raw = await _controller.runJavaScriptReturningResult(
        'document.cookie',
      );
      // Android returns the string JSON-quoted, iOS bare.
      var cookies = raw is String ? raw : raw.toString();
      if (cookies.startsWith('"')) cookies = jsonDecode(cookies) as String;
      if (cookies.isNotEmpty) widget.onCookies?.call(cookies);
    } catch (_) {
      // No cookies only costs the per-account session, not the login.
    }
    if (mounted) Navigator.of(context).pop(url);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const CloseButton(),
        title: Text(context.l10n.logIn),
        bottom: _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: _progress == 0 ? null : _progress / 100,
                  minHeight: 2,
                ),
              )
            : null,
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
