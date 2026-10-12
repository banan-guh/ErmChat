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

  const TwitchLoginPage({super.key, required this.authUrl});

  /// A [LoginPresenter] that pushes this page from [context].
  static LoginPresenter presenter(BuildContext context) =>
      (url) => Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => TwitchLoginPage(authUrl: url)),
      );

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
        Navigator.of(context).pop(url);
      }
      return NavigationDecision.prevent;
    }
    final scheme = Uri.tryParse(url)?.scheme;
    if (request.isMainFrame && scheme != 'https' && scheme != 'about') {
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
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
