import 'dart:async';

import 'package:flutter/material.dart';
import '../../irc/proxy_config.dart';
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
      title: const Text('Chat proxy'),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Use chat proxy'),
            subtitle: const Text(
              'Use ermchat-server.',
            ),
            value: _enabled,
            onChanged: _onEnabledChanged,
          ),
          if (_enabled)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'Proxy URL',
                  hintText: 'ws://192.168.1.10:8080/ws',
                ),
                keyboardType: TextInputType.url,
                onChanged: (_) => unawaited(_commit()),
              ),
            ),
        ],
      ),
    );
  }
}
