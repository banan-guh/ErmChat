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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: TextWithTrailing(
        title,
        trailing: trailing,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
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
      title: TextWithTrailing(title, trailing: titleTrailing),
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

/// Marks a page that explains its settings. Info buttons show only under
/// one, so the aggregate pages explain and the home pages stay plain.
class SettingInfoScope extends InheritedWidget {
  const SettingInfoScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingInfoScope>() != null;

  @override
  bool updateShouldNotify(SettingInfoScope oldWidget) => false;
}

/// [text] with [trailing] flowing after its last word, so a title that
/// wraps keeps the trailing widget beside its end. Plain text outside a
/// [SettingInfoScope].
class TextWithTrailing extends StatelessWidget {
  const TextWithTrailing(this.text, {super.key, this.trailing, this.style});

  final String text;
  final Widget? trailing;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final trailing = this.trailing;
    if (trailing == null || !SettingInfoScope.of(context)) {
      return Text(text, style: style);
    }
    return Text.rich(
      TextSpan(
        text: text,
        children: [
          WidgetSpan(alignment: PlaceholderAlignment.middle, child: trailing),
        ],
      ),
      style: style,
    );
  }
}
