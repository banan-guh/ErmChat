import 'dart:async';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../util/log.dart';
import 'dev_settings_screen.dart';

class AboutScreen extends StatefulWidget {
  final ValueChanged<bool>? onTestWidgetsChanged;

  const AboutScreen({super.key, this.onTestWidgetsChanged});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String _version = 'Loading...';
  int _tapCount = 0;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _version = '${info.version}+${info.buildNumber}');
      }
    } catch (_) {
      logDebug('[AboutScreen] failed to load package info');
      if (mounted) setState(() => _version = 'unknown');
    }
  }

  void _handleTap() {
    _tapCount++;
    if (_tapCount >= 7) {
      _tapCount = 0;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DevSettingsScreen(
            onTestWidgetsChanged: widget.onTestWidgetsChanged,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: InkWell(
        onTap: _handleTap,
        child: SizedBox.expand(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('ErmChat', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'Version $_version',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
