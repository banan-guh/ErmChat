import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../util/prefs.dart';
import 'settings_page.dart';

class StreamSettingsScreen extends StatefulWidget {
  final ValueChanged<bool>? onShowExtensionsChanged;
  final ValueChanged<bool>? onRetainWebviewChanged;
  final ValueChanged<bool>? onPipEnabledChanged;

  const StreamSettingsScreen({
    super.key,
    this.onShowExtensionsChanged,
    this.onRetainWebviewChanged,
    this.onPipEnabledChanged,
  });

  @override
  State<StreamSettingsScreen> createState() => _StreamSettingsScreenState();
}

class _StreamSettingsScreenState extends State<StreamSettingsScreen> {
  bool _showExtensions = false;
  bool _retainWebview = true;
  bool _pipEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await Prefs.load();
    if (!mounted) return;
    setState(() {
      _showExtensions = prefs.streamShowExtensions;
      _retainWebview = prefs.streamRetainWebview;
      _pipEnabled = prefs.streamPipEnabled;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: const Text('Livestreams'),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.extension),
            title: const Text('Show stream extensions'),
            subtitle: const Text('Load channel extensions inside the player'),
            value: _showExtensions,
            onChanged: (value) {
              setState(() => _showExtensions = value);
              unawaited(
                Prefs.load().then(
                  (prefs) => prefs.setStreamShowExtensions(value),
                ),
              );
              widget.onShowExtensionsChanged?.call(value);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.cached),
            title: const Text('Retain player'),
            subtitle: const Text(
              'Keep the player alive when switching channels',
            ),
            value: _retainWebview,
            onChanged: (value) {
              setState(() => _retainWebview = value);
              unawaited(
                Prefs.load().then(
                  (prefs) => prefs.setStreamRetainWebview(value),
                ),
              );
              widget.onRetainWebviewChanged?.call(value);
            },
          ),
          if (Platform.isAndroid)
            SwitchListTile(
              secondary: const Icon(Icons.picture_in_picture),
              title: const Text('Picture-in-picture'),
              subtitle: const Text(
                'Float the stream over other apps (Android 12+, needs Retain player)',
              ),
              value: _pipEnabled,
              onChanged: (value) {
                setState(() => _pipEnabled = value);
                unawaited(
                  Prefs.load().then(
                    (prefs) => prefs.setStreamPipEnabled(value),
                  ),
                );
                widget.onPipEnabledChanged?.call(value);
              },
            ),
        ],
      ),
    );
  }
}
