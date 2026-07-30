import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/twitch_auth.dart';
import '../../services/twitch_oauth.dart';
import '../../twitch_config.dart';
import 'settings_screen.dart';

enum _AuthState { idle, waiting, success, error, needsSetup, pasteToken }

class AccountScreen extends StatefulWidget {
  final TwitchAuth twitchAuth;
  final OAuthStarter? oAuthStarter;

  const AccountScreen({super.key, required this.twitchAuth, this.oAuthStarter});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  _AuthState _authState = _AuthState.idle;
  String? _authError;
  bool _useBrowserOAuth = false;
  String? _browserAuthState;
  String? _browserAuthUrl;
  final _pasteController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.twitchAuth.isConfigured) _authState = _AuthState.success;
    _loadOAuthMode();
  }

  Future<void> _loadOAuthMode() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _useBrowserOAuth = prefs.getBool('use_browser_oauth') ?? false;
      });
    }
  }

  Future<void> _saveOAuthMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_browser_oauth', value);
  }

  @override
  void dispose() {
    _pasteController.dispose();
    super.dispose();
  }

  Future<void> _startOAuth() async {
    setState(() {
      _authState = _AuthState.waiting;
      _authError = null;
    });

    if (!TwitchConfig.isConfigured) {
      setState(() => _authState = _AuthState.needsSetup);
      return;
    }

    if (_useBrowserOAuth) {
      _startBrowserOAuth();
    } else {
      final starter = widget.oAuthStarter ?? TwitchOAuth.startFlow;
      final token = await starter(context);

      if (!mounted) return;

      if (token != null && token.isNotEmpty) {
        widget.twitchAuth.setCredentials(accessToken: token);
        setState(() => _authState = _AuthState.success);
      } else {
        setState(() {
          _authState = _AuthState.error;
          _authError =
              TwitchOAuth.lastError ?? 'Authorization failed or timed out.';
        });
      }
    }
  }

  void _startBrowserOAuth() {
    final urlInfo = TwitchOAuth.generateAuthUrl();
    if (urlInfo == null) return;

    _browserAuthUrl = urlInfo.url;
    _browserAuthState = urlInfo.state;
    _pasteController.clear();

    setState(() => _authState = _AuthState.pasteToken);

    launchUrl(Uri.parse(urlInfo.url), mode: LaunchMode.externalApplication);
  }

  void _submitPastedUrl() {
    final pasted = _pasteController.text.trim();
    if (pasted.isEmpty) return;

    final params = TwitchOAuth.parseFragment(pasted);
    final error = params['error'];
    final token = params['access_token'];
    final state = params['state'];

    if (error != null) {
      setState(() {
        _authState = _AuthState.error;
        _authError = 'Twitch returned: $error';
      });
      return;
    }

    if (token != null) {
      if (state != _browserAuthState) {
        setState(() {
          _authState = _AuthState.error;
          _authError = 'CSRF: state mismatch';
        });
        return;
      }
      widget.twitchAuth.setCredentials(accessToken: token);
      setState(() => _authState = _AuthState.success);
      return;
    }

    setState(() {
      _authError =
          'No access token found in the pasted URL. '
          'Make sure you paste the full redirect URL including the #fragment.';
    });
  }

  void _clearCredentials() {
    widget.twitchAuth.clear();
    setState(() {
      _authState = _AuthState.idle;
      _authError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        children: [
          _buildBody(),
          SwitchListTile(
            title: const Text('Use browser for OAuth'),
            subtitle: const Text(
              'Opens Twitch login in external browser instead of in-app WebView',
            ),
            value: _useBrowserOAuth,
            onChanged: (value) {
              setState(() => _useBrowserOAuth = value);
              _saveOAuthMode(value);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_authState) {
      case _AuthState.idle:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: FilledButton.icon(
              onPressed: _startOAuth,
              icon: const Icon(Icons.login),
              label: const Text('Login with Twitch'),
            ),
          ),
        );

      case _AuthState.needsSetup:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.info_outline, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'Open lib/twitch_config.dart and replace YOUR_CLIENT_ID_HERE '
                  'with your Twitch Client ID.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Get one at dev.twitch.tv/console/apps',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _startOAuth,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try Again'),
                ),
              ],
            ),
          ),
        );

      case _AuthState.waiting:
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Opening Twitch login...'),
                SizedBox(height: 16),
                CircularProgressIndicator(),
              ],
            ),
          ),
        );

      case _AuthState.pasteToken:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_authError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _authError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              const Text(
                'Authorize in your browser, then paste the full redirect URL '
                '(including the #fragment) below.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              SelectionArea(
                child: Text(
                  _browserAuthUrl ?? '',
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  if (_browserAuthUrl != null) {
                    Clipboard.setData(ClipboardData(text: _browserAuthUrl!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('URL copied!')),
                    );
                  }
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy URL'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pasteController,
                decoration: const InputDecoration(
                  hintText: 'Paste redirect URL here...',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        setState(() => _authState = _AuthState.idle);
                      },
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _submitPastedUrl,
                      child: const Text('Submit'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );

      case _AuthState.success:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle, size: 64, color: Colors.green),
                const SizedBox(height: 16),
                const Text('Connected to Twitch'),
                const SizedBox(height: 24),
                TextButton.icon(
                  onPressed: _clearCredentials,
                  icon: const Icon(Icons.logout),
                  label: const Text('Disconnect'),
                ),
              ],
            ),
          ),
        );

      case _AuthState.error:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    _authError ?? 'Unknown error',
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _startOAuth,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try Again'),
                ),
              ],
            ),
          ),
        );
    }
  }
}
