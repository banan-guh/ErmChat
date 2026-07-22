import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/twitch_message.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_oauth.dart';
import '../twitch_config.dart';

String _readVersion() {
  try {
    final file = File('pubspec.yaml');
    final lines = file.readAsLinesSync();
    for (final line in lines) {
      final match = RegExp(r'^version:\s*(.+)$').firstMatch(line);
      if (match != null) return match.group(1)!;
    }
  } catch (_) {}
  return 'unknown';
}

typedef OAuthStarter = Future<String?> Function(BuildContext context);

class SettingsScreen extends StatefulWidget {
  final TwitchAuth twitchAuth;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueNotifier<List<String>>? channelNotifier;
  final ValueChanged<String>? onLeaveChannel;
  final ValueChanged<String>? onAddChannel;
  final ValueChanged<List<String>>? onReorderChannels;
  final OAuthStarter? oAuthStarter;
  final Stream<TwitchMessage>? eventSubMessageStream;

  const SettingsScreen({
    super.key,
    required this.twitchAuth,
    required this.onThemeChanged,
    this.channelNotifier,
    this.onLeaveChannel,
    this.onAddChannel,
    this.onReorderChannels,
    this.oAuthStarter,
    this.eventSubMessageStream,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

enum _AuthState { idle, waiting, success, error, needsSetup, pasteToken }

class _SettingsScreenState extends State<SettingsScreen> {
  _AuthState _authState = _AuthState.idle;
  String? _authError;
  int _maxMessagesPerChannel = 200;
  bool _useBrowserOAuth = false;
  String? _browserAuthState;
  String? _browserAuthUrl;
  final _pasteController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.twitchAuth.isConfigured) _authState = _AuthState.success;
    widget.channelNotifier?.addListener(_onChannelsChanged);
    _loadMaxMessages();
    _loadOAuthMode();
  }

  Future<void> _loadMaxMessages() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _maxMessagesPerChannel =
            prefs.getInt('max_messages_per_channel') ?? 200;
      });
    }
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
    widget.channelNotifier?.removeListener(_onChannelsChanged);
    _pasteController.dispose();
    super.dispose();
  }

  void _onChannelsChanged() {
    if (mounted) setState(() {});
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

  void _addChannelDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join channel'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'channel name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (_) {
            final text = controller.text;
            Navigator.pop(ctx);
            widget.onAddChannel?.call(text);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text;
              Navigator.pop(ctx);
              widget.onAddChannel?.call(text);
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final channels = widget.channelNotifier?.value ?? [];

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.channelNotifier != null) ...[
              Text('Channels', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (channels.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No channels joined',
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              else
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: channels.length,
                  onReorderItem: (oldIndex, newIndex) {
                    final reordered = List.of(channels);
                    final item = reordered.removeAt(oldIndex);
                    reordered.insert(newIndex, item);
                    widget.onReorderChannels?.call(reordered);
                  },
                  itemBuilder: (_, i) => ListTile(
                    key: ValueKey(channels[i]),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.drag_handle),
                    title: Text(channels[i]),
                    trailing: IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => widget.onLeaveChannel?.call(channels[i]),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: OutlinedButton.icon(
                  onPressed: _addChannelDialog,
                  icon: const Icon(Icons.add),
                  label: const Text('Join channel'),
                ),
              ),
              const Divider(height: 32),
            ],
            SwitchListTile(
              title: const Text('Dark mode'),
              value: isDark,
              onChanged: (dark) {
                widget.onThemeChanged(dark ? ThemeMode.dark : ThemeMode.light);
              },
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Max messages per channel: $_maxMessagesPerChannel',
                  ),
                ),
                Slider(
                  value: _maxMessagesPerChannel.toDouble(),
                  min: 100,
                  max: 1000,
                  divisions: 9,
                  label: '$_maxMessagesPerChannel',
                  onChanged: (value) async {
                    final v = value.toInt();
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setInt('max_messages_per_channel', v);
                    if (mounted) setState(() => _maxMessagesPerChannel = v);
                  },
                ),
              ],
            ),
            const Divider(height: 32),
            Text(
              'Twitch Login',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
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
            const Divider(height: 32),
            Text('About', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('flutter_twitch_app'),
              subtitle: Text('Version ${_readVersion()}'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_authState) {
      case _AuthState.idle:
        return Center(
          child: FilledButton.icon(
            onPressed: _startOAuth,
            icon: const Icon(Icons.login),
            label: const Text('Login with Twitch'),
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
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Opening Twitch login...'),
              const SizedBox(height: 16),
              const CircularProgressIndicator(),
            ],
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
        );

      case _AuthState.error:
        return Center(
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
        );
    }
  }
}
