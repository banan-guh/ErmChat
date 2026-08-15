import 'package:flutter/material.dart';
import '../../services/analytics_service.dart';
import 'analytics_screen.dart';
import 'recent_uploads_screen.dart';
import 'uploader_settings_screen.dart';

class ToolsSettingsScreen extends StatelessWidget {
  final AnalyticsService? analyticsService;
  final List<String>? channels;

  const ToolsSettingsScreen({super.key, this.analyticsService, this.channels});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tools')),
      body: ListView(
        children: [
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
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
