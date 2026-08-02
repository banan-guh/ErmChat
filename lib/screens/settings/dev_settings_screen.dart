import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../widgets/welcome_dialog.dart';

class DevSettingsScreen extends StatelessWidget {
  const DevSettingsScreen({super.key});

  Future<void> _replayWelcomeScreen(BuildContext context) async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('welcome_seen', false);
    if (!context.mounted) return;
    showWelcomeDialog(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dev settings')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.replay),
            title: const Text('Replay welcome screen'),
            subtitle: const Text('Show the first-launch popup again'),
            onTap: () => _replayWelcomeScreen(context),
          ),
        ],
      ),
    );
  }
}
