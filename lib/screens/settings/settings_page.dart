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

/// One action in a [SettingsActionRow].
class SettingsAction {
  const SettingsAction(this.label, this.child);

  final String label;
  final Widget child;
}

/// Lays actions side by side, each taking width in proportion to its label,
/// so the row fills. Stacks them full width when the labels cannot fit.
class SettingsActionRow extends StatelessWidget {
  const SettingsActionRow({super.key, required this.actions});

  final List<SettingsAction> actions;

  static const _gap = 12.0;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelLarge;
    final scaler = MediaQuery.textScalerOf(context);
    // Button padding is 24 each side; the label is the part that varies.
    final widths = [
      for (final action in actions)
        _textWidth(action.label, style, scaler, Directionality.of(context)) +
            48,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final needed =
            widths.fold(0.0, (sum, width) => sum + width) +
            _gap * (actions.length - 1);
        if (needed > constraints.maxWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                actions[i].child,
              ],
            ],
          );
        }
        return Row(
          children: [
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) const SizedBox(width: _gap),
              Expanded(
                flex: widths[i].round().clamp(1, 1 << 20),
                child: actions[i].child,
              ),
            ],
          ],
        );
      },
    );
  }

  static double _textWidth(
    String text,
    TextStyle? style,
    TextScaler scaler,
    TextDirection direction,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}
