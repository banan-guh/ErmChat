import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/recent_messages.dart';

class RecentMessagesSettingsScreen extends StatefulWidget {
  final ValueChanged<RecentMessagesConfig>? onChanged;

  const RecentMessagesSettingsScreen({super.key, this.onChanged});

  @override
  State<RecentMessagesSettingsScreen> createState() =>
      _RecentMessagesSettingsScreenState();
}

class _RecentMessagesSettingsScreenState
    extends State<RecentMessagesSettingsScreen> {
  RecentMessagesMode _mode = RecentMessagesMode.auto;
  final TextEditingController _customUrlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final config = RecentMessagesConfig.fromPrefs(prefs);
    if (!mounted) return;
    setState(() {
      _mode = config.mode;
      _customUrlController.text = config.customUrl ?? '';
    });
  }

  RecentMessagesConfig get _currentConfig {
    if (_mode == RecentMessagesMode.custom) {
      final url = _customUrlController.text.trim();
      // Custom with no URL is invalid; behave as Auto until one is supplied.
      if (url.isEmpty) return RecentMessagesConfig();
      return RecentMessagesConfig(mode: _mode, customUrl: url);
    }
    return RecentMessagesConfig(mode: _mode);
  }

  Future<void> _commit() async {
    final config = _currentConfig;
    final prefs = await SharedPreferences.getInstance();
    await config.toPrefs(prefs);
    widget.onChanged?.call(config);
  }

  void _onModeChanged(RecentMessagesMode? mode) {
    if (mode == null) return;
    setState(() => _mode = mode);
    unawaited(_commit());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recent messages')),
      body: RadioGroup<RecentMessagesMode>(
        groupValue: _mode,
        onChanged: (mode) {
          if (mode != null) _onModeChanged(mode);
        },
        child: ListView(
          children: [
            RadioListTile<RecentMessagesMode>(
              title: const Text('Auto'),
              subtitle: const Text('robotty, then zneix mirror'),
              value: RecentMessagesMode.auto,
            ),
            RadioListTile<RecentMessagesMode>(
              title: const Text('Robotty only'),
              subtitle: const Text('recent-messages.robotty.de'),
              value: RecentMessagesMode.robotty,
            ),
            RadioListTile<RecentMessagesMode>(
              title: const Text('Zneix only'),
              subtitle: const Text('recent-messages.zneix.eu'),
              value: RecentMessagesMode.zneix,
            ),
            RadioListTile<RecentMessagesMode>(
              title: const Text('Custom URL'),
              subtitle: const Text('Your own recent-messages backend'),
              value: RecentMessagesMode.custom,
            ),
            if (_mode == RecentMessagesMode.custom)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: TextField(
                  controller: _customUrlController,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://example.com/api/v2/recent-messages',
                  ),
                  keyboardType: TextInputType.url,
                  onChanged: (_) => unawaited(_commit()),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
