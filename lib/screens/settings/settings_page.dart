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
  const SettingsSectionHeader(this.title, {super.key, this.trailing});

  final String title;

  /// Sits right after the title, such as an info button.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
    );
    final trailing = this.trailing;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, trailing == null ? 16 : 8, 16, 4),
      child: trailing == null
          ? text
          : Row(
              children: [
                Flexible(child: text),
                trailing,
              ],
            ),
    );
  }
}

/// Navigation row with a leading icon and a trailing chevron.
class SettingsNavTile extends StatelessWidget {
  const SettingsNavTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.enabled = true,
    required this.onTap,
    this.titleTrailing,
  });

  final IconData icon;
  final String title;

  /// Sits right after the title, such as an info button.
  final Widget? titleTrailing;
  final String? subtitle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: titleTrailing == null
          ? Text(title)
          : Row(
              children: [
                Flexible(child: Text(title)),
                titleTrailing!,
              ],
            ),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: const Icon(Icons.chevron_right),
      enabled: enabled,
      onTap: onTap,
    );
  }
}

/// A page's opening line: why the page exists and what is on it.
class SettingsPageIntro extends StatelessWidget {
  const SettingsPageIntro(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
