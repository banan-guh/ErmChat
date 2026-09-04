import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/stream_player_controller.dart';

class StreamSettingsScreen extends StatefulWidget {
  final ValueChanged<bool>? onShowExtensionsChanged;
  final ValueChanged<bool>? onRetainWebviewChanged;

  const StreamSettingsScreen({
    super.key,
    this.onShowExtensionsChanged,
    this.onRetainWebviewChanged,
  });

  @override
  State<StreamSettingsScreen> createState() => _StreamSettingsScreenState();
}

class _StreamSettingsScreenState extends State<StreamSettingsScreen> {
  bool _showExtensions = false;
  bool _retainWebview = true;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _showExtensions =
          prefs.getBool(StreamPlayerController.showExtensionsKey) ?? false;
      _retainWebview =
          prefs.getBool(StreamPlayerController.retainWebviewKey) ?? true;
    });
  }

  Future<void> _setBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Livestreams')),
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
                _setBool(StreamPlayerController.showExtensionsKey, value),
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
                _setBool(StreamPlayerController.retainWebviewKey, value),
              );
              widget.onRetainWebviewChanged?.call(value);
            },
          ),
        ],
      ),
    );
  }
}
