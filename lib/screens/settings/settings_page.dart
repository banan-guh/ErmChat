import 'package:flutter/material.dart';

// Shared settings shell: bottom SafeArea clears the transparent nav bar.
class SettingsPage extends StatelessWidget {
  final Widget title;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final Widget body;
  final Widget? floatingActionButton;

  const SettingsPage({
    super.key,
    required this.title,
    this.actions,
    this.bottom,
    required this.body,
    this.floatingActionButton,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: title, actions: actions, bottom: bottom),
      body: SafeArea(top: false, bottom: true, child: body),
      floatingActionButton: floatingActionButton,
    );
  }
}

/// Bold section title used to group settings rows.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}
