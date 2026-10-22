import 'dart:async';

import 'package:flutter/material.dart';
import '../../irc/proxy_config.dart';
import '../../l10n/l10n.dart';
import '../../util/settings.dart';
import 'settings_page.dart';

/// Chat proxy (ermchat-server) opt-in. Persists on every change; the read
/// socket picks it up on app restart.
class ProxySettingsScreen extends StatefulWidget {
  const ProxySettingsScreen({super.key});

  @override
  State<ProxySettingsScreen> createState() => _ProxySettingsScreenState();
}

class _ProxySettingsScreenState extends State<ProxySettingsScreen> {
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
    await Settings.bind();
    if (!mounted) return;
    setState(() => _urlController.text = Settings.proxyUrl.value);
  }

  Future<void> _commitUrl() async {
    await Settings.proxyUrl.set(_urlController.text.trim());
  }

  void _onEnabledChanged(bool value) {
    unawaited(Settings.proxyEnabled.set(value));
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.chatProxy),
      body: ValueListenableBuilder<bool>(
        valueListenable: Settings.proxyEnabled,
        builder: (context, enabled, _) => ListView(
          children: [
            SwitchListTile(
              title: Text(context.l10n.useChatProxy),
              value: enabled,
              onChanged: _onEnabledChanged,
            ),
            if (enabled)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
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
                    unawaited(_commitUrl());
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
