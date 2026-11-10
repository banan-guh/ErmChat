import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'design_tokens.dart';

/// Side of the chat widget cards' header controls.
const double kChromeMenuSize = 28;

/// The chat widget cards' gap from the top and sides of the chat pages.
const double kChromeMenuMargin = 8;

// The view menu in the island's button row: search, mod view, calendar,
// and the fullscreen, input and stream toggles. Its chevron points up, the
// way the menu opens, and flips while open.
class ChromeMenuButton extends StatefulWidget {
  final VoidCallback onToggleFullscreen;
  final VoidCallback onToggleInput;
  final VoidCallback? onToggleStream;
  final bool Function()? showStreamToggle;
  final bool Function()? streamActive;
  final VoidCallback? onShowModView;
  final bool Function()? showModView;
  final VoidCallback? onToggleSearch;

  /// Opens the channel page's days.
  final VoidCallback? onCalendar;

  const ChromeMenuButton({
    super.key,
    required this.onToggleFullscreen,
    required this.onToggleInput,
    this.onToggleStream,
    this.showStreamToggle,
    this.streamActive,
    this.onShowModView,
    this.showModView,
    this.onToggleSearch,
    this.onCalendar,
  });

  @override
  State<ChromeMenuButton> createState() => ChromeMenuButtonState();
}

class ChromeMenuButtonState extends State<ChromeMenuButton> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return ChromeMenu(
      onOpenChanged: (open) => setState(() => _open = open),
      entries: () {
        final l10n = context.l10n;
        final showMod = widget.showModView?.call() ?? false;
        final showStream = widget.showStreamToggle?.call() ?? false;
        final active = widget.streamActive?.call() ?? false;
        return [
          if (showMod)
            ChromeMenuEntry(
              l10n.modView,
              () => widget.onShowModView?.call(),
              icon: Icons.shield_outlined,
            ),
          ChromeMenuEntry(
            l10n.search,
            () => widget.onToggleSearch?.call(),
            icon: Icons.search,
          ),
          if (widget.onCalendar case final onCalendar?)
            ChromeMenuEntry(
              l10n.historyCalendar,
              onCalendar,
              icon: Icons.calendar_month_outlined,
            ),
          ChromeMenuEntry(
            l10n.toggleFullscreen,
            widget.onToggleFullscreen,
            icon: Icons.fullscreen,
          ),
          ChromeMenuEntry(
            l10n.toggleInput,
            widget.onToggleInput,
            icon: Icons.keyboard_outlined,
          ),
          if (showStream)
            ChromeMenuEntry(
              active ? l10n.hideStream : l10n.showStream,
              () => widget.onToggleStream?.call(),
              icon: Icons.live_tv_outlined,
            ),
        ];
      },
      buttonStyle: const ButtonStyle(),
      trigger: AnimatedRotation(
        turns: _open ? 0.0 : 0.5,
        duration: Motion.fast,
        child: const Icon(Icons.expand_more),
      ),
    );
  }
}

/// The view menu's pill while fullscreen floats it over the pages. Its width
/// matches a small FAB's tap target, so a floating button under it at the
/// same right edge shares its center.
class FloatingMenuShell extends StatelessWidget {
  const FloatingMenuShell({super.key, required this.child});

  final Widget child;

  static const double width = 48;
  static const double height = 40;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: DecoratedBox(
      decoration: ShapeDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        shape: const StadiumBorder(),
      ),
      child: Center(child: child),
    ),
  );
}

/// One row of a [ChromeMenu]; [ChromeMenuEntry.divider] draws a line.
class ChromeMenuEntry {
  const ChromeMenuEntry(this.label, this.onTap, {this.icon});
  const ChromeMenuEntry.divider() : label = null, onTap = null, icon = null;

  final String? label;
  final VoidCallback? onTap;

  /// Leading icon.
  final IconData? icon;
}

/// A chrome dropdown. [entries] is read on each open, so rows that depend on
/// state stay current.
class ChromeMenu extends StatefulWidget {
  const ChromeMenu({
    super.key,
    required this.trigger,
    required this.entries,
    this.onOpenChanged,
    this.buttonStyle,
  });

  /// The tap target; with [buttonStyle], the icon of an [IconButton] in that
  /// style, which draws its own ink.
  final Widget trigger;
  final ButtonStyle? buttonStyle;
  final List<ChromeMenuEntry> Function() entries;
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<ChromeMenu> createState() => _ChromeMenuState();
}

class _ChromeMenuState extends State<ChromeMenu> {
  List<ChromeMenuEntry> _entries = const [];

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      position: PopupMenuPosition.under,
      popUpAnimationStyle: const AnimationStyle(duration: Motion.fast),
      onOpened: () => widget.onOpenChanged?.call(true),
      onCanceled: () => widget.onOpenChanged?.call(false),
      onSelected: (i) {
        widget.onOpenChanged?.call(false);
        _entries[i].onTap?.call();
      },
      itemBuilder: (_) {
        _entries = widget.entries();
        return [
          for (var i = 0; i < _entries.length; i++)
            if (_entries[i].label case final label?)
              PopupMenuItem(
                value: i,
                child: Row(
                  children: [
                    if (_entries[i].icon case final icon?) ...[
                      Icon(icon, size: 20),
                      const SizedBox(width: 12),
                    ],
                    Flexible(
                      child: Text(label, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              )
            else
              const PopupMenuDivider(),
        ];
      },
      style: widget.buttonStyle,
      icon: widget.buttonStyle == null ? null : widget.trigger,
      child: widget.buttonStyle == null ? widget.trigger : null,
    );
  }
}
