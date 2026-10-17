import 'dart:async';

import 'package:flutter/material.dart';
import '../../irc/proxy_config.dart';
import '../../l10n/l10n.dart';
import '../../util/prefs.dart';
import 'settings_page.dart';

/// Chat proxy (ermchat-server) opt-in. Persists on every change; the read
/// socket picks it up on app restart.
class ProxySettingsScreen extends StatefulWidget {
  const ProxySettingsScreen({super.key});

  @override
  State<ProxySettingsScreen> createState() => _ProxySettingsScreenState();
}

class _ProxySettingsScreenState extends State<ProxySettingsScreen> {
  bool _enabled = false;
  final TextEditingController _urlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await Prefs.load();
    final config = ProxyConfig.fromPrefs(prefs);
    if (!mounted) return;
    setState(() {
      _enabled = config.enabled;
      _urlController.text = config.url;
    });
  }

  Future<void> _commit() async {
    final prefs = await Prefs.load();
    await ProxyConfig(
      enabled: _enabled,
      url: _urlController.text.trim(),
    ).toPrefs(prefs);
  }

  void _onEnabledChanged(bool value) {
    setState(() => _enabled = value);
    unawaited(_commit());
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.chatProxy),
      body: ListView(
        children: [
          SwitchListTile(
            title: Text(context.l10n.useChatProxy),
            value: _enabled,
            onChanged: _onEnabledChanged,
          ),
          if (_enabled)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: context.l10n.proxyUrl,
                  hintText: 'ws://192.168.1.10:8080/ws',
                  errorText:
                      ProxyConfig(url: _urlController.text.trim()).insecure
                      ? context.l10n.proxyInsecure
                      : null,
                ),
                keyboardType: TextInputType.url,
                onChanged: (_) {
                  setState(() {});
                  unawaited(_commit());
                },
              ),
            ),
        ],
      ),
    );
  }
}
