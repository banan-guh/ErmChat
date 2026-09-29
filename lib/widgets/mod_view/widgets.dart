import 'package:flutter/material.dart';

import 'scope.dart';

class ModSectionHeader extends StatelessWidget {
  const ModSectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: ModSectionHeaderText(title),
    );
  }
}

/// The section header label alone, for rows that add their own trailing.
class ModSectionHeaderText extends StatelessWidget {
  const ModSectionHeaderText(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title.toUpperCase(),
      style: TextStyle(
        fontWeight: FontWeight.w600,
        fontSize: 12,
        letterSpacing: 0.8,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Small grey explainer line above a list.
class ModHint extends StatelessWidget {
  const ModHint(this.text, {super.key, this.padding = EdgeInsets.zero});

  final String text;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Spinner sized to sit where a row's trailing button would.
class ModSpinner extends StatelessWidget {
  const ModSpinner({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: const CircularProgressIndicator(strokeWidth: 2),
    );
  }
}

/// Centered empty state: large icon plus bold title and grey subtitle.
class ModEmpty extends StatelessWidget {
  const ModEmpty({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: muted),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: TextStyle(fontSize: 14, color: muted),
                textAlign: TextAlign.center,
              ),
            ],
            ?action,
          ],
        ),
      ),
    );
  }
}

/// Error state with retry.
class ModError extends StatelessWidget {
  const ModError({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// Renders a [ModLoader]: spinner, error with retry, [empty] when
/// [isEmpty] holds, else [builder]. [inline] sizes the spinner for a
/// section inside a list instead of a whole tab.
class ModLoadView<T extends Object> extends StatelessWidget {
  const ModLoadView({
    super.key,
    required this.loader,
    required this.builder,
    this.isEmpty,
    this.empty,
    this.inline = false,
  });

  final ModLoader<T> loader;
  final Widget Function(BuildContext context, T value) builder;
  final bool Function(T value)? isEmpty;
  final Widget? empty;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: loader,
      builder: (context, _) {
        final value = loader.value;
        if (value == null) {
          final error = loader.error;
          if (error != null) {
            return ModError(message: error, onRetry: loader.load);
          }
          const spinner = CircularProgressIndicator();
          return inline
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: spinner),
                )
              : const Center(child: spinner);
        }
        if (empty != null && (isEmpty?.call(value) ?? false)) return empty!;
        return builder(context, value);
      },
    );
  }
}

/// Horizontal single-select chip row (filters, statuses).
class ModChoiceChips<T> extends StatelessWidget {
  const ModChoiceChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
  });

  final List<(String, T)> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding,
      child: Row(
        spacing: 8,
        children: [
          for (final (label, value) in options)
            ChoiceChip(
              label: Text(label),
              selected: value == selected,
              onSelected: (_) => onSelected(value),
            ),
        ],
      ),
    );
  }
}

/// Square grid tile for the Modes and Stream grids. [dimmed] greys it out
/// while keeping [onTap], so a gated tile can still explain itself.
class ModTile extends StatelessWidget {
  const ModTile({
    super.key,
    required this.icon,
    required this.label,
    this.status,
    this.active = false,
    this.dimmed = false,
    this.busy = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? status;
  final bool active;
  final bool dimmed;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = active ? scheme.primaryContainer : scheme.surfaceContainerHigh;
    final fg = active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return Opacity(
      opacity: dimmed || onTap == null ? 0.55 : 1.0,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: busy ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  const ModSpinner(size: 28)
                else
                  Icon(icon, size: 28, color: fg),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (status != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    status!,
                    style: TextStyle(fontSize: 11, color: fg),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A 3-column tile grid that sizes to its content inside a list.
class ModTileGrid extends StatelessWidget {
  const ModTileGrid({
    super.key,
    required this.tiles,
    this.aspectRatio = 0.9,
    this.padding = EdgeInsets.zero,
  });

  final List<Widget> tiles;
  final double aspectRatio;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 3,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: aspectRatio,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: padding,
      children: tiles,
    );
  }
}
