import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import '../../services/analytics_service.dart';
import '../../services/emote_images.dart';
import '../../services/tts_controller.dart';
import 'analytics_screen.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';
import 'tts_settings_screen.dart';
import 'uploader_settings_screen.dart';

/// Features too small for a top-level entry: TTS, uploads, analytics, and
/// the stream player toggles.
class ToolsSettingsScreen extends StatelessWidget {
  final AnalyticsService? analyticsService;
  final List<String>? channels;
  final TtsController? ttsController;
  final EmoteImages? images;
  final ValueChanged<bool>? onPipEnabledChanged;

  const ToolsSettingsScreen({
    super.key,
    this.analyticsService,
    this.channels,
    this.ttsController,
    this.images,
    this.onPipEnabledChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: const Text('Tools'),
      body: ListView(
        children: [
          SettingsNavTile(
            icon: Icons.record_voice_over,
            title: 'Text-to-speech',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TtsSettingsScreen(ttsController: ttsController),
              ),
            ),
          ),
          SettingsNavTile(
            icon: Icons.upload,
            title: 'Image uploader',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const UploaderSettingsScreen()),
            ),
          ),
          if (analyticsService != null && channels != null && images != null)
            SettingsNavTile(
              icon: Icons.insights,
              title: 'Analytics',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AnalyticsScreen(
                    analyticsService: analyticsService!,
                    channels: channels!,
                    images: images!,
                  ),
                ),
              ),
            ),
          if (Platform.isAndroid) ...[
            const SettingsSectionHeader('Livestreams'),
            PrefsSwitchTile(
              secondary: const Icon(Icons.picture_in_picture),
              title: 'Picture-in-picture',
              defaultValue: false,
              read: (p) => p.streamPipEnabled,
              write: (p, v) => p.setStreamPipEnabled(v),
              onChanged: onPipEnabledChanged,
            ),
          ],
        ],
      ),
    );
  }
}
