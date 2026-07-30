import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

Map<String, String?> _parseFragment(String url) {
  final uri = Uri.parse(url);
  final fragment = uri.fragment;
  if (fragment.isEmpty) return {};
  return Uri.splitQueryString(fragment);
}

class LoginWebView extends StatefulWidget {
  final String authUrl;
  final String expectedState;
  final String redirectUri;
  final void Function(String? token, {String? error}) onTokenResult;

  const LoginWebView({
    super.key,
    required this.authUrl,
    required this.expectedState,
    required this.redirectUri,
    required this.onTokenResult,
  });

  @override
  State<LoginWebView> createState() => _LoginWebViewState();
}

class _LoginWebViewState extends State<LoginWebView> {
  bool _isLoading = true;
  bool _handled = false;
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            debugPrint('LoginWebView.onPageStarted: $url');
            if (mounted) setState(() => _isLoading = true);
          },
          onPageFinished: (url) {
            debugPrint('LoginWebView.onPageFinished: $url');
            if (mounted) setState(() => _isLoading = false);
          },
          onNavigationRequest: (request) {
            debugPrint('LoginWebView.onNavigationRequest: ${request.url}');
            if (_isRedirect(request.url)) {
              _extractToken(request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onUrlChange: (change) {
            final url = change.url;
            debugPrint('LoginWebView.onUrlChange: $url');
            if (url != null && _isRedirect(url)) {
              _extractToken(url);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.authUrl));
  }

  bool _isRedirect(String url) {
    return url.startsWith(widget.redirectUri);
  }

  void _extractToken(String url) {
    if (_handled) return;
    _handled = true;

    final params = _parseFragment(url);
    final error = params['error'];
    final token = params['access_token'];
    final state = params['state'];

    if (error != null) {
      widget.onTokenResult(null, error: 'Twitch returned: $error');
      Navigator.pop(context);
      return;
    }

    if (token != null) {
      if (state != widget.expectedState) {
        widget.onTokenResult(null, error: 'CSRF: state mismatch');
        Navigator.pop(context);
        return;
      }
      widget.onTokenResult(token);
      Navigator.pop(context);
      return;
    }

    // no token or error — redirectUri match was a false positive
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Twitch Login'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            widget.onTokenResult(null);
            Navigator.pop(context);
          },
        ),
      ),
      body: Column(
        children: [
          if (_isLoading) const LinearProgressIndicator(),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}
