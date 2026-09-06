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
