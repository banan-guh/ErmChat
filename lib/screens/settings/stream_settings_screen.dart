import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'prefs_tiles.dart';
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
  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: const Text('Livestreams'),
      body: ListView(
        children: [
          PrefsSwitchTile(
            secondary: const Icon(Icons.extension),
            title: 'Show stream extensions',
            subtitle: 'Load channel extensions inside the player',
            defaultValue: false,
            read: (p) => p.streamShowExtensions,
            write: (p, v) => p.setStreamShowExtensions(v),
            onChanged: widget.onShowExtensionsChanged,
          ),
          PrefsSwitchTile(
            secondary: const Icon(Icons.cached),
            title: 'Retain player',
            subtitle: 'Keep the player alive when switching channels',
            defaultValue: true,
            read: (p) => p.streamRetainWebview,
            write: (p, v) => p.setStreamRetainWebview(v),
            onChanged: widget.onRetainWebviewChanged,
          ),
          if (Platform.isAndroid)
            PrefsSwitchTile(
              secondary: const Icon(Icons.picture_in_picture),
              title: 'Picture-in-picture',
              subtitle:
                  'Float the stream over other apps (Android 12+, needs Retain player)',
              defaultValue: false,
              read: (p) => p.streamPipEnabled,
              write: (p, v) => p.setStreamPipEnabled(v),
              onChanged: widget.onPipEnabledChanged,
            ),
        ],
      ),
    );
  }
}
