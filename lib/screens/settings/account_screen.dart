import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../l10n/l10n.dart';
import '../../services/twitch_api.dart';
import '../../services/twitch_auth.dart';
import '../../services/twitch_oauth.dart';
import '../../twitch_config.dart';
import '../../util/log.dart';
import '../../util/settings.dart';
import '../../widgets/app_snack.dart';
import '../../widgets/dialogs.dart';
import 'settings_page.dart';
import 'twitch_login_page.dart';

enum _AuthState { idle, waiting, success, error, needsSetup, pasteToken }

class AccountScreen extends StatefulWidget {
  final TwitchAuth twitchAuth;
  final OAuthStarter? oAuthStarter;
  final TwitchApi? twitchApi;

  /// Runs after the shared WebView session changed, so a live player can
  /// pick it up.
  final VoidCallback? onWebSessionChanged;

  const AccountScreen({
    super.key,
    required this.twitchAuth,
    this.oAuthStarter,
    this.twitchApi,
    this.onWebSessionChanged,
  });

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  _AuthState _authState = _AuthState.idle;
  String? _authError;
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
  }

  Future<void> _loadConnectedLogin() async {
    final auth = widget.twitchAuth;
    if (!auth.isConfigured) return;
    // Attribute the resolution to the credential it was made with so a slow
    // result landing after an account switch is discarded (setUser).
    final tokenAtStart = auth.accessToken;
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
          resolvedWithToken: tokenAtStart,
        );
      }
    } catch (_) {
      login = null;
    }
    if (!mounted) return;
    setState(() => _connectedLogin = login);
  }

  @override
  void dispose() {
    _pasteController.dispose();
    if (widget.twitchApi == null) _ownApi?.close();
    super.dispose();
  }

  /// [adding] signs in another account. With the active account's session
  /// saved, the jar empties so the user signs in fresh and Twitch skips its
  /// authorize page for an approved app; without one to put back, Twitch's
  /// forced authorize page offers "Not you?" instead. Any other login keeps
  /// the jar, so a re-login of the signed-in account is one tap.
  Future<void> _startOAuth({bool adding = false}) async {
    setState(() {
      _authState = _AuthState.waiting;
      _authError = null;
    });

    if (!TwitchConfig.isConfigured) {
      setState(() => _authState = _AuthState.needsSetup);
      return;
    }

    final l = context.l10n;
    String? cookies;
    final present = TwitchLoginPage.presenter(
      context,
      onCookies: (c) => cookies = c,
    );
    final saved = widget.twitchAuth.activeAccount?.webCookies;
    if (Settings.useBrowserOAuth.value) {
      _startBrowserOAuth(forceVerify: adding);
      return;
    }
    final starter = widget.oAuthStarter;
    final fresh = adding && saved != null && starter == null;
    if (fresh) await TwitchLoginPage.clearSession();
    final token = starter != null
        ? await starter()
        : await TwitchOAuth.startFlow(
            present: present,
            forceVerify: adding && !fresh,
            l: l,
          );
    final signedIn = token != null && token.isNotEmpty;
    // A login that went nowhere hands the jar back to the active account.
    if (fresh && !signedIn) await TwitchLoginPage.useSession(saved);

    await _finishNativeOAuth(
      token,
      cookies: cookies,
      // TwitchOAuth's own flow treats a closed login as a cancel, not an error.
      cancelledIsCancel: starter == null,
    );
  }

  /// Settles what the native flow came back with: a token signs the account
  /// in, a closed login returns to where the user was, anything else shows
  /// why it failed.
  Future<void> _finishNativeOAuth(
    String? token, {
    required String? cookies,
    required bool cancelledIsCancel,
  }) async {
    if (!mounted) return;

    if (token != null && token.isNotEmpty) {
      widget.twitchAuth.setCredentials(accessToken: token, webCookies: cookies);
      widget.onWebSessionChanged?.call();
      setState(() => _authState = _AuthState.success);
      _loadConnectedLogin();
      return;
    }

    if (cancelledIsCancel && TwitchOAuth.lastCancelled) {
      // Closing the login is not an error: back to where the user was.
      setState(() {
        _authState = widget.twitchAuth.isConfigured
            ? _AuthState.success
            : _AuthState.idle;
      });
      return;
    }

    setState(() {
      _authState = _AuthState.error;
      _authError = TwitchOAuth.lastError ?? context.l10n.loginFailed;
    });
  }

  void _startBrowserOAuth({bool forceVerify = false}) {
    final urlInfo = TwitchOAuth.generateAuthUrl(forceVerify: forceVerify);
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
        _authError = TwitchOAuth.describeError(error, context.l10n);
      });
      return;
    }

    if (token != null) {
      if (state != _browserAuthState) {
        setState(() {
          _authState = _AuthState.error;
          _authError = TwitchOAuth.stateMismatchError(context.l10n);
        });
        return;
      }
      widget.twitchAuth.setCredentials(accessToken: token);
      setState(() => _authState = _AuthState.success);
      _loadConnectedLogin();
      return;
    }

    setState(() {
      _authError = context.l10n.loginLinkMissing;
    });
  }

  // Puts the active account's web session in the WebView jar once the
  // active account changed from [left]. An account without a saved one gets
  // an empty jar rather than the previous account's session.
  Future<void> _followSession(String? left) async {
    final active = widget.twitchAuth.activeAccount;
    if (active?.login == left) return;
    final next = active?.webCookies;
    try {
      if (next != null) {
        await TwitchLoginPage.useSession(next);
      } else {
        await TwitchLoginPage.clearSession();
      }
    } catch (e) {
      // A jar that fails to change must not stop the switch itself.
      logDebug('[Account] web session swap failed: $e');
    }
    widget.onWebSessionChanged?.call();
  }

  /// Points the screen back at whatever auth now holds: the state, the error
  /// and the resolved login all follow it. With multiple saved accounts,
  /// dropping the active one falls back to the next instead of logging out.
  void _syncToAuth() {
    final configured = widget.twitchAuth.isConfigured;
    setState(() {
      _authState = configured ? _AuthState.success : _AuthState.idle;
      _authError = null;
      _connectedLogin = null;
    });
    if (configured) {
      _loadConnectedLogin();
    }
  }

  Future<void> _clearCredentials() async {
    final left = widget.twitchAuth.activeAccount?.login;
    await widget.twitchAuth.clear();
    await _followSession(left);
    if (!mounted) return;
    _syncToAuth();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.pageAccount),
      body: ListView(children: [_buildAccountSection(), _buildBody()]),
    );
  }

  // Account switcher, always visible: saved accounts plus an Anonymous row
  // at the bottom. Tap to switch; Disconnect removes the active account.
  Widget _buildAccountSection() {
    final auth = widget.twitchAuth;
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        final accounts = auth.accounts;
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                context.l10n.accounts,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            for (final account in accounts) _accountTile(auth, account, theme),
            _anonymousTile(auth, theme),
          ],
        );
      },
    );
  }

  /// One saved account row; an expired account is dimmed.
  Widget _accountTile(TwitchAuth auth, TwitchAccount account, ThemeData theme) {
    final isActive = account.login.toLowerCase() == auth.login?.toLowerCase();
    final isExpired = account.expired;
    final needsReauth = isActive && !isExpired && auth.scopeStale;
    final tile = ListTile(
      leading: _AccountAvatar(account: account),
      title: Text(account.login),
      subtitle: isExpired
          ? Text(context.l10n.accountExpired)
          : needsReauth
          ? Text(context.l10n.accountNewPermissions)
          : isActive
          ? Text(context.l10n.accountActive)
          : null,
      trailing: isActive && !isExpired
          ? Icon(Icons.check, color: theme.colorScheme.primary)
          : null,
      onTap: () => _switchAccount(() => auth.switchTo(account.login)),
    );
    return isExpired ? Opacity(opacity: 0.5, child: tile) : tile;
  }

  /// The signed-out row at the bottom of the switcher.
  Widget _anonymousTile(TwitchAuth auth, ThemeData theme) {
    final isActive = auth.isAnonymous;
    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        child: Icon(
          Icons.person_outline,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      title: Text(context.l10n.anonymous),
      subtitle: isActive ? Text(context.l10n.accountActive) : null,
      trailing: isActive
          ? Icon(Icons.check, color: theme.colorScheme.primary)
          : null,
      onTap: () => _switchAccount(auth.switchToAnonymous),
    );
  }

  // Account/anonymous taps leave a stale _authState behind (e.g. success UI
  // while anonymous), so sync it back to the auth state when no login flow
  // is in progress.
  Future<void> _switchAccount(Future<void> Function() switchOp) async {
    final left = widget.twitchAuth.activeAccount?.login;
    await switchOp();
    await _followSession(left);
    if (!mounted) return;
    if (_settled) {
      _syncToAuth();
    } else if (widget.twitchAuth.isConfigured) {
      // An open login flow owns the screen; the login still resolves.
      _loadConnectedLogin();
    }
  }

  /// States that describe the settled account, not an open login flow.
  bool get _settled =>
      _authState == _AuthState.idle ||
      _authState == _AuthState.success ||
      _authState == _AuthState.error;

  /// Disconnect forgets the active account, so it confirms first.
  Future<void> _disconnect() async {
    final active = widget.twitchAuth.activeAccount;
    if (active == null) return _clearCredentials();
    return _confirmRemove(active);
  }

  Future<void> _confirmRemove(TwitchAccount account) async {
    final confirmed = await confirmDialog(
      context,
      title: context.l10n.removeAccountTitle,
      message: context.l10n.removeAccountMessage(account.login),
      confirmLabel: context.l10n.remove,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final left = widget.twitchAuth.activeAccount?.login;
    await widget.twitchAuth.removeAccount(account.login);
    await _followSession(left);
    if (!mounted) return;
    _syncToAuth();
  }

  Widget _buildBody() => switch (_authState) {
    _AuthState.idle => _idleBody(),
    _AuthState.needsSetup => _needsSetupBody(),
    _AuthState.waiting => _waitingBody(),
    _AuthState.pasteToken => _pasteTokenBody(),
    _AuthState.success => _successBody(),
    _AuthState.error => _errorBody(),
  };

  /// A single Log in button; the switcher above already shows the accounts.
  Widget _idleBody() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: FilledButton.icon(
        onPressed: _startOAuth,
        icon: const Icon(Icons.login),
        label: Text(context.l10n.logIn),
      ),
    ),
  );

  /// TwitchConfig still has its placeholder client id, so login cannot run.
  Widget _needsSetupBody() => Center(
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
            label: Text(context.l10n.tryAgain),
          ),
        ],
      ),
    ),
  );

  Widget _waitingBody() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(context.l10n.openingTwitchLogin),
          const SizedBox(height: 16),
          const CircularProgressIndicator(),
        ],
      ),
    ),
  );

  /// Browser OAuth: the URL to finish in a browser, then the redirect to paste.
  Widget _pasteTokenBody() => Padding(
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
              style: TextStyle(color: Theme.of(context).colorScheme.error),
              textAlign: TextAlign.center,
            ),
          ),
        Text(context.l10n.browserAuthHint, textAlign: TextAlign.center),
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
              AppSnack.show(context, context.l10n.urlCopied);
            }
          },
          icon: const Icon(Icons.copy, size: 18),
          label: Text(context.l10n.copyUrl),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pasteController,
          decoration: InputDecoration(
            hintText: context.l10n.pasteRedirectUrl,
            border: const OutlineInputBorder(),
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
                child: Text(context.l10n.cancel),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _submitPastedUrl,
                child: Text(context.l10n.submit),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _successBody() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 40, color: Colors.green),
          const SizedBox(height: 8),
          // Follows auth changes so switching accounts updates the header
          // immediately; _connectedLogin is only a fallback until the active
          // account's identity is resolved.
          ListenableBuilder(
            listenable: widget.twitchAuth,
            builder: (context, _) {
              final login = widget.twitchAuth.login ?? _connectedLogin;
              return Text(
                login != null
                    ? context.l10n.connectedAs(login)
                    : context.l10n.connected,
              );
            },
          ),
          ListenableBuilder(
            listenable: widget.twitchAuth,
            builder: (context, _) {
              if (!widget.twitchAuth.scopeStale) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  context.l10n.modScopesStale,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          OverflowBar(
            spacing: 12,
            overflowSpacing: 8,
            alignment: MainAxisAlignment.center,
            children: [
              ListenableBuilder(
                listenable: widget.twitchAuth,
                builder: (context, _) {
                  final auth = widget.twitchAuth;
                  final needsLogin = auth.scopeStale || auth.isActiveExpired;
                  return OutlinedButton.icon(
                    // Stale scopes and expired tokens re-login the active
                    // account.
                    onPressed: () => _startOAuth(adding: !needsLogin),
                    icon: Icon(needsLogin ? Icons.login : Icons.person_add),
                    label: Text(
                      needsLogin
                          ? context.l10n.logInAgain
                          : context.l10n.addAccount,
                    ),
                  );
                },
              ),
              TextButton.icon(
                onPressed: _disconnect,
                icon: const Icon(Icons.logout),
                label: Text(context.l10n.disconnect),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _errorBody() => Center(
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
              _authError ?? context.l10n.unknownError,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _startOAuth,
            icon: const Icon(Icons.refresh),
            label: Text(context.l10n.tryAgain),
          ),
        ],
      ),
    ),
  );
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
