import 'package:flutter/material.dart';
import '../../services/analytics_service.dart';
import '../../services/tts_controller.dart';
import 'analytics_screen.dart';
import 'recent_uploads_screen.dart';
import 'uploader_settings_screen.dart';
import 'tts_settings_screen.dart';

class ToolsSettingsScreen extends StatelessWidget {
  final AnalyticsService? analyticsService;
  final List<String>? channels;
  final TtsController? ttsController;

  const ToolsSettingsScreen({
    super.key,
    this.analyticsService,
    this.channels,
    this.ttsController,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tools')),
      body: ListView(
        children: [
          _buildTile(
            context,
            icon: Icons.record_voice_over,
            title: 'Text-to-speech',
            subtitle: 'Read out the active channel',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TtsSettingsScreen(ttsController: ttsController),
              ),
            ),
          ),
          _buildTile(
            context,
            icon: Icons.upload,
            title: 'Image uploader',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const UploaderSettingsScreen()),
            ),
          ),
          _buildTile(
            context,
            icon: Icons.image,
            title: 'Recent uploads',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const RecentUploadsScreen()),
            ),
          ),
          if (analyticsService != null && channels != null)
            _buildTile(
              context,
              icon: Icons.insights,
              title: 'Analytics',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AnalyticsScreen(
                    analyticsService: analyticsService!,
                    channels: channels!,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
