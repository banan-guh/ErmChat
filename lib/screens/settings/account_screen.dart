import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/twitch_api.dart';
import '../../services/twitch_auth.dart';
import '../../services/twitch_oauth.dart';
import '../../twitch_config.dart';

enum _AuthState { idle, waiting, success, error, needsSetup, pasteToken }

class AccountScreen extends StatefulWidget {
  final TwitchAuth twitchAuth;
  final OAuthStarter? oAuthStarter;
  final TwitchApi? twitchApi;

  const AccountScreen({
    super.key,
    required this.twitchAuth,
    this.oAuthStarter,
    this.twitchApi,
  });

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  _AuthState _authState = _AuthState.idle;
  String? _authError;
  bool _useBrowserOAuth = false;
  String? _browserAuthState;
  String? _browserAuthUrl;
  String? _connectedLogin;
  final _pasteController = TextEditingController();
  TwitchApi? _ownApi;

  TwitchApi get _twitchApi => _ownApi ??= widget.twitchApi ?? TwitchApi();

  @override
  void initState() {
    super.initState();
    if (widget.twitchAuth.isConfigured) {
      _authState = _AuthState.success;
      _loadConnectedLogin();
    }
    _loadOAuthMode();
  }

  Future<void> _loadConnectedLogin() async {
    final auth = widget.twitchAuth;
    if (!auth.isConfigured) return;
    String? login;
    try {
      final user = await _twitchApi.getCurrentUser(auth);
      login = user?['login'];
      if (login != null && login.isNotEmpty) {
        // Keep the saved account's avatar fresh on every resolution.
        auth.setUser(
          login,
          user?['id'],
          profileImageUrl: user?['profile_image_url'],
        );
      }
    } catch (_) {
      login = null;
    }
    if (!mounted) return;
    setState(() => _connectedLogin = login);
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

  Future<void> _startOAuth({bool ephemeral = false}) async {
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
      final starter = widget.oAuthStarter;
      final token = starter != null
          ? await starter()
          : await TwitchOAuth.startFlow(ephemeral: ephemeral);

      if (!mounted) return;

      if (token != null && token.isNotEmpty) {
        widget.twitchAuth.setCredentials(accessToken: token);
        setState(() => _authState = _AuthState.success);
        _loadConnectedLogin();
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
        _authError = 'Authorization error: $error';
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
      _loadConnectedLogin();
      return;
    }

    setState(() {
      _authError =
          'No access token found in the pasted URL. '
          'Make sure you paste the full redirect URL including the #fragment.';
    });
  }

  Future<void> _clearCredentials() async {
    await widget.twitchAuth.clear();
    if (!mounted) return;
    setState(() {
      // With multiple saved accounts, clearing the active one falls back to
      // the next account instead of logging out entirely.
      _authState = widget.twitchAuth.isConfigured
          ? _AuthState.success
          : _AuthState.idle;
      _authError = null;
      _connectedLogin = null;
    });
    if (widget.twitchAuth.isConfigured) {
      _loadConnectedLogin();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        children: [
          if (widget.twitchAuth.accounts.isNotEmpty) _buildAccountSection(),
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

  // Saved accounts: tap to switch, long-press to remove (with confirmation).
  Widget _buildAccountSection() {
    final auth = widget.twitchAuth;
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        final accounts = auth.accounts;
        if (accounts.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                'Accounts',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            for (final account in accounts)
              ListTile(
                leading: _AccountAvatar(account: account),
                title: Text(account.login),
                subtitle:
                    account.login.toLowerCase() == auth.login?.toLowerCase()
                    ? const Text('Active')
                    : null,
                trailing:
                    account.login.toLowerCase() == auth.login?.toLowerCase()
                    ? Icon(Icons.check, color: theme.colorScheme.primary)
                    : null,
                onTap: () => auth.switchTo(account.login),
                onLongPress: () => _confirmRemove(account),
              ),
          ],
        );
      },
    );
  }

  Future<void> _confirmRemove(TwitchAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove account?'),
        content: Text('Are you sure you want to remove @${account.login}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.twitchAuth.removeAccount(account.login);
    if (!mounted) return;
    setState(() {
      _authState = widget.twitchAuth.isConfigured
          ? _AuthState.success
          : _AuthState.idle;
      _authError = null;
      _connectedLogin = null;
    });
    if (widget.twitchAuth.isConfigured) {
      _loadConnectedLogin();
    }
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
              label: const Text('Login'),
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
                Icon(Icons.check_circle, size: 40, color: Colors.green),
                const SizedBox(height: 8),
                Text(
                  _connectedLogin != null
                      ? 'Connected as $_connectedLogin'
                      : 'Connected',
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _startOAuth(ephemeral: true),
                      icon: const Icon(Icons.person_add),
                      label: const Text('Add account'),
                    ),
                    const SizedBox(width: 12),
                    TextButton.icon(
                      onPressed: _clearCredentials,
                      icon: const Icon(Icons.logout),
                      label: const Text('Disconnect'),
                    ),
                  ],
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

// Account avatar: the saved profile picture when available, otherwise the
// first letter of the login.
class _AccountAvatar extends StatelessWidget {
  final TwitchAccount account;

  const _AccountAvatar({required this.account});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final letter = Text(
      account.login.isEmpty ? '?' : account.login[0].toUpperCase(),
      style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
    );
    final url = account.profileImageUrl;
    if (url == null || url.isEmpty) {
      return CircleAvatar(
        radius: 18,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        child: letter,
      );
    }
    return CircleAvatar(
      radius: 18,
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      foregroundImage: NetworkImage(url),
      onForegroundImageError: (_, _) {},
      child: letter,
    );
  }
}
